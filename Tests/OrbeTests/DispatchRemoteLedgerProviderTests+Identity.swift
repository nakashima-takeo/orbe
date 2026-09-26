import XCTest

@testable import Orbe

/// 行と PR の同一性（push 先の remote のリポジトリ, ローカル名）を、実 git が解決する push 先から、
/// チップ・PR 行の行き先・clean の PR の事実まで通す。
///
/// 壊れると、base（`origin/main`）を追跡する作業ブランチに main→release のマージ済み PR が紐づいて、
/// レビュー中の worktree が clean の安全群に初期チェック付きで並ぶ。fork へ push する運用では自分の PR を
/// 見失い、確かめられない push 先の行は「確かめて 0 件」と読まれて安全確認を素通りする。
extension DispatchRemoteLedgerProviderTests {

  /// `git worktree add -b X … origin/main` で作った（base を追跡する）worktree は、自分の PR にだけ
  /// 紐づく。base から出た PR（open のリリース PR・マージ済みの main→release）はチップにも clean の
  /// 事実にも現れず、自分の PR がレビュー中なら安全群に入らない。
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
    try servePullRequests([
      pullRequestNode(1265, head: "main", from: "me/r"),
      pullRequestNode(7, head: "issue/1257", from: "me/r"),
    ])
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

    XCTAssertEqual(item(model, "wt-issue")?.linkedPRNumber, 7)
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
  /// でも、自分の fork から出た PR がその行に紐づく——チップ・PR 行の行き先・clean の事実の 3 つとも。
  /// 本家の同名ブランチから出た PR は紐づかない。
  func testTriangularForkWorkflowLinksOwnPullRequestToTheRow() throws {
    addRemote("origin", "base/r")
    addRemote("mine", "me/r")
    try answer("base/r", found: "base/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(git(["config", "remote.pushDefault", "mine"]).isSuccess)
    XCTAssertTrue(git(["update-ref", "refs/remotes/origin/main", "HEAD"]).isSuccess)
    let worktree = dir.appendingPathComponent("wt-topic").path
    XCTAssertTrue(git(["worktree", "add", "-q", "-b", "topic", worktree, "origin/main"]).isSuccess)
    try servePullRequests([
      pullRequestNode(3, head: "topic", from: "me/r"),
      pullRequestNode(4, head: "topic", from: "base/r"),
    ])
    try serveBranchPullRequests(
      "topic",
      "[\(branchPR(3, head: "topic", state: "OPEN", from: "me/r")),"
        + "\(branchPR(4, head: "topic", state: "OPEN", from: "base/r"))]")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(
      pump({
        guard case .loaded = provider.branchPRStates["topic"] else { return false }
        return self.pullRequestRow(model, 3) != nil
      }))

    XCTAssertEqual(item(model, "wt-topic")?.linkedPRNumber, 3)
    XCTAssertEqual(
      pullRequestRow(model, 3)?.action,
      .pullRequest(number: 3, route: .open(.worktree(path: worktree))))
    XCTAssertEqual(pullRequestRow(model, 4)?.action, .pullRequest(number: 4, route: .browser))
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
  /// 紐づかず、clean の PR の事実は取得失敗（安全群に入らない）。問い合わせもしない。他の行と
  /// Pull requests は普通に出る。
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
    let worktree = try addWorktree("wt-b", branch: "b")
    let heads = ["a", "u", "b"]
    try servePullRequests(
      heads.enumerated().map { pullRequestNode($0.offset + 1, head: $0.element, from: "me/r") })
    for (index, head) in heads.enumerated() {
      try serveBranchPullRequests(
        head, "[\(branchPR(index + 1, head: head, state: "OPEN", from: "me/r"))]")
    }
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(
      pump({
        guard case .loaded = provider.branchPRStates["b"] else { return false }
        return self.pullRequestRow(model, 3) != nil && !provider.pullRequestsFetching
      }))

    XCTAssertEqual(provider.branchPRStates["a"], .failed, "確かめられない remote へ push する行")
    XCTAssertEqual(provider.branchPRStates["u"], .failed, "URL の remote へ push する行")
    XCTAssertEqual(calls("H"), ["b"], "確かめられない行は問い合わせない")
    XCTAssertNil(item(model, "wt-a")?.linkedPRNumber)
    XCTAssertNil(item(model, "wt-u")?.linkedPRNumber)
    XCTAssertEqual(item(model, "wt-b")?.linkedPRNumber, 3)
    XCTAssertEqual(
      section(model, "Pull requests")?.items.map(\.idText), ["#1", "#2", "#3"],
      "情報行もローディング行も出ない")
    XCTAssertEqual(pullRequestRow(model, 1)?.action, .pullRequest(number: 1, route: .browser))
    XCTAssertEqual(pullRequestRow(model, 2)?.action, .pullRequest(number: 2, route: .browser))
    XCTAssertEqual(
      pullRequestRow(model, 3)?.action,
      .pullRequest(number: 3, route: .open(.worktree(path: worktree))))
  }
}
