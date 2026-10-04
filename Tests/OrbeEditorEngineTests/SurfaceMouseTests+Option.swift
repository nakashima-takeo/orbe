import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// ⌥ のマウス（VS Code の `CreateCursor` と `LastCursor*Select`）——⌥クリックでカーソルを足し、既存のカーソルの上なら
/// 外す。⌥ドラッグは足した 1 本だけを伸ばし、⌥ダブル／トリプルクリックは足した 1 本を語／行にする。行番号の列は行で足す。
/// 壊れると、⌥クリックが他のカーソルを消す・外せない・ドラッグで他のカーソルまで伸びる・ダブルクリックでカーソルが
/// 増え続ける・選択の上の ⌥押下でドラッグ＆ドロップが始まる。
extension SurfaceMouseTests {
  private var lines: String { "foo bar baz\nqux quux\nend\n" }

  private func cursors(_ opened: Opened) -> [NSRange] {
    opened.surface.cursorSelections
  }

  /// ⌥クリックはカーソルを足し、カーソルが 2 本以上で押した位置がどれかの選択の中（両端を含む）なら、そのカーソルを外す。
  func testOptionClickAddsAndRemovesCursors() throws {
    let opened = try open(lines)
    _ = host(opened)
    try click(opened, row: 0, column: 1)
    try click(opened, row: 1, column: 2, flags: .option)
    XCTAssertEqual(
      cursors(opened), [NSRange(location: 1, length: 0), NSRange(location: 14, length: 0)])
    try click(opened, row: 2, column: 1, flags: .option)
    XCTAssertEqual(cursors(opened).count, 3)
    try click(opened, row: 1, column: 2, flags: .option)
    XCTAssertEqual(
      cursors(opened), [NSRange(location: 1, length: 0), NSRange(location: 22, length: 0)],
      "既存のカーソルの上なら外す")
    try click(opened, row: 0, column: 1, flags: .option)
    XCTAssertEqual(cursors(opened), [NSRange(location: 22, length: 0)], "主を外せば次のカーソルが主")
    try click(opened, row: 2, column: 1, flags: .option)
    XCTAssertEqual(cursors(opened), [NSRange(location: 22, length: 0)], "1 本なら外さない（まとまる）")
  }

  /// ⌥ドラッグは足した 1 本だけを伸ばす。途中で他のカーソルに重なってまとまっても、戻せば元に分かれる。
  func testOptionDragExtendsOnlyTheAddedCursor() throws {
    let opened = try open(lines)
    _ = host(opened)
    try click(opened, row: 0, column: 1)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 0, column: 6), flags: .option)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 9), flags: .option)
    XCTAssertEqual(
      cursors(opened), [NSRange(location: 1, length: 0), NSRange(location: 6, length: 3)])
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 0), flags: .option)
    XCTAssertEqual(cursors(opened), [NSRange(location: 0, length: 6)], "重なればまとまる")
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 8), flags: .option)
    XCTAssertEqual(
      cursors(opened), [NSRange(location: 1, length: 0), NSRange(location: 6, length: 2)],
      "戻せば元に分かれる")
    try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 8), flags: .option)
  }

  /// ⌥ダブルクリックは足した 1 本を語に、⌥トリプルクリックは行にする（増え続けない）。
  func testOptionMultiClicksTurnTheAddedCursorIntoAWordOrLine() throws {
    let opened = try open(lines)
    _ = host(opened)
    try click(opened, row: 0, column: 1)
    try click(opened, row: 1, column: 5, flags: .option)
    try click(opened, row: 1, column: 5, clicks: 2, flags: .option)
    XCTAssertEqual(
      cursors(opened), [NSRange(location: 1, length: 0), NSRange(location: 16, length: 4)])
    try click(opened, row: 1, column: 5, clicks: 3, flags: .option)
    XCTAssertEqual(
      cursors(opened), [NSRange(location: 1, length: 0), NSRange(location: 12, length: 9)])
  }

  /// 行番号の列の ⌥クリックは行で足し、同じ行の ⌥クリックで外す。
  func testOptionClickOnTheGutterAddsLines() throws {
    let opened = try open(lines)
    _ = host(opened)
    try click(opened, row: 0, column: 1)
    let gutter = CGPoint(x: 8, y: point(opened, row: 1, column: 0).y)
    try mouse(opened, .leftMouseDown, at: gutter, flags: .option)
    try mouse(opened, .leftMouseUp, at: gutter, flags: .option)
    XCTAssertEqual(
      cursors(opened), [NSRange(location: 1, length: 0), NSRange(location: 12, length: 9)])
    try mouse(opened, .leftMouseDown, at: gutter, flags: .option)
    try mouse(opened, .leftMouseUp, at: gutter, flags: .option)
    XCTAssertEqual(cursors(opened), [NSRange(location: 1, length: 0)], "足すはずの行の動く端で外す")
  }

  /// 選択の上の ⌥押下は本文のドラッグを始めず、カーソルを足す。⇧⌥クリックは ⇧クリックのまま（1 本に伸ばす）。
  func testOptionPressOnASelectionAddsACursorAndShiftOptionExtends() throws {
    let opened = try open(lines)
    _ = host(opened)
    opened.surface.selectedRange = NSRange(location: 4, length: 3)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 0, column: 5), flags: .option)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 0, column: 10), flags: .option)
    XCTAssertNil(opened.surface.textView.draggedRange, "本文のドラッグは始まらない")
    try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 10), flags: .option)
    XCTAssertEqual(cursors(opened), [NSRange(location: 4, length: 6)], "足した 1 本が伸びて主にまとまる")
    XCTAssertEqual(text(opened.document), lines)
    try click(opened, row: 1, column: 1, flags: [.shift, .option])
    XCTAssertEqual(cursors(opened), [NSRange(location: 4, length: 9)], "⇧⌥ は主から 1 本に伸ばす")
  }
}
