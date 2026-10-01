import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 本文へ落とす受け口——落とす位置の印をドラッグの間だけ同じ 1 コマに出し、他のアプリの文字は貼るときと同じ改行で入れ、この
/// 面から運んだ文字は移動（⌥ ならコピー）にし、Finder のファイルは載せる側へ開かせる。壊れると CRLF の文書に LF が混ざる・
/// 印が残る・移動が元の字を残す・外部変更の後の落としが関係の無い字を消す・ファイルの名前が本文に入る。
extension SurfaceClipboardTests {
  /// 他のアプリの文字——ドラッグの間は落とす位置に印を出し（外れたら消す）、落とすと文書の改行の作法で入って選ばれる。
  func testDroppingTextFromAnotherAppInsertsItWithTheDocumentLineBreak() throws {
    let opened = try open("ab\r\ncd\r\n")
    _ = host(opened)
    let view = opened.surface.textView
    let drag = FakeDraggingInfo(
      at: view.convert(point(opened, row: 1, column: 1), to: nil),
      pasteboard: try dragBoard(string: "x\ny"), operations: .copy)
    XCTAssertEqual(view.draggingEntered(drag), .copy)
    XCTAssertEqual(opened.surface.drawn.drop, 5, "落とす位置の印")
    view.draggingExited(drag)
    XCTAssertNil(opened.surface.drawn.drop, "外れたら消す")
    _ = view.draggingUpdated(drag)
    XCTAssertTrue(view.performDragOperation(drag))
    view.concludeDragOperation(drag)
    XCTAssertEqual(text(opened.document), "ab\r\ncx\r\nyd\r\n")
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 5, length: 4), "落とした文字列を選ぶ")
    XCTAssertNil(opened.surface.drawn.drop)
  }

  /// この面から運んだ文字は移動で、1 回の undo で戻る。送り手が移動を許さない（⌥）ならコピーで、元の字を残す。
  func testDroppingOwnTextMovesItOrCopiesWithOption() throws {
    let opened = try open("abc def\n")
    _ = host(opened)
    let view = opened.surface.textView
    let board = try dragBoard(string: "abc")
    let end = view.convert(point(opened, row: 0, column: 7), to: nil)
    view.draggedRange = NSRange(location: 0, length: 3)
    let move = FakeDraggingInfo(at: end, pasteboard: board, source: view)
    XCTAssertEqual(view.draggingUpdated(move), .move)
    XCTAssertTrue(view.performDragOperation(move))
    XCTAssertEqual(text(opened.document), " defabc\n")
    try XCTUnwrap(view.undoManager).undo()
    XCTAssertEqual(text(opened.document), "abc def\n", "移動は 1 回の undo で戻る")

    view.draggedRange = NSRange(location: 0, length: 3)
    let copy = FakeDraggingInfo(at: end, pasteboard: board, source: view, operations: .copy)
    XCTAssertEqual(view.draggingUpdated(copy), .copy)
    XCTAssertTrue(view.performDragOperation(copy))
    XCTAssertEqual(text(opened.document), "abc defabc\n", "元の字を残す")
  }

  /// ドラッグの途中で本文が丸ごと差し替わったら、この面から運んだ文字でもコピーとして落とす（古い位置の字を消さない）。
  func testDroppingAfterReplacingFromDiskCopiesInsteadOfMoving() throws {
    let opened = try open("abc def\n")
    _ = host(opened)
    let view = opened.surface.textView
    view.draggedRange = NSRange(location: 0, length: 3)
    opened.surface.replaceAll(with: "xyz uvw\n")
    let drop = FakeDraggingInfo(
      at: view.convert(point(opened, row: 0, column: 7), to: nil),
      pasteboard: try dragBoard(string: "abc"), source: view)
    XCTAssertTrue(view.performDragOperation(drop))
    XCTAssertEqual(text(opened.document), "xyz uvwabc\n")
  }

  /// Finder のファイルは、本文へ落とすと載せる側に開かせ、本文には何も入れず印も出さない。
  func testDroppingFinderFilesAsksTheHostToOpenThem() throws {
    let opened = try open("abc\n")
    _ = host(opened)
    let hostSide = RecordingHost()
    opened.surface.host = hostSide
    let view = opened.surface.textView
    let file = URL(fileURLWithPath: "/tmp/a.txt")
    let board = try dragBoard(string: nil)
    board.writeObjects([file as NSURL])
    let drop = FakeDraggingInfo(
      at: view.convert(point(opened, row: 0, column: 1), to: nil), pasteboard: board,
      operations: .copy)
    XCTAssertEqual(view.draggingUpdated(drop), .copy)
    XCTAssertNil(opened.surface.drawn.drop)
    XCTAssertTrue(view.performDragOperation(drop))
    XCTAssertEqual(hostSide.openedFiles, [[file]])
    XCTAssertEqual(text(opened.document), "abc\n")
  }

  /// 落とすときの判断——ファイルは開き（⇧ ならパス）、この面のドラッグは移動（コピーならコピー）で選択の中（両端を含む）へは
  /// 落とさず、コピーの端なら隣へ写し、他の送り手の文字はコピーで入れる。
  func testDropRules() {
    let files = [URL(fileURLWithPath: "/tmp/a.txt")]
    let dragged = NSRange(location: 4, length: 3)
    func plan(
      _ offset: Int?, files: [URL]? = nil, string: String? = "s", dragged: NSRange? = nil,
      copying: Bool = false, shift: Bool = false, opensFiles: Bool = true
    ) -> DropPlan {
      DropRules.plan(
        DropSituation(
          offset: offset, files: files, string: string, dragged: dragged, copying: copying,
          shift: shift, opensFiles: opensFiles))
    }
    XCTAssertEqual(plan(nil), DropPlan(), "本文の外")
    XCTAssertEqual(plan(2, files: files), DropPlan(operation: .copy, action: .open(files)))
    XCTAssertEqual(
      plan(2, files: files, shift: true),
      DropPlan(operation: .copy, indicator: 2, action: .insertPaths(files, at: 2)))
    XCTAssertEqual(plan(2, files: files, opensFiles: false), DropPlan(), "載せる側がいなければ受けない")
    XCTAssertEqual(plan(2, string: nil), DropPlan(), "平文もファイルも無い")
    XCTAssertEqual(
      plan(2), DropPlan(operation: .copy, indicator: 2, action: .insert("s", at: 2, moving: nil)),
      "他の送り手はコピー")
    XCTAssertEqual(
      plan(0, dragged: dragged),
      DropPlan(operation: .move, indicator: 0, action: .insert("s", at: 0, moving: dragged)))
    for inside in [4, 5, 7] {
      XCTAssertEqual(plan(inside, dragged: dragged), DropPlan(), "選択の中へは移さない（\(inside)）")
    }
    XCTAssertEqual(plan(5, dragged: dragged, copying: true), DropPlan(), "コピーでも内側へは写さない")
    for edge in [4, 7] {
      XCTAssertEqual(
        plan(edge, dragged: dragged, copying: true),
        DropPlan(operation: .copy, indicator: edge, action: .insert("s", at: edge, moving: nil)),
        "コピーで端なら隣へ写す（\(edge)）")
    }
  }

  /// ドラッグの板（名前つきの専用のもの）。
  private func dragBoard(string: String?) throws -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("dev.orbe.test.\(UUID().uuidString)"))
    addTeardownBlock { board.releaseGlobally() }
    board.clearContents()
    if let string { board.setString(string, forType: .string) }
    return board
  }
}
