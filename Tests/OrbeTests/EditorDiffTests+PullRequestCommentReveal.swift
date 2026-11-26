import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// レビューのポップアップの未送信のコメントの行から、その場所へ移る——ポップアップが閉じ、そのファイルの PR の diff が本体に
/// 出て、コメントの行が見える位置に来て、畳んだスレッドが開く。PR の中身とレビューのやりとりは差し替えの構造体が答える。
///
/// 壊れると何が起きるか: 未送信のコメントの行を押しても、別のファイルの diff のままになる。diff の先頭（最初の変更区間）に出て、
/// コメントの行を探し直すことになる。解決済みで畳んだスレッドが畳まれたままで、コメントが見えない。同じファイルの diff を
/// 見ている間に押しても、その行へ動かない。
extension EditorDiffTests {
  /// ほかのファイルの diff を見ている間に、行 150 にある、解決済みで畳んだスレッドの未送信のコメントの行を押すと、ポップアップが
  /// 閉じ、そのファイルの diff が出て行 150 が見え、スレッドが開く。続けて同じファイルの行 80 のコメントの行を押すと、行 80 へ動く。
  func testPressingAPendingCommentRevealsItsLineAndOpensItsThread() throws {
    var lines = (1...200).map { "line \($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "long"]).isSuccess)
    let remote = Remote()
    remote.threads = [
      pendingThread("T_far", line: 150, resolved: true),
      pendingThread("T_mid", line: 80, resolved: false),
    ]
    let opened = try commentedTab(remote) {
      lines[2] = "THREE"
      try self.repo.write("a.txt", lines.joined(separator: "\n") + "\n")
      try self.repo.write("b.txt", "b\n")
      XCTAssertTrue(self.repo.git(["add", "b.txt"]).isSuccess)
    }
    let pane = opened.tab.group.view.editor
    let state = try XCTUnwrap(pane.pullRequest.state)
    _ = try open(state, path: "b.txt", into: opened.tab)
    XCTAssertEqual(pane.diff?.id.path, "b.txt", "前提: ほかのファイルの diff を見ている")
    let review = pane.reviewPopup
    pumpMain(until: { review.canOpen }, "前提: レビューを開ける")
    review.toggle()
    XCTAssertTrue(review.isOpen, "前提: ポップアップが開く")

    review.press(try XCTUnwrap(state.pendingComments.first { $0.thread == "T_far" }))
    XCTAssertFalse(review.isOpen, "ポップアップが閉じる")
    let diff = try XCTUnwrap(pane.diff)
    XCTAssertEqual(diff.id.path, "a.txt", "そのファイルの diff が出る")
    pumpMain(until: { diff.placement == .placed && diff.newSurface != nil }, "位置を決める")
    let surface = try engine(diff.newSurface)
    XCTAssertTrue(shows(surface, line: 149), "行 150 が見える")
    pumpMain(until: { diff.comments?.zone(thread: "T_far") != nil }, "スレッドが置かれる")
    XCTAssertEqual(diff.comments?.zone(thread: "T_far")?.isCollapsed, false, "畳んだスレッドが開く")

    review.press(try XCTUnwrap(state.pendingComments.first { $0.thread == "T_mid" }))
    XCTAssertTrue(pane.diff === diff, "前提: 同じ diff のまま")
    XCTAssertTrue(shows(surface, line: 79), "同じファイルの diff でも行 80 へ動く")
  }

  /// 面 `surface` に、文書の行 `line`（0 始まり）が見えているか。
  private func shows(_ surface: MetalTextSurface, line: Int) -> Bool {
    surface.flush()
    let (first, visible) = surface.viewportLines
    let unit = surface.rows.unit(ofLine: line)
    return unit >= Double(first) && unit < Double(first + visible)
  }

  /// a.txt の新しい側の行 `line` の、未送信のコメント 1 件のスレッド。
  private func pendingThread(_ id: String, line: Int, resolved: Bool)
    -> GitHubPullRequestReview.Thread
  {
    GitHubPullRequestReview.Thread(
      id: id, path: "a.txt", side: .new, line: line, isResolved: resolved, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: [.init(id: "\(id)-C", author: "me", body: "本文", createdAt: Date(), isPending: true)]
    )
  }
}
