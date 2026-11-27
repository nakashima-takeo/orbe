import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 折り返した行の段の端へのキーと削除。壊れると、⌘← / ⌘→ を繰り返しても段の端から先へ進めない、⌘⌫ が上の段の字まで消す、
/// 段の終わりまで選んだ後の ↓ が 1 段飛ぶ。
extension SurfaceWrapTests {
  /// ⌘← / ⌘→ は段の端へ動き、既に段の端に居れば文書の行の端へ進む。
  func testCommandArrowsGoOnToTheLineEndsFromTheSegmentEnds() throws {
    let opened = try opened()
    let wrap = try wrap(opened)
    let editor = opened.surface.editor
    let lineEnd = NSMaxRange(opened.document.text.contentRange(ofRow: 0))
    opened.surface.selectedRange = NSRange(location: wrap.start(of: 1) + 3, length: 0)
    editor.perform(.move(.home, extending: false))
    XCTAssertEqual(opened.surface.caretLocation, wrap.start(of: 1), "段の頭")
    editor.perform(.move(.home, extending: false))
    XCTAssertEqual(opened.surface.caretLocation, 0, "文書の行の最初の空白でない字")
    editor.perform(.move(.end, extending: false))
    XCTAssertEqual(opened.surface.caretLocation, wrap.start(of: 1), "段の終わり")
    XCTAssertTrue(editor.state.cursors.primary.upstream)
    editor.perform(.move(.end, extending: true))
    XCTAssertEqual(
      opened.surface.selectedRange,
      NSRange(location: wrap.start(of: 1), length: lineEnd - wrap.start(of: 1)), "⇧ つきも文書の行末へ")
  }

  /// ⌘⌫ と行末までの削除は、それぞれ ⌘⇧← / ⌘⇧→ と同じ範囲を消す——続きの段では段の頭まで、最後でない段では段の終わりまで。既に段の
  /// 端に居れば文書の行の端まで。段の端は付きで決まり、続きの段の頭から始まる選択の ⌘⌫ は選択だけを消す。
  func testCommandDeletesStopAtTheSegmentEnds() throws {
    let original = sample as NSString
    let wrap = try wrap(try opened())
    let (first, second) = (wrap.start(of: 1), wrap.start(of: 2))
    let lineEnd = original.range(of: "\n").location
    struct Case {
      let cursor: Cursor
      let command: EditCommand
      let deleted: NSRange
      let label: String
    }
    let cases = [
      Case(
        cursor: Cursor(first + 3), command: .deleteToLineStart,
        deleted: NSRange(first..<first + 3), label: "⌘⌫ は段の頭まで"),
      Case(
        cursor: Cursor(first), command: .deleteToLineStart, deleted: NSRange(0..<first),
        label: "段の頭からの ⌘⌫ は行頭まで"),
      Case(
        cursor: Cursor(second, upstream: true), command: .deleteToLineStart,
        deleted: NSRange(first..<second), label: "段の終わり（付き）からの ⌘⌫ は、その段の頭まで"),
      Case(
        cursor: Cursor.selecting(NSRange(first..<first + 3)), command: .deleteToLineStart,
        deleted: NSRange(first..<first + 3), label: "続きの段の頭から始まる選択の ⌘⌫ は選択だけ"),
      Case(
        cursor: Cursor(2), command: .deleteToLineEnd, deleted: NSRange(2..<first),
        label: "行末までの削除は段の終わりまで"),
      Case(
        cursor: Cursor(first, upstream: true), command: .deleteToLineEnd,
        deleted: NSRange(first..<lineEnd), label: "段の終わり（付き）からの行末までの削除は行末まで"),
    ]
    for item in cases {
      let opened = try opened()
      opened.surface.inputScope {
        opened.surface.editor.select(CursorList(item.cursor), reveal: .none)
      }
      opened.surface.editor.perform(item.command)
      XCTAssertEqual(
        text(opened.document), original.replacingCharacters(in: item.deleted, with: ""), item.label)
    }
  }

  /// 段の終わりで終わる選択を ↓ で畳むと、上の段の終わりから 1 段下へ動く（2 段下へ飛ばない）——前へ伸ばした選択でも、
  /// 後ろへ伸ばした選択でも、Esc で畳んだキャレットからでも。
  func testCollapsingASelectionThatEndsAtASegmentEndMovesFromTheUpperSegment() throws {
    let opened = try opened()
    let wrap = try wrap(opened)
    XCTAssertGreaterThanOrEqual(wrap.segments, 3, "前提")
    let editor = opened.surface.editor
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    editor.perform(.move(.end, extending: true))
    editor.perform(.move(.down, extending: false))
    XCTAssertEqual(
      opened.surface.rows.segment(
        containing: opened.surface.caretLocation, line: 0,
        upstream: editor.state.cursors.primary.upstream),
      1)
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    editor.perform(.move(.end, extending: false))
    editor.perform(.move(.home, extending: true))
    editor.perform(.move(.down, extending: false))
    XCTAssertEqual(
      opened.surface.rows.segment(
        containing: opened.surface.caretLocation, line: 0,
        upstream: editor.state.cursors.primary.upstream),
      1, "段の終わりで終わる、後ろへ伸ばした選択からも 1 段下")
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    editor.perform(.move(.end, extending: true))
    editor.perform(.cancel)
    editor.perform(.move(.down, extending: false))
    XCTAssertEqual(
      opened.surface.rows.segment(
        containing: opened.surface.caretLocation, line: 0,
        upstream: editor.state.cursors.primary.upstream),
      1, "Esc で畳んだキャレットからも 1 段下")
  }

  /// 段の終わりまで選んだ選択を → で畳むと、動く端の付きを保ち、キャレットは選択の地が終わる上の段の終わりに残る。
  func testCollapsingRightKeepsTheMovingEndOnTheUpperSegment() throws {
    let opened = try opened()
    let wrap = try wrap(opened)
    let editor = opened.surface.editor
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    editor.perform(.move(.end, extending: true))
    editor.perform(.move(.right, extending: false))
    XCTAssertEqual(opened.surface.caretLocation, wrap.start(of: 1))
    XCTAssertTrue(editor.state.cursors.primary.upstream, "上の段の終わり")
  }

  /// 続きの段からのページ送りは、送った段の数だけ離れた段へキャレットを動かす（文書の行の単位で飛ばない）。
  func testPagingMovesTheCaretByTheScrolledSegments() throws {
    let opened = try opened((0..<600).map { "w\($0)" }.joined(separator: " ") + "\n")
    let surface = opened.surface
    let editor = surface.editor
    surface.selectedRange = NSRange(location: try wrap(opened).start(of: 2) + 1, length: 0)
    func segment() -> Int {
      surface.rows.segment(
        containing: surface.caretLocation, line: 0, upstream: editor.state.cursors.primary.upstream)
    }
    let top = surface.viewport.top.offset
    editor.perform(.move(.pageDown, extending: false))
    let scrolled = surface.viewport.top.offset - top
    XCTAssertGreaterThan(scrolled, 1, "前提: 1 段より多く送る")
    XCTAssertEqual(surface.viewport.top.line, 0, "前提: 同じ文書の行の中")
    XCTAssertEqual(segment(), 2 + scrolled, "送った段の数だけ下の段")
    editor.perform(.move(.pageUp, extending: false))
    XCTAssertEqual(segment(), 2, "戻すと元の段")
  }

  /// ⌥⌘↓ は、キャレットの 1 段下——折り返した行では、同じ文書の行の次の段——にカーソルを足す（段の終わり（付き）の
  /// キャレットからは、次の段にキャレットを足す）。
  func testInsertingACursorBelowAddsItOnTheNextSegment() throws {
    let opened = try opened()
    let wrap = try wrap(opened)
    let editor = opened.surface.editor
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    editor.perform(.insertCursor(below: true))
    let added = editor.state.cursors.all.map(\.position).filter { $0 != 2 }
    XCTAssertEqual(added.count, 1, "前提: 1 本足す")
    XCTAssertEqual(
      opened.surface.rows.segment(containing: added[0], line: 0), 1, "同じ文書の行の 2 段目")
    XCTAssertLessThan(added[0], wrap.start(of: 2))
    let upstream = try self.opened()
    upstream.surface.selectedRange = NSRange(location: 2, length: 0)
    upstream.surface.editor.perform(.move(.end, extending: false))
    upstream.surface.editor.perform(.insertCursor(below: true))
    let cursors = upstream.surface.editor.state.cursors.all
    XCTAssertEqual(cursors.count, 2, "前提: 1 本足す")
    XCTAssertTrue(cursors.allSatisfy { $0.selection.length == 0 }, "段の終わり（付き）から足しても選択を作らない")
    XCTAssertEqual(
      cursors.map {
        upstream.surface.rows.segment(containing: $0.position, line: 0, upstream: $0.upstream)
      }
      .sorted(), [0, 1], "上の段の終わりと、次の段")
  }

  /// 段の終わりより右を右クリックすると、キャレットは段の終わり（付き）に入り、続く ↓ はその段から 1 段下へ動く。
  func testRightClickingPastASegmentEndPlacesTheCaretAtItsEnd() throws {
    let opened = try opened()
    let wrap = try wrap(opened)
    let host = RecordingHost()
    opened.surface.host = host
    let view = opened.surface.textView
    let at = CGPoint(
      x: opened.surface.surfaceLayout.text.maxX - 2, y: point(opened, row: 0, column: 0).y)
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: view.convert(at, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))
    _ = view.menu(for: event)
    XCTAssertEqual(host.menus, 1, "前提: メニューを出した")
    let editor = opened.surface.editor
    XCTAssertEqual(opened.surface.caretLocation, wrap.start(of: 1))
    XCTAssertTrue(editor.state.cursors.primary.upstream, "段の終わり")
    editor.perform(.move(.down, extending: false))
    XCTAssertEqual(
      opened.surface.rows.segment(
        containing: opened.surface.caretLocation, line: 0,
        upstream: editor.state.cursors.primary.upstream),
      1, "1 段目から 1 段下")
  }
}
