import XCTest

@testable import Orbe

/// ⌘⇧X を開いたときにタスクへ結び付ける、タスクの worktree のブランチの PR を引く
/// `WorktreePullRequestResolver`。ブランチと PR の突き合わせは clean と同じ規則（head が push 先の正式名＋ブランチ名と
/// 等しいものだけ）で、選ぶのは open の最新、無ければ最新。結び付きのリポジトリは PR の URL から読む。
///
/// 壊れると何が起きるか: 他人の fork の同名ブランチに立った PR がタスクに付く。閉じた古い PR が、今レビュー中
/// の PR を差し置いて付く。fork から本体へ出した PR が、fork のリポジトリの番号として付き、存在しない PR を
/// 指す。main の worktree のタスクに、main を head にした無関係な PR が付く。
extension WorktreePaletteRemoteLedgerProviderTests {
  /// worktree ごとの PR（ブランチを見たが PR の無い worktree はキーごと無い）。
  private func resolve(_ worktrees: [String: String?]) -> [String: GitHubItemID]? {
    resolveBranches(worktrees)?.compactMapValues(\.pullRequest)
  }

  private func pullURL(_ repo: String, _ number: Int) -> String {
    "https://github.com/\(repo)/pull/\(number)"
  }

  /// 本体（org/r）へ自分の fork（me/r）から出した PR。同じ名前のブランチに立った他人の PR と、閉じた PR を
  /// 差し置いて選ばれ、本体の番号として読む。
  func testTheOpenPullRequestHeadedByTheWorktreesBranchIsChosen() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    let path = try addWorktree("wt-feat", branch: "feat")
    try serveBranchPullRequests(
      "feat",
      "["
        + [
          branchPR(9, head: "feat", state: "OPEN", from: "stranger/r", url: pullURL("org/r", 9)),
          branchPR(8, head: "feat", state: "CLOSED", from: "me/r", url: pullURL("org/r", 8)),
          branchPR(7, head: "feat", state: "OPEN", from: "me/r", url: pullURL("org/r", 7)),
        ].joined(separator: ",") + "]")

    XCTAssertEqual(
      resolve([path: "feat"]), [path: try XCTUnwrap(GitHubItemID(repo: "org/r", number: 7))])
  }

  func testWithoutAnOpenPullRequestTheLatestIsChosen() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    let path = try addWorktree("wt-feat", branch: "feat")
    try serveBranchPullRequests(
      "feat",
      "["
        + [
          branchPR(5, head: "feat", state: "MERGED", from: "me/r", url: pullURL("me/r", 5)),
          branchPR(4, head: "feat", state: "CLOSED", from: "me/r", url: pullURL("me/r", 4)),
        ].joined(separator: ",") + "]")

    XCTAssertEqual(
      resolve([path: "feat"]), [path: try XCTUnwrap(GitHubItemID(repo: "me/r", number: 5))])
  }

  /// 既定ブランチの worktree は PR の head として見ない（問い合わせもしない）。
  func testTheDefaultBranchsWorktreeGetsNoPullRequest() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(
      git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]).isSuccess)
    try serveBranchPullRequests(
      "main", "[\(branchPR(3, head: "main", state: "OPEN", from: "me/r", url: pullURL("me/r", 3)))]"
    )

    XCTAssertEqual(resolve([root: "main"]), [:])
    XCTAssertFalse(calls("H").contains("main"), "既定ブランチの PR は問い合わせない")
  }

  /// ブランチと PR の答え（ブランチを見ない worktree はキーごと無い）。
  private func resolveBranches(_ worktrees: [String: String?]) -> [String:
    WorktreeBranchPullRequest]?
  {
    var found: [String: WorktreeBranchPullRequest]?
    WorktreePullRequestResolver(gitHub: GitHubCLI(), cache: GitHubCache()).resolve(
      worktrees: worktrees
    ) {
      found = $0
    }
    XCTAssertTrue(pump { found != nil })
    return found
  }

  /// 期待が未確定（無い・既定ブランチ）なら、worktree の今のブランチ（既定ブランチ以外）を見てその PR を引き、
  /// ブランチも答える。期待が確定していれば、そのブランチにいる間だけ答える。
  func testAnUnconfirmedExpectationAnswersTheCurrentBranchAndItsPullRequest() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat"]).isSuccess)
    try serveBranchPullRequests(
      "feat", "[\(branchPR(7, head: "feat", state: "OPEN", from: "me/r", url: pullURL("me/r", 7)))]"
    )
    let feat = WorktreeBranchPullRequest(
      branch: "feat", pullRequest: try XCTUnwrap(GitHubItemID(repo: "me/r", number: 7)))

    XCTAssertEqual(resolveBranches([root: nil]), [root: feat], "記録が無い")
    XCTAssertEqual(resolveBranches([root: "main"]), [root: feat], "既定ブランチの記録")
    XCTAssertEqual(resolveBranches([root: "feat"]), [root: feat], "確定した記録と同じブランチ")
    XCTAssertTrue(git(["checkout", "-q", "-b", "other"]).isSuccess)
    XCTAssertEqual(resolveBranches([root: "feat"]), [:], "確定した記録と別のブランチ")
    XCTAssertEqual(
      resolveBranches([root: nil]),
      [root: WorktreeBranchPullRequest(branch: "other", pullRequest: nil)],
      "PR の無いブランチも答える")
  }

  /// GitHub に届かないリポジトリでも、未確定の期待にはブランチを答える（PR だけが無い）。
  func testAnUnconfirmedExpectationAnswersTheBranchWithoutGitHub() throws {
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat"]).isSuccess)

    XCTAssertEqual(
      resolveBranches([root: nil]),
      [root: WorktreeBranchPullRequest(branch: "feat", pullRequest: nil)])
    XCTAssertTrue(calls("H").isEmpty, "PR は問い合わせない")
  }
}
