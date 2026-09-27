import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面のマウス——クリックの回数で単位（文字・語・行・全体）が決まり、その後のドラッグと ⇧クリックは単位と起点の範囲を
/// 保って伸びる。行番号の列は行の単位、URL の ⌘クリックは離したときに開く。壊れると、クリックした字とキャレットの位置が
/// 違う、ダブルクリックのドラッグが字の単位で伸びる、遠くへ飛んだ直後のクリックが別の行に当たる、ドラッグで URL が開く。
@MainActor
final class SurfaceMouseTests: EngineTestCase {
  private let sample = "let value = 1\nfoo.bar baz\n  qux\n"

  func testClickCountsChooseTheUnit() throws {
    let opened = try open(sample)
    _ = host(opened)
    try click(opened, row: 1, column: 5)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 19, length: 0))
    try click(opened, row: 1, column: 5, clicks: 2)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 18, length: 3), "語")
    try click(opened, row: 1, column: 5, clicks: 3)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 14, length: 12), "行（改行まで）")
    try click(opened, row: 1, column: 5, clicks: 4)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 32), "全体")
  }

  /// ダブルクリックの後のドラッグと ⇧クリックは語の単位のまま伸び、元の語は選択に残る。
  func testDragAndShiftClickKeepTheWordUnit() throws {
    let opened = try open(sample)
    _ = host(opened)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 1, column: 9), clicks: 2)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 5), clicks: 2)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 4, length: 25 - 4), "上へ伸ばすと語の始まりまで")
    XCTAssertEqual(opened.surface.caretLocation, 4)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 5), clicks: 2)
    try click(opened, row: 2, column: 3, flags: .shift)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 22, length: 31 - 22), "⇧クリックも語の単位で、元の語から")
  }

  /// 最終行より下の空き地を押すとキャレットは末尾へ。遠くへ飛んだ直後でも、ポインタの下の行に当たる。
  func testClicksBelowTheLastLineAndAfterAFarJump() throws {
    let opened = try open(sample)
    _ = host(opened)
    try click(opened, row: 20, column: 2)
    XCTAssertEqual(opened.surface.caretLocation, 32)
    let long = try open((0..<5000).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(long)
    long.document.scroll(toFirstLine: 4000)
    try click(long, row: 0, column: 4)
    XCTAssertEqual(long.document.text.row(containing: long.surface.caretLocation), 4000)
    XCTAssertEqual(long.surface.caretLocation, long.document.text.lineStart(4000) + 4)
  }

  /// 行番号の列を押すと行を改行まで選び、ドラッグは行の単位で伸びる。⇧↓ で伸ばした後の ⇧クリックは元の行から。
  /// git の印の列は何もしない。
  func testGutterSelectsLines() throws {
    let opened = try open(sample)
    _ = host(opened)
    let gutter = { (row: Int) in CGPoint(x: 8, y: self.point(opened, row: row, column: 0).y) }
    try mouse(opened, .leftMouseDown, at: gutter(1))
    try mouse(opened, .leftMouseDragged, at: gutter(2))
    try mouse(opened, .leftMouseUp, at: gutter(2))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 14, length: 32 - 14))
    try mouse(opened, .leftMouseDown, at: gutter(0))
    try mouse(opened, .leftMouseUp, at: gutter(0))
    opened.surface.perform(.move(.down, extending: true))
    try mouse(opened, .leftMouseDown, at: gutter(2), flags: .shift)
    try mouse(opened, .leftMouseUp, at: gutter(2), flags: .shift)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 32), "元の行（0）から")
    let marks = CGPoint(
      x: opened.surface.config.columnWidth(lineCount: 4) - 3, y: gutter(1).y)
    try mouse(opened, .leftMouseDown, at: marks)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 32), "印の列は何もしない")
  }

  /// ⌘だけのクリックは URL を離したときに開き、動かして離せば開かない（その間は選択も伸びない）。
  func testCommandClickOpensALinkOnRelease() throws {
    let opened = try open("see https://example.com/a now\n")
    _ = host(opened)
    var opens: [URL] = []
    opened.surface.onOpenLink = { opens.append($0) }
    let on = point(opened, row: 0, column: 10)
    try mouse(opened, .leftMouseDown, at: on, flags: .command)
    try mouse(opened, .leftMouseUp, at: on, flags: .command)
    XCTAssertEqual(opens, [URL(string: "https://example.com/a")!])
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 0), "選択は動かない")
    try mouse(opened, .leftMouseDown, at: on, flags: .command)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 20), flags: .command)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 20), flags: .command)
    XCTAssertEqual(opens.count, 1, "動かして離せば開かない")
    XCTAssertEqual(opened.surface.selectedRange.length, 0, "その間は選択が伸びない")
    try click(opened, row: 0, column: 10)
    XCTAssertEqual(opens.count, 1, "素のクリックはキャレットを置くだけ")
    XCTAssertEqual(opened.surface.caretLocation, 10)
  }

  /// ドラッグが本文の下へ出ると、ポインタが止まっていても自動スクロールし、選択が見えている下端の行まで伸び続ける。
  func testDraggingBelowTheTextAutoscrollsAndExtends() throws {
    let opened = try open((0..<500).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 600, height: 400))
    try mouse(opened, .leftMouseDown, at: point(opened, row: 1, column: 1))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 200, y: 460))
    let pointer = (opened.surface.responder as? MetalTextView)?.pointer
    pointer?.frame(now: 10)
    pointer?.frame(now: 10.5)
    pointer?.frame(now: 11)
    let (first, visible) = opened.document.viewportLines
    XCTAssertGreaterThan(first, 20, "0.5 秒ごとに外れた距離に応じた速さで送る")
    let caretRow = CGFloat(opened.document.text.row(containing: opened.surface.caretLocation))
    XCTAssertEqual(caretRow, (first + visible - 0.01).rounded(.down), accuracy: 1, "見えている下端の行まで伸びる")
    XCTAssertEqual(opened.surface.selectedRange.location, opened.document.text.lineStart(1) + 1)
    try mouse(opened, .leftMouseUp, at: CGPoint(x: 200, y: 460))
  }
}
