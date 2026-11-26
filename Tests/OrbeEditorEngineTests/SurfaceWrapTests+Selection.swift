import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 折り返した行の選択・キー・変換・区間を見せる操作。壊れると、続きの段で選んだ語や行が別の所になる、⌃A・⌃E・行番号の
/// 押下が段の単位に変わる、↓ で字下げの分だけ横にずれる、候補窓が別の段に出る、⌘F の一致が画面の外に残る。
extension SurfaceWrapTests {
  /// 語が 40 個並ぶ長い行と、短い行。
  private var words: String {
    (0..<40).map { "word\($0)" }.joined(separator: " ") + "\nshort\n"
  }

  /// トリプルクリック・行番号の押下・⌃A・⌃E は、続きの段からでも文書の行の単位で動く。
  func testDocumentLineOperationsWorkOnTheWholeLineFromAContinuationSegment() throws {
    let opened = try opened(words)
    let wrap = try wrap(opened)
    let text = opened.document.text
    let line = NSRange(location: 0, length: text.lineStart(1))
    try click(opened, row: 2, column: 3, clicks: 3)
    XCTAssertEqual(opened.surface.selectedRange, line, "トリプルクリックは文書の行を改行まで選ぶ")
    let gutter = CGPoint(x: 8, y: point(opened, row: 2, column: 0).y)
    try mouse(opened, .leftMouseDown, at: gutter)
    try mouse(opened, .leftMouseUp, at: gutter)
    XCTAssertEqual(opened.surface.selectedRange, line, "続きの段の横の行番号の列を押すと、文書の行を選ぶ")
    opened.surface.selectedRange = NSRange(location: wrap.start(of: 1) + 2, length: 0)
    try key(opened, "e", .control, keyCode: 14)
    XCTAssertEqual(
      opened.surface.caretLocation, NSMaxRange(text.contentRange(ofRow: 0)), "⌃E は文書の行末")
    try key(opened, "a", .control, keyCode: 0)
    XCTAssertEqual(opened.surface.caretLocation, 0, "⌃A は文書の行の 1 列目")
  }

  /// 続きの段でダブルクリックした語が選ばれ、段をまたいでドラッグすると、押した字から離した字までが選ばれる。ドラッグが
  /// 本文の右の外へ出れば、横にはスクロールせず、ポインタの段の終わりまで伸びる。
  func testSelectingWithTheMouseFollowsTheCharactersOfEachSegment() throws {
    let opened = try opened(words)
    let wrap = try wrap(opened)
    let text = opened.document.text
    let second = wrap.start(of: 1)
    try click(opened, row: 1, column: 1, clicks: 2)
    let word =
      (text.substring(NSRange(location: second, length: wrap.start(of: 2) - second))
      as NSString).range(of: " ").location
    XCTAssertEqual(
      opened.surface.selectedRange, NSRange(location: second, length: word), "2 段目の頭の語")
    try mouse(opened, .leftMouseDown, at: point(opened, row: 0, column: 2))
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 1, column: 3))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 2, length: second + 3 - 2))
    let right = CGPoint(
      x: opened.surface.surfaceLayout.text.maxX + 40, y: point(opened, row: 1, column: 0).y)
    try mouse(opened, .leftMouseDragged, at: right)
    try mouse(opened, .leftMouseUp, at: right)
    XCTAssertEqual(
      NSMaxRange(opened.surface.selectedRange), wrap.start(of: 2), "右の外は、その段の終わりまで")
    XCTAssertEqual(opened.surface.scrollPosition.x, 0, "横にはスクロールしない")
  }

  /// ↓ は、描いた位置（続きの段の字下げを含む）を保って次の段へ動く——字下げした続きの段では、上の段と同じ x の字に入る。
  func testDownKeepsTheDrawnPositionAcrossTheContinuationIndent() throws {
    let indent = "        "
    let opened = try opened(indent + (0..<40).map { "w\($0)" }.joined(separator: " ") + "\n")
    let wrap = try wrap(opened)
    XCTAssertEqual(
      CGFloat(wrap.indent), 8 * opened.surface.config.cell, accuracy: 0.01, "前提: 8 桁の字下げ")
    opened.surface.selectedRange = NSRange(location: indent.utf16.count + 3, length: 0)
    try key(opened, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125)
    XCTAssertEqual(
      opened.surface.caretLocation, wrap.start(of: 1) + 3, "字下げの分を引いた桁ではなく、同じ x の字")
  }

  /// 変換中の未確定の字が段をまたいでも、未確定の矩形は、未確定の先頭がある段の 1 段の高さに付く。
  func testTheMarkedRectSitsOnTheSegmentWhereTheMarkedTextStarts() throws {
    let opened = try opened(words)
    let window = host(opened, size: CGSize(width: 420, height: 300))
    fakeInputMethod(opened)
    let wrap = try wrap(opened)
    opened.surface.selectedRange = NSRange(location: wrap.start(of: 2) - 2, length: 0)
    replay([.mark("かなかなかなかな")], on: opened)
    let client = opened.surface.textView
    let marked = client.markedRange()
    let rows = opened.surface.rows
    let segment = rows.segment(containing: marked.location, line: 0)
    XCTAssertEqual(segment, 1, "前提: 未確定の先頭は 2 段目")
    XCTAssertGreaterThan(
      rows.segment(containing: NSMaxRange(marked) - 1, line: 0), segment, "前提: 未確定は段をまたぐ")
    let rect = client.convert(
      window.convertFromScreen(client.firstRect(forCharacterRange: marked, actualRange: nil)),
      from: nil)
    XCTAssertEqual(rect.midY, point(opened, row: 1, column: 0).y, accuracy: 0.5, "2 段目の縦の中央")
    XCTAssertEqual(rect.height, opened.surface.config.lineHeight, accuracy: 0.5, "1 段の高さ")
  }

  /// 区間を見せると（⌘F の一致へ送る）、長い行の後ろの段にある区間でも、その段が見える。
  func testRevealingARangeInALaterSegmentShowsThatSegment() throws {
    let opened = try opened((0..<600).map { "w\($0)" }.joined(separator: " ") + "\n")
    let rows = opened.surface.rows
    let target =
      (opened.document.text.substring(
        NSRange(location: 0, length: opened.document.text.lineEnd(0))) as NSString).range(
        of: "w555")
    let segment = rows.segment(containing: target.location, line: 0)
    let viewport = opened.surface.viewport
    XCTAssertGreaterThan(
      CGFloat(segment), CGFloat(viewport.top.offset) + viewport.visibleLines, "前提: 画面の下の外")
    opened.surface.reveal(target, policy: .centerIfOutside)
    let shown = opened.surface.viewport
    XCTAssertEqual(shown.top.line, 0)
    XCTAssertLessThanOrEqual(shown.top.offset, segment)
    XCTAssertLessThan(
      CGFloat(segment), CGFloat(shown.top.offset) + shown.visibleLines, "一致の段が見える")
  }
}
