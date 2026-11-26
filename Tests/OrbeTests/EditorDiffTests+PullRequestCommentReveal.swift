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

  /// 古い側の行のコメントの行を押すと、古い版の行の位置へ移る。古い版の行 11〜110 の 100 行を新しい 50 行に置き換えた PR で、
  /// 後ろの文脈の行（古い版の行 150 は新しい版の行 100）は、インラインで新しい版の行 100 が、並列で左の面の行 150 が見える。
  /// 置き換えた行（古い版の行 60）は、インラインで差し込んだ削除行の下のスレッドが、並列で左の面の行 60 が見える。
  func testPressingAnOldSidePendingCommentRevealsItsOldLine() throws {
    let lines = (1...300).map { "line \($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "long"]).isSuccess)
    let remote = Remote()
    remote.threads = [
      pendingThread("T_context", line: 150, side: .old),
      pendingThread("T_replaced", line: 60, side: .old),
    ]
    let opened = try commentedTab(remote) {
      let replaced = lines[..<10] + (1...50).map { "new \($0)" } + lines[110...]
      try self.repo.write("a.txt", replaced.joined(separator: "\n") + "\n")
    }
    let pane = opened.tab.group.view.editor
    let state = try XCTUnwrap(pane.pullRequest.state)
    let diff = opened.diff
    pumpMain(until: { diff.placement == .placed }, "前提: 位置を決める")
    let press = { (thread: String) in
      pane.reviewPopup.press(try XCTUnwrap(state.pendingComments.first { $0.thread == thread }))
    }

    try press("T_context")
    XCTAssertTrue(pane.diff === diff, "前提: 同じ diff のまま")
    let inline = try engine(diff.newSurface)
    XCTAssertTrue(shows(inline, line: 99), "インラインで新しい版の行 100 が見える")
    pumpMain(until: { diff.comments?.zone(thread: "T_replaced") != nil }, "前提: スレッドが置かれる")
    try press("T_replaced")
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T_replaced"))
    XCTAssertTrue(
      shows(inline, zone: zone), "インラインで、差し込んだ削除行（古い版の行 60）の下のスレッドが見える")

    resize(try XCTUnwrap(pane.window), width: Self.sideWidth)
    pumpMain(until: { diff.oldSurface != nil }, "前提: 並列")
    try press("T_replaced")
    XCTAssertTrue(shows(try engine(diff.oldSurface), line: 59), "並列で左の面の行 60 が見える")
    try press("T_context")
    XCTAssertTrue(shows(try engine(diff.oldSurface), line: 149), "並列で左の面の行 150 が見える")
  }

  /// 面 `surface` に、絵の差し込み `zone` の上端が見えているか。
  private func shows(_ surface: MetalTextSurface, zone: PrCommentZone) -> Bool {
    surface.flush()
    guard let block = surface.rows.block(ofZone: ObjectIdentifier(zone)) else { return false }
    let (first, visible) = surface.viewportLines
    let unit = surface.rows.unit(ofBlock: block)
    return unit >= Double(first) && unit < Double(first + visible)
  }

  /// 面 `surface` に、文書の行 `line`（0 始まり）が見えているか。
  private func shows(_ surface: MetalTextSurface, line: Int) -> Bool {
    surface.flush()
    let (first, visible) = surface.viewportLines
    let unit = surface.rows.unit(ofLine: line)
    return unit >= Double(first) && unit < Double(first + visible)
  }

  /// a.txt の側 `side` の行 `line` の、未送信のコメント 1 件のスレッド。
  private func pendingThread(
    _ id: String, line: Int, side: GitHubDiffSide = .new, resolved: Bool = false
  ) -> GitHubPullRequestReview.Thread {
    GitHubPullRequestReview.Thread(
      id: id, path: "a.txt", side: side, line: line, isResolved: resolved, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: [.init(id: "\(id)-C", author: "me", body: "本文", createdAt: Date(), isPending: true)]
    )
  }
}
