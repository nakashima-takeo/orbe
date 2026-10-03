import XCTest

@testable import Orbe

/// 行と PR の同一性（push 先の remote のリポジトリ, ローカル名）を、実 git が解決する push 先から、
/// clean の PR の事実まで通す。
///
/// 壊れると、base（`origin/main`）を追跡する作業ブランチに main→release のマージ済み PR が紐づいて、
/// レビュー中の worktree が clean の安全群に初期チェック付きで並ぶ。fork へ push する運用では自分の PR を
/// 見失い、確かめられない push 先の行は「確かめて 0 件」と読まれて安全確認を素通りする。
extension WorktreePaletteRemoteLedgerProviderTests {

  /// `git worktree add -b X … origin/main` で作った（base を追跡する）worktree は、自分の PR にだけ
  /// 紐づく。base から出た PR（マージ済みの main→release）は clean の事実に現れず、自分の PR が
  /// レビュー中なら安全群に入らない。
  func testBaseTrackingWorktreeIgnoresPullRequestsFromTheBase() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(git(["update-ref", "refs/remotes/origin/main", "HEAD"]).isSuccess)
    let worktree = dir.appendingPathComponent("wt-issue").path
    XCTAssertTrue(
      git(["worktree", "add", "-q", "-b", "issue/1257", worktree, "origin/main"]).isSuccess)
    XCTAssertEqual(
      run(["rev-parse", "--abbrev-ref", "@{upstream}"], in: worktree).stdoutText
        .trimmingCharacters(in: .whitespacesAndNewlines), "origin/main", "前提: base を追跡している")
    try serveBranchPullRequests(
      "main", "[\(branchPR(1264, head: "main", state: "MERGED", base: "release", from: "me/r"))]")
    try serveBranchPullRequests(
      "issue/1257", "[\(branchPR(7, head: "issue/1257", state: "OPEN", from: "me/r"))]")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(
      pump({
        guard case .loaded = provider.branchPRStates["issue/1257"] else { return false }
        return model.classification?.first { $0.branch == "issue/1257" }?.isReady == true
      }))

    XCTAssertEqual(
      provider.branchPRStates["issue/1257"],
      .loaded([
        GitHubBranchPR(
          number: 7, headRefName: "issue/1257", state: "OPEN", baseRefName: "main",
          headRepository: mine)
      ]))
    let row = try XCTUnwrap(model.classification?.first { $0.branch == "issue/1257" })
    XCTAssertFalse(row.vocabulary.contains(.mergedPR(1264, base: "release")))
    XCTAssertNotEqual(row.group, .safe, "レビュー中の worktree は安全群に入らない")
  }

  /// fork の三角運用（`remote.pushDefault` が自分の fork、作業ブランチは本家の `origin/main` を追跡）
  /// でも、自分の fork から出た PR がその行の clean の事実になる。本家の同名ブランチから出た PR は
  /// 紐づかない。
  func testTriangularForkWorkflowLinksOwnPullRequestToTheRow() throws {
    addRemote("origin", "base/r")
    addRemote("mine", "me/r")
    try answer("base/r", found: "base/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(git(["config", "remote.pushDefault", "mine"]).isSuccess)
    XCTAssertTrue(git(["update-ref", "refs/remotes/origin/main", "HEAD"]).isSuccess)
    let worktree = dir.appendingPathComponent("wt-topic").path
    XCTAssertTrue(git(["worktree", "add", "-q", "-b", "topic", worktree, "origin/main"]).isSuccess)
    try serveBranchPullRequests(
      "topic",
      "[\(branchPR(3, head: "topic", state: "OPEN", from: "me/r")),"
        + "\(branchPR(4, head: "topic", state: "OPEN", from: "base/r"))]")
    let (_, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(
      pump({
        guard case .loaded = provider.branchPRStates["topic"] else { return false }
        return true
      }))

    XCTAssertEqual(
      provider.branchPRStates["topic"],
      .loaded([
        GitHubBranchPR(
          number: 3, headRefName: "topic", state: "OPEN", baseRefName: "main",
          headRepository: mine)
      ]))
  }

  /// 正式名を確かめられない remote（見えない private・消えた fork）や、remote として引けない push 先
  /// （`branch.<名前>.remote` に URL を直接書いた行）へ push する行は、origin の同名ブランチの PR に
  /// 紐づかず、clean の PR の事実は取得失敗（安全群に入らない）。問い合わせもしない。他の行は普通に
  /// 紐づく。
  func testRowsPushingWhereGitHubCannotConfirmStayUnknownForClean() throws {
    addRemote("origin", "me/r")
    addRemote("gone", "gone/r")
    try answer("me/r", found: "me/r")
    try answerNotFound("gone/r")
    _ = try addWorktree("wt-a", branch: "a")
    XCTAssertTrue(git(["config", "branch.a.pushRemote", "gone"]).isSuccess)
    _ = try addWorktree("wt-u", branch: "u")
    XCTAssertTrue(git(["config", "branch.u.remote", "https://github.com/me/r.git"]).isSuccess)
    XCTAssertTrue(git(["config", "branch.u.merge", "refs/heads/u"]).isSuccess)
    _ = try addWorktree("wt-b", branch: "b")
    let heads = ["a", "u", "b"]
    for (index, head) in heads.enumerated() {
      try serveBranchPullRequests(
        head, "[\(branchPR(index + 1, head: head, state: "OPEN", from: "me/r"))]")
    }
    let (_, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(
      pump({
        guard case .loaded = provider.branchPRStates["b"] else { return false }
        return true
      }))

    XCTAssertEqual(provider.branchPRStates["a"], .failed, "確かめられない remote へ push する行")
    XCTAssertEqual(provider.branchPRStates["u"], .failed, "URL の remote へ push する行")
    XCTAssertEqual(calls("H"), ["b"], "確かめられない行は問い合わせない")
    XCTAssertEqual(
      provider.branchPRStates["b"],
      .loaded([
        GitHubBranchPR(
          number: 3, headRefName: "b", state: "OPEN", baseRefName: "main", headRepository: mine)
      ]))
  }
}
