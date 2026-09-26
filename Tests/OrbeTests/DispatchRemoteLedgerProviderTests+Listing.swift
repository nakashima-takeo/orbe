import XCTest

@testable import Orbe

/// remote の一覧の読み取りが台帳へ届く経路。読めない一覧を「remote が無い」と読まないこと、表示の
/// 装飾が付くリポジトリ（部分クローン）でも読めることを固定する。
extension DispatchRemoteLedgerProviderTests {

  /// remote の一覧が読めなければ、どの行も「確かめられない」（空の一覧として確定させない）。空で確定
  /// させると、どの行も「GitHub の行でない」になり、clean がレビュー中の PR を持つ worktree を
  /// 「確かめて 0 件」と読む。
  func testUnreadableRemoteListLeavesEveryRowUnverified() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    _ = try addWorktree("wt-feat", branch: "feat")
    let (_, provider) = makeProvider()
    provider.load()
    XCTAssertTrue(pump({ provider.remoteLedger != .pending }), "前提: 読めた一覧で台帳が確定する")

    provider.remoteListing = .unreadable

    XCTAssertTrue(originUnverified(provider))
    XCTAssertEqual(provider.branchPRStates["feat"], .failed, "安全群に入らない側に倒れる")
  }

  /// **部分クローンでも通常の clone と同じに紐づく。** 部分クローンは remote の表示にフィルタ名
  /// （`[blob:none]`）が付くが、行のチップ・PR 行の行き先・clean の PR の事実は変わらない。
  func testPartialCloneLinksRowsAndPullRequestsLikeAFullClone() throws {
    XCTAssertTrue(git(["config", "uploadpack.allowFilter", "true"]).isSuccess)
    let partial = dir.appendingPathComponent("partial").path
    XCTAssertTrue(
      run(["clone", "-q", "--filter=blob:none", "file://\(root!)", partial], in: dir.path)
        .isSuccess)
    let worktree = dir.appendingPathComponent("wt-feat").path
    XCTAssertTrue(run(["worktree", "add", "-q", "-b", "feat", worktree], in: partial).isSuccess)
    XCTAssertTrue(
      run(["remote", "set-url", "origin", "https://github.com/me/r.git"], in: partial).isSuccess)
    XCTAssertTrue(run(["config", "protocol.https.allow", "never"], in: partial).isSuccess)
    XCTAssertTrue(
      run(["remote", "-v"], in: partial).stdoutText.contains("(fetch) [blob:none]"),
      "前提: 表示の fetch 行に部分クローンのフィルタ名が付く")
    try answer("me/r", found: "me/r")
    try servePullRequest(1, head: "feat", from: "me/r")
    let open = GitHubBranchPR(
      number: 1, headRefName: "feat", state: "OPEN", baseRefName: "main", headRepository: mine)
    try serveBranchPullRequests(
      "feat",
      #"[{"number":1,"headRefName":"feat","state":"OPEN","baseRefName":"main","#
        + #""headRepositoryOwner":{"login":"me"},"headRepository":{"name":"r"}}]"#)
    let (model, provider) = makeProvider(cwd: partial)

    provider.load()
    XCTAssertTrue(
      pump({
        self.pullRequestRow(model, 1) != nil && provider.branchPRStates["feat"] == .loaded([open])
      }))
    XCTAssertEqual(item(model, "wt-feat")?.linkedPRNumber, 1, "worktree にチップが付く")
    XCTAssertEqual(
      pullRequestRow(model, 1)?.action,
      .pullRequest(number: 1, route: .open(.worktree(path: worktree))), "PR 行は既存 worktree を開く")
  }
}
