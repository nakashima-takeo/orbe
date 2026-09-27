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
    XCTAssertEqual(
      opened.surface.selectedRange, NSRange(location: 4, length: 25 - 4), "上へ伸ばすと語の始まりまで")
    XCTAssertEqual(opened.surface.caretLocation, 4)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 5), clicks: 2)
    try click(opened, row: 2, column: 3, flags: .shift)
    XCTAssertEqual(
      opened.surface.selectedRange, NSRange(location: 22, length: 31 - 22), "⇧クリックも語の単位で、元の語から")
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
    let host = RecordingHost()
    opened.surface.host = host
    let on = point(opened, row: 0, column: 10)
    try mouse(opened, .leftMouseDown, at: on, flags: .command)
    try mouse(opened, .leftMouseUp, at: on, flags: .command)
    XCTAssertEqual(host.links, [URL(string: "https://example.com/a")!])
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 0), "選択は動かない")
    try mouse(opened, .leftMouseDown, at: on, flags: .command)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 20), flags: .command)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 20), flags: .command)
    XCTAssertEqual(host.links.count, 1, "動かして離せば開かない")
    XCTAssertEqual(opened.surface.selectedRange.length, 0, "その間は選択が伸びない")
    try click(opened, row: 0, column: 10)
    XCTAssertEqual(host.links.count, 1, "素のクリックはキャレットを置くだけ")
    XCTAssertEqual(opened.surface.caretLocation, 10)
  }

  /// 右から左の字を含む行でも、押した字の見た目の位置にキャレットが置かれる（ヘブライ語・アラビア語・混在の行）。右から
  /// 左の並びの中では、字の右の縁が字の前。
  func testClicksLandOnRightToLeftCharacters() throws {
    let opened = try open("ab שלום cd\nمرحبا\nאבג 12\n")
    _ = host(opened)
    let config = opened.surface.config
    let column = config.columnWidth(lineCount: opened.document.text.lineCount)
    for (row, offset) in [(0, 4), (0, 6), (1, 2), (2, 1)] {
      let x = caretX(opened, row: row, offset: offset)
      let y = config.topInset + (CGFloat(row) + 0.5) * config.lineHeight
      try mouse(opened, .leftMouseDown, at: CGPoint(x: column + x - 1, y: y))
      try mouse(opened, .leftMouseUp, at: CGPoint(x: column + x - 1, y: y))
      XCTAssertEqual(
        opened.surface.caretLocation, opened.document.text.lineStart(row) + offset,
        "行 \(row) の位置 \(offset) の字の右の縁のすぐ左")
    }
  }

  /// 4 回以上のクリックの全体は、その後のドラッグで縮まない（VS Code と同じ）。
  func testFourClicksSelectAllAndDraggingKeepsIt() throws {
    let opened = try open(sample)
    _ = host(opened)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 1, column: 5), clicks: 4)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 1, column: 7), clicks: 4)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 1, column: 7), clicks: 4)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 32))
  }

  /// 4 回のクリックの全体の選択は、⌘A と同じく位置を動かさない（VS Code の `SelectAll` も見せにいかない）。
  func testFourClicksSelectAllWithoutScrolling() throws {
    let opened = try open((0..<3000).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 600, height: 400))
    try click(opened, row: 1, column: 2, clicks: 4)
    XCTAssertEqual(opened.surface.selectedRange.length, opened.document.text.length)
    XCTAssertEqual(opened.surface.scroll.peek(at: 0).position.y, 0, "末尾へ飛ばない")
    XCTAssertEqual(opened.document.viewportLines.first, 0)
  }

  /// マウスの押下として面へ届いた ⌃クリックは、選択を動かさない（AppKit は、右クリックのメニューがあれば押下を送らずに
  /// メニューを出す。メニューが無ければ押下が届く）。
  func testControlClickArrivingAsMouseDownLeavesTheSelection() throws {
    let opened = try open(sample)
    _ = host(opened)
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    try click(opened, row: 1, column: 5, flags: .control)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 2, length: 0))
    let gutter = CGPoint(x: 8, y: point(opened, row: 1, column: 0).y)
    try mouse(opened, .leftMouseDown, at: gutter, flags: .control)
    try mouse(opened, .leftMouseUp, at: gutter, flags: .control)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 2, length: 0), "行番号の列")
  }

  /// 行番号の列の上へのドラッグは、動く側の端をポインタの行の行頭に置き、押した行は選択に残る。押した行へ戻れば押した行だけ。
  /// 最終行は本文の終わりまで選ぶ。
  func testGutterDragUpwardKeepsThePressedLine() throws {
    let opened = try open("a\nbb\nccc\ndddd")
    _ = host(opened)
    let text = opened.document.text
    let gutter = { (row: Int) in CGPoint(x: 8, y: self.point(opened, row: row, column: 0).y) }
    try mouse(opened, .leftMouseDown, at: gutter(2))
    try mouse(opened, .leftMouseDragged, at: gutter(0))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: text.lineStart(3)))
    XCTAssertEqual(opened.surface.caretLocation, 0, "動く側の端は先頭")
    try mouse(opened, .leftMouseDragged, at: gutter(2))
    try mouse(opened, .leftMouseUp, at: gutter(2))
    XCTAssertEqual(
      opened.surface.selectedRange,
      NSRange(location: text.lineStart(2), length: text.lineStart(3) - text.lineStart(2)))
    try mouse(opened, .leftMouseDown, at: gutter(3))
    try mouse(opened, .leftMouseUp, at: gutter(3))
    XCTAssertEqual(
      opened.surface.selectedRange,
      NSRange(location: text.lineStart(3), length: text.length - text.lineStart(3)), "最終行")
  }
}
