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
    XCTAssertEqual(cursors(opened), [NSRange(location: 22, length: 0)])
    try click(opened, row: 2, column: 1, flags: .option)
    XCTAssertEqual(cursors(opened), [NSRange(location: 22, length: 0)], "1 本なら外さない（まとまる）")
  }

  /// 外す判定は選択の両端を含む——選択の始まりや終わりを ⌥クリックしても、そのカーソルを外す。
  func testOptionClickOnEitherEndOfASelectionRemovesThatCursor() throws {
    let opened = try open(lines)
    _ = host(opened)
    for column in [0, 3] {
      opened.surface.inputScope {
        opened.surface.editor.select(
          CursorList(.selecting(NSRange(location: 0, length: 3)), others: [Cursor(22)]),
          reveal: .none)
      }
      try click(opened, row: 0, column: CGFloat(column), flags: .option)
      XCTAssertEqual(cursors(opened), [NSRange(location: 22, length: 0)], "桁 \(column)")
    }
  }

  /// 主を外せば、列で次のカーソル（文書の順ではなく足した順）が主になる。
  func testRemovingThePrimaryPromotesTheNextCursorInTheList() throws {
    let opened = try open(lines)
    _ = host(opened)
    try click(opened, row: 0, column: 1)
    try click(opened, row: 2, column: 1, flags: .option)
    try click(opened, row: 1, column: 2, flags: .option)
    try click(opened, row: 0, column: 1, flags: .option)
    XCTAssertEqual(
      cursors(opened), [NSRange(location: 22, length: 0), NSRange(location: 14, length: 0)])
  }

  /// 素のクリックの後に ⌥ を押した 2 回目は、素のダブルクリックと同じく語を選ぶ。⌥クリックでカーソルを外した直後の
  /// ⌥ダブルクリックは何もしない（残ったカーソルを畳まない）。
  func testOptionOnlyOnTheSecondClickActsLikeAPlainDoubleClick() throws {
    let opened = try open(lines)
    _ = host(opened)
    try click(opened, row: 1, column: 5)
    try click(opened, row: 1, column: 5, clicks: 2, flags: .option)
    XCTAssertEqual(cursors(opened), [NSRange(location: 16, length: 4)])

    try click(opened, row: 0, column: 1)
    try click(opened, row: 2, column: 1, flags: .option)
    try click(opened, row: 2, column: 1, flags: .option)
    try click(opened, row: 2, column: 1, clicks: 2, flags: .option)
    XCTAssertEqual(cursors(opened), [NSRange(location: 1, length: 0)])
  }

  /// ⌥ドラッグの途中で本文が変われば、マウスの操作はそこで終わる（押す前の古い位置のカーソルを置き直さない）。
  func testAnEditDuringAnOptionDragEndsTheDrag() throws {
    let opened = try open(lines)
    _ = host(opened)
    try click(opened, row: 0, column: 1)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 1, column: 2), flags: .option)
    opened.surface.perform(.insert("Z"))
    let typed = cursors(opened)
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 1, column: 6), flags: .option)
    try mouse(opened, .leftMouseUp, at: point(opened, row: 1, column: 6), flags: .option)
    XCTAssertEqual(cursors(opened), typed)
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

  /// 行番号の列の ⌥クリックで外す判定は、足すはずの行のカーソルの動く端（次の行頭）で取る——その行頭のカーソルが外れる。
  func testRemovingFromTheGutterUsesTheMovingEndOfTheLine() throws {
    let opened = try open(lines)
    _ = host(opened)
    try click(opened, row: 0, column: 1)
    try click(opened, row: 2, column: 0, flags: .option)
    let gutter = CGPoint(x: 8, y: point(opened, row: 1, column: 0).y)
    try mouse(opened, .leftMouseDown, at: gutter, flags: .option)
    try mouse(opened, .leftMouseUp, at: gutter, flags: .option)
    XCTAssertEqual(cursors(opened), [NSRange(location: 1, length: 0)])
  }

  /// 行番号の列の ⌥クリックは行で足す。
  func testOptionClickOnTheGutterAddsLines() throws {
    let opened = try open(lines)
    _ = host(opened)
    try click(opened, row: 0, column: 1)
    let gutter = CGPoint(x: 8, y: point(opened, row: 1, column: 0).y)
    try mouse(opened, .leftMouseDown, at: gutter, flags: .option)
    try mouse(opened, .leftMouseUp, at: gutter, flags: .option)
    XCTAssertEqual(
      cursors(opened), [NSRange(location: 1, length: 0), NSRange(location: 12, length: 9)])
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
