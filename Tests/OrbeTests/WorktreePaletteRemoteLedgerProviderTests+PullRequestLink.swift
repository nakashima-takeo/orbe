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
  private func resolve(_ worktrees: [String]) -> [String: GitHubItemID]? {
    var found: [String: GitHubItemID]?
    WorktreePullRequestResolver(gitHub: GitHubCLI(), cache: GitHubCache()).resolve(
      worktrees: worktrees
    ) {
      found = $0
    }
    XCTAssertTrue(pump { found != nil })
    return found
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

    XCTAssertEqual(resolve([path]), [path: try XCTUnwrap(GitHubItemID(repo: "org/r", number: 7))])
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

    XCTAssertEqual(resolve([path]), [path: try XCTUnwrap(GitHubItemID(repo: "me/r", number: 5))])
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

    XCTAssertEqual(resolve([root]), [:])
    XCTAssertFalse(calls("H").contains("main"), "既定ブランチの PR は問い合わせない")
  }
}
