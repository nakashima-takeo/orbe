import XCTest

@testable import Orbe

/// PR の diff——古い側は PR のマージベースの版（rename なら元のパス）、新しい側は PR の先頭の版。両側とも読むだけで、PR に
/// push があれば新しい両端で作り直す。PR の中身は差し替えの構造体が答える。
///
/// 壊れると何が起きるか: rename したファイルの diff が全部の行の追加になる。PR に push があっても古い diff のまま。手元の
/// 作業ツリーの本文が新しい側に出る。打鍵で PR の diff の本文が変わる。
extension EditorDiffTests {
  /// 差し替えの構造体が返す中身（テストが書き換えて、次の読み直しに答えさせる）。
  private final class Reply {
    var content: GitHubPullRequestContent?
  }

  private func content(base: String, head: String) -> GitHubPullRequestContent {
    GitHubPullRequestContent(
      nodeID: "PR_1", number: 5, title: "題", url: "https://github.com/me/r/pull/5", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: base, headCommit: head, commitCount: 1, commits: [],
      files: [.init(path: "b.txt", change: .renamed, isViewed: false)])
  }

  /// `reply` の中身を答える PR の状態を作り、手元のリポジトリを結ぶ。
  private func pullRequest(_ reply: Reply) throws -> PullRequestState {
    let state = PullRequestState.shared(
      for: PullRequestState.Key(
        commonDir: repo.root + "/.git", id: try XCTUnwrap(GitHubItemID(repo: "me/r", number: 5))),
      source: PullRequestSource(
        branchPullRequests: { _, _, _ in }, branchExists: { _, _ in },
        content: { _, completion in
          completion(reply.content.map { .success($0) } ?? .failure(.reason("")))
        },
        setViewed: { _, _, _, _ in }))
    state.attach(repo: try repo.open(), fetchRemote: nil)
    return state
  }

  /// rename したファイルは元のパスのマージベースの版と比べ、両側とも読むだけ。PR に push があって両端が変われば、新しい
  /// 先頭の本文で作り直す。
  func testAPullRequestDiffComparesTheMergeBaseAndFollowsANewHead() throws {
    let base = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    XCTAssertTrue(repo.git(["mv", "a.txt", "b.txt"]).isSuccess)
    try repo.write("b.txt", "one\ntwo\nTHREE\nfour\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "rename and change"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    let reply = Reply()
    reply.content = content(base: base, head: head)
    let state = try pullRequest(reply)
    let (tab, _) = tab()

    let diff = try tab.group.editor.openDiff(id("b.txt", .pullRequest(state.key)), as: .pinned)

    waitRows(diff, "元のパスと比べた 1 行の変更") { self.removedLines($0) == [2] }
    XCTAssertNil(diff.document, "新しい側は版の本文で、作業ツリーの文書ではない")
    diff.newSurface?.responder.perform(Selector(("insertText:")), with: "x")
    XCTAssertEqual(diff.newRevision?.text.lineCount, 5, "打鍵で本文が変わらない")

    XCTAssertTrue(repo.git(["switch", "-q", "feat"]).isSuccess)
    try repo.write("b.txt", "one\ntwo\nTHREE\nfour\nfive\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "push"]).isSuccess)
    let pushed = repo.head()
    reply.content = content(base: base, head: pushed)
    state.reload()
    waitRows(diff, "新しい先頭で作り直す") { _ in diff.newRevision?.text.lineCount == 6 }
    XCTAssertEqual(diff.revisionHunks.count, 2, "変えた行と足した行")
  }
}
