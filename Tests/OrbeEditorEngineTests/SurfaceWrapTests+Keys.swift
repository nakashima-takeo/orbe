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

  /// ⌘⌫ と ⌘⌦ は ⌘⇧← / ⌘⇧→ と同じ範囲を消す——続きの段では段の頭まで、最後でない段では段の終わりまで。
  func testCommandDeletesStopAtTheSegmentEnds() throws {
    let original = sample as NSString
    let left = try opened()
    let wrap = try wrap(left)
    left.surface.selectedRange = NSRange(location: wrap.start(of: 1) + 3, length: 0)
    left.surface.editor.perform(.deleteToLineStart)
    XCTAssertEqual(
      text(left.document),
      original.replacingCharacters(in: NSRange(location: wrap.start(of: 1), length: 3), with: ""),
      "⌘⌫ は段の頭まで")
    let right = try opened()
    right.surface.selectedRange = NSRange(location: 2, length: 0)
    right.surface.editor.perform(.deleteToLineEnd)
    XCTAssertEqual(
      text(right.document),
      original.replacingCharacters(
        in: NSRange(location: 2, length: wrap.start(of: 1) - 2), with: ""),
      "⌘⌦ は段の終わりまで")
  }

  /// 段の終わりまで選んだ（付きのある）選択を ↓ で畳むと、上の段の終わりから 1 段下へ動く（2 段下へ飛ばない）。
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

  /// ⌥⌘↓ は、キャレットの 1 段下——折り返した行では、同じ文書の行の次の段——にカーソルを足す。
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
  }
}
