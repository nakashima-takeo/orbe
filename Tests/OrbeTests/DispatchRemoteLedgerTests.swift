import XCTest

@testable import Orbe

/// remote の台帳（`DispatchRemoteLedger`）と、行の同一性を求める口（`DispatchRowIdentities`）。番号チップ・
/// PR 行の行き先・clean の PR の突き合わせはすべてここを通る。
///
/// 確定の判定が甘いと、正式名が分からないうちに行が「GitHub の行でない」と読まれ、チップが付かないまま
/// PR 行がブラウザに倒れ、clean ではレビュー中の PR を持つ worktree が安全群に入りうる。確かめられない
/// remote を「GitHub でない」と読むと、clean が PR の事実を「確かめて 0 件」と読む。同一性の求め方が狂うと、
/// 他人の fork の PR が自分の行に紐づくか、自分の PR が自分の行から外れる。
final class DispatchRemoteLedgerTests: OrbeTestCase {

  private let mine = GitHubRepoName(nameWithOwner: "me/r")
  private let base = GitHubRepoName(nameWithOwner: "base/r")

  private func settled(_ repositories: [String: DispatchRemoteRepository])
    -> DispatchRemoteLedger.Resolved
  {
    DispatchRemoteLedger.Resolved(repositories: repositories)
  }

  private func branch(_ name: String, pushRemote: String?) -> GitBranch {
    GitBranch(name: name, relativeDate: "", upstream: nil, pushRemote: pushRemote)
  }

  // MARK: - 確定

  /// GitHub の remote すべてに答え（正式名・確かめられない）が揃ったときだけ確定する。GitHub でない
  /// remote は問い合わせないので待たない。
  func testLedgerSettlesOnlyWhenEveryGitHubRemoteHasAnAnswer() {
    let remotes = [
      "origin": "git@github.com:me/r.git", "upstream": "https://github.com/base/r.git",
      "local": "/srv/mirror.git",
    ]
    XCTAssertEqual(
      DispatchRemoteLedger(remotes: remotes, answers: [mine: .found(mine)]),
      .pending, "答えの無い GitHub の remote が残っている間は未確定")

    XCTAssertEqual(
      DispatchRemoteLedger(remotes: remotes, answers: [mine: .found(mine), base: .unverified]),
      .settled(settled(["origin": .github(mine), "upstream": .unverified, "local": .notGitHub])),
      "確かめられない remote は「GitHub でない」と分けて確定する")
  }

  /// GitHub の URL なのにリポジトリ名を読めない remote は、「GitHub でない」ではなく「確かめられない」。
  func testGitHubURLWithoutARepositoryNameIsUnverified() {
    XCTAssertEqual(
      DispatchRemoteLedger(
        remotes: ["origin": "git@github.com:me/r.git", "odd": "https://github.com/"],
        answers: [mine: .found(mine)]),
      .settled(settled(["origin": .github(mine), "odd": .unverified])))
  }

  /// URL が改名前の名前のままでも、GitHub が答えた正式名で行の ref が決まる（PR の head と等しくなる）。
  func testRenamedRemoteIsIdentifiedByItsCanonicalName() {
    let old = GitHubRepoName(nameWithOwner: "me/old-name")
    let ledger = DispatchRemoteLedger(
      remotes: ["origin": "https://github.com/me/old-name.git"], answers: [old: .found(mine)])
    guard case .settled(let resolved) = ledger else { return XCTFail("答えが揃えば確定する") }
    let identities = DispatchRowIdentities(
      resolved: resolved, localBranches: [branch("feat", pushRemote: "origin")])
    XCTAssertEqual(identities.local("feat"), .ref(GitHubBranchRef(repo: mine, branch: "feat")))
  }

  // MARK: - ローカルブランチの同一性

  /// push 先の remote のリポジトリと、ローカル名。
  func testLocalBranchIsItsPushRemoteRepositoryAndLocalName() {
    let identities = DispatchRowIdentities(
      resolved: settled(["origin": .github(base), "mine": .github(mine)]),
      localBranches: [branch("feat", pushRemote: "mine"), branch("topic", pushRemote: "origin")])
    XCTAssertEqual(
      identities.local("feat"), .ref(GitHubBranchRef(repo: mine, branch: "feat")),
      "fork へ push する行は fork のブランチ")
    XCTAssertEqual(identities.local("topic"), .ref(GitHubBranchRef(repo: base, branch: "topic")))
  }

  /// push 先が無い行と、ローカルブランチを追跡する（`.`）行は、origin の同名ブランチとみなす。
  func testLocalBranchWithoutAPushRemoteIsOriginsSameNamedBranch() {
    let identities = DispatchRowIdentities(
      resolved: settled(["origin": .github(mine), "upstream": .github(base)]),
      localBranches: [branch("feat", pushRemote: nil), branch("stacked", pushRemote: ".")])
    XCTAssertEqual(identities.local("feat"), .ref(GitHubBranchRef(repo: mine, branch: "feat")))
    XCTAssertEqual(
      identities.local("stacked"), .ref(GitHubBranchRef(repo: mine, branch: "stacked")))
  }

  /// push 先の remote が GitHub でない行は `notGitHub`、確かめられない行は `unverified`——origin の
  /// 同名ブランチと読み替えない。remote として引けない push 先（URL を直接書いた remote・存在しない
  /// remote）も確かめられない。
  func testLocalBranchOnAnUnusablePushRemoteIsNotReadAsOrigin() {
    let identities = DispatchRowIdentities(
      resolved: settled([
        "origin": .github(mine), "mirror": .notGitHub, "gone": .unverified,
      ]),
      localBranches: [
        branch("a", pushRemote: "mirror"), branch("b", pushRemote: "gone"),
        branch("c", pushRemote: "https://github.com/me/r.git"),
        branch("d", pushRemote: "removed"),
      ])
    XCTAssertEqual(identities.local("a"), .notGitHub)
    XCTAssertEqual(identities.local("b"), .unverified)
    XCTAssertEqual(identities.local("c"), .unverified, "URL を直接書いた remote")
    XCTAssertEqual(identities.local("d"), .unverified, "存在しない remote")
  }

  // MARK: - remote 追跡ブランチの同一性

  /// `<remote>/<branch>` を台帳の remote 名で切り分ける。`/` を含む remote 名は最も長く一致するものを採る。
  func testRemoteBranchIsSplitByTheLongestKnownRemoteName() {
    let team = GitHubRepoName(nameWithOwner: "team/r")
    let ledger = settled([
      "origin": .github(base), "team": .github(team), "team/me": .github(mine),
      "gone": .unverified,
    ])
    XCTAssertEqual(
      ledger.remoteBranch("origin/feat/x"), .ref(GitHubBranchRef(repo: base, branch: "feat/x")))
    XCTAssertEqual(
      ledger.remoteBranch("team/me/feat"), .ref(GitHubBranchRef(repo: mine, branch: "feat")))
    XCTAssertEqual(
      ledger.remoteBranch("team/feat"), .ref(GitHubBranchRef(repo: team, branch: "feat")))
    XCTAssertEqual(ledger.remoteBranch("gone/feat"), .unverified)
    XCTAssertEqual(ledger.remoteBranch("unknown/feat"), .notGitHub, "台帳に無い remote")
  }
}
