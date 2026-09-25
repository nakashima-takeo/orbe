import XCTest

@testable import Orbe

/// remote の台帳（`DispatchRemoteLedger`）。行が「GitHub のどのリポジトリのどのブランチか」を決める
/// 唯一の置き場で、番号チップ・PR 行の行き先・clean の PR の突き合わせはすべてここを通る。
///
/// 確定の判定が甘いと、正式名が分からないうちに行が「GitHub の行でない」と読まれ、チップが付かないまま
/// PR 行がブラウザに倒れ、clean ではレビュー中の PR を持つ worktree が安全群に入りうる。ref の求め方が
/// 狂うと、他人の fork の PR が自分の行に紐づくか、自分の PR が自分の行から外れる。
final class DispatchRemoteLedgerTests: OrbeTestCase {

  private let mine = GitHubRepoName(nameWithOwner: "me/r")
  private let base = GitHubRepoName(nameWithOwner: "base/r")

  private func settled(_ repositories: [String: GitHubRepoName?]) -> DispatchRemoteLedger.Resolved {
    DispatchRemoteLedger.Resolved(repositories: repositories)
  }

  private func upstream(_ remote: String, _ branch: String) -> GitUpstream {
    GitUpstream(
      short: "\(remote)/\(branch)", ref: "refs/remotes/\(remote)/\(branch)", remote: remote,
      remoteRef: "refs/heads/\(branch)", track: nil)
  }

  // MARK: - 確定

  /// GitHub の remote すべてに答え（正式名・存在しない）が揃ったときだけ確定する。GitHub でない
  /// remote は問い合わせないので待たない。
  func testLedgerSettlesOnlyWhenEveryGitHubRemoteHasAnAnswer() {
    let remotes = [
      "origin": "git@github.com:me/r.git", "upstream": "https://github.com/base/r.git",
      "local": "/srv/mirror.git",
    ]
    XCTAssertEqual(
      DispatchRemoteLedger(remotes: remotes, resolutions: [mine: .found(mine)], failed: []),
      .pending, "答えの無い GitHub の remote が残っている間は未確定")

    XCTAssertEqual(
      DispatchRemoteLedger(
        remotes: remotes, resolutions: [mine: .found(mine), base: .notFound], failed: []),
      .settled(settled(["origin": mine, "upstream": nil, "local": nil])),
      "存在しないリポジトリと GitHub でない remote は「GitHub の行でない」で確定する")
  }

  /// 問い合わせが失敗した remote があれば、確定ではなく失敗（確定した `nil` と取り違えない）。
  func testFailedLookupLeavesTheLedgerFailedInsteadOfSettled() {
    XCTAssertEqual(
      DispatchRemoteLedger(
        remotes: ["origin": "git@github.com:me/r.git", "upstream": "https://github.com/base/r"],
        resolutions: [mine: .found(mine)], failed: [base]),
      .failed)
  }

  /// URL が改名前の名前のままでも、GitHub が答えた正式名で行の ref が決まる（PR の head と等しくなる）。
  func testRenamedRemoteIsIdentifiedByItsCanonicalName() {
    let old = GitHubRepoName(nameWithOwner: "me/old-name")
    let ledger = DispatchRemoteLedger(
      remotes: ["origin": "https://github.com/me/old-name.git"],
      resolutions: [old: .found(mine)], failed: [])
    guard case .settled(let resolved) = ledger else { return XCTFail("答えが揃えば確定する") }
    XCTAssertEqual(
      resolved.ref(forLocal: "feat", upstream: upstream("origin", "feat")),
      GitHubBranchRef(repo: mine, branch: "feat"))
  }

  // MARK: - ローカルブランチの ref

  /// upstream があれば、その remote のリポジトリと remote 側のブランチ名（ローカル名とは限らない）。
  func testLocalBranchWithUpstreamIsTheUpstreamRepositoryAndBranch() {
    let ledger = settled(["origin": base, "mine": mine])
    XCTAssertEqual(
      ledger.ref(forLocal: "feat", upstream: upstream("mine", "feature-x")),
      GitHubBranchRef(repo: mine, branch: "feature-x"), "fork の remote を追跡する行は fork のブランチ")
    XCTAssertEqual(
      ledger.ref(forLocal: "feat", upstream: upstream("origin", "feature-x")),
      GitHubBranchRef(repo: base, branch: "feature-x"))
  }

  /// upstream が無い行と、台帳に無い remote（ローカルブランチを追跡する `.` 等）を追跡する行は、
  /// origin の同名ブランチとみなす。
  func testLocalBranchWithoutUsableUpstreamIsOriginsSameNamedBranch() {
    let ledger = settled(["origin": mine, "upstream": base])
    let expected = GitHubBranchRef(repo: mine, branch: "feat")
    XCTAssertEqual(ledger.ref(forLocal: "feat", upstream: nil), expected, "upstream が無い")
    XCTAssertEqual(
      ledger.ref(forLocal: "feat", upstream: upstream(".", "main")), expected, "ローカルブランチを追跡")
  }

  /// 追跡先・既定の remote が GitHub でない（存在しない）行は、どの PR とも等しくならない。
  func testBranchOnNonGitHubRemoteHasNoRef() {
    let ledger = settled(["origin": nil, "upstream": base])
    XCTAssertNil(ledger.ref(forLocal: "feat", upstream: nil), "origin が GitHub でない")
    XCTAssertNil(
      settled(["origin": mine, "mirror": nil]).ref(
        forLocal: "feat", upstream: upstream("mirror", "feat")),
      "追跡先の remote が GitHub でない行を origin の行と読み替えない")
  }

  // MARK: - remote 追跡ブランチの ref

  /// `<remote>/<branch>` を台帳の remote 名で切り分ける。`/` を含む remote 名は最も長く一致するものを採る。
  func testRemoteBranchIsSplitByTheLongestKnownRemoteName() {
    let team = GitHubRepoName(nameWithOwner: "team/r")
    let ledger = settled(["origin": base, "team": team, "team/me": mine])
    XCTAssertEqual(
      ledger.ref(forRemoteBranch: "origin/feat/x"), GitHubBranchRef(repo: base, branch: "feat/x"))
    XCTAssertEqual(
      ledger.ref(forRemoteBranch: "team/me/feat"), GitHubBranchRef(repo: mine, branch: "feat"))
    XCTAssertEqual(
      ledger.ref(forRemoteBranch: "team/feat"), GitHubBranchRef(repo: team, branch: "feat"))
    XCTAssertNil(ledger.ref(forRemoteBranch: "unknown/feat"), "台帳に無い remote は同一性を持たない")
  }
}
