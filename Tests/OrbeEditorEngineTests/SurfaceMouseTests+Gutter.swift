import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 行番号の列の操作の細部を VS Code の既定に照らす——押せば焦点が本文へ移り、⇧クリックは選択の動かない側の端
/// （元の区間）から伸ばし、選んだ後は動く側の端を最小限に見せる。ポインタの形は列と本文で分かれる。壊れると、行番号を
/// 押しても打鍵が本文に入らない、⇧クリックがキャレットの側から伸びて選んだ行や語が外れる、押した行の次の行頭が画面の外に
/// 残る、行番号の上で I ビームが出る。
extension SurfaceMouseTests {
  private var twenty: String { (0..<20).map { "line \($0) text" }.joined(separator: "\n") + "\n" }

  /// 行 `row`（0 始まり）を改行まで。
  private func line(_ row: Int, _ opened: Opened) -> NSRange {
    let text = opened.document.text
    return NSRange(location: text.lineStart(row), length: text.lineEnd(row) - text.lineStart(row))
  }

  private func gutter(_ opened: Opened, _ row: Int) -> CGPoint {
    CGPoint(x: 8, y: point(opened, row: row, column: 0).y)
  }

  private func pressGutter(_ opened: Opened, _ row: Int, flags: NSEvent.ModifierFlags = []) throws {
    try mouse(opened, .leftMouseDown, at: gutter(opened, row), flags: flags)
    try mouse(opened, .leftMouseUp, at: gutter(opened, row), flags: flags)
  }

  /// 番号を押すとその行を改行まで選び、焦点は本文へ移る。最終行は本文の終わりまで。
  func testPressingANumberSelectsTheLineAndFocusesTheText() throws {
    let opened = try open(twenty)
    let window = host(opened)
    window.makeFirstResponder(nil)
    try pressGutter(opened, 3)
    XCTAssertEqual(opened.surface.selectedRange, line(3, opened))
    XCTAssertTrue(window.firstResponder === opened.surface.responder, "焦点は本文へ")

    let tail = try open("a\nb")
    _ = host(tail)
    try pressGutter(tail, 1)
    XCTAssertEqual(tail.surface.selectedRange, NSRange(location: 2, length: 1), "最終行は本文の終わりまで")
  }

  /// ⇧クリックは選択の動かない側の端から押した行まで伸ばす——キャレットからなら押した行の終わりまで、列で選んだ直後なら
  /// その行が起点、列で上へ伸ばした選択なら押した行が起点、本文で左へ伸ばした選択なら右端が起点。
  func testShiftPressingANumberExtendsFromTheFixedEnd() throws {
    let opened = try open(twenty)
    _ = host(opened)
    let caret = line(3, opened).location + 2
    opened.surface.selectedRange = NSRange(location: caret, length: 0)
    try pressGutter(opened, 6, flags: .shift)
    XCTAssertEqual(
      opened.surface.selectedRange,
      NSRange(location: caret, length: NSMaxRange(line(6, opened)) - caret), "キャレットから")

    try pressGutter(opened, 8)
    try pressGutter(opened, 5, flags: .shift)
    XCTAssertEqual(
      opened.surface.selectedRange, NSUnionRange(line(5, opened), line(8, opened)), "起点は選んだ 8 行目")

    try mouse(opened, .leftMouseDown, at: gutter(opened, 8))
    try mouse(opened, .leftMouseDragged, at: gutter(opened, 6))
    try mouse(opened, .leftMouseUp, at: gutter(opened, 6))
    try pressGutter(opened, 10, flags: .shift)
    XCTAssertEqual(
      opened.surface.selectedRange, NSUnionRange(line(8, opened), line(10, opened)),
      "上へ伸ばした選択は押した 8 行目が起点")

    let end = line(3, opened).location + 4
    opened.surface.selectedRange = NSRange(location: end, length: 0)
    opened.surface.perform(.move(.left, extending: true))
    opened.surface.perform(.move(.left, extending: true))
    XCTAssertEqual(opened.surface.caretLocation, end - 2, "前提: 動く側は左端")
    try pressGutter(opened, 5, flags: .shift)
    XCTAssertEqual(
      opened.surface.selectedRange,
      NSRange(location: end, length: NSMaxRange(line(5, opened)) - end), "本文で左へ伸ばした選択は右端が起点")
  }

  /// 語を選んだ（ダブルクリック）後に上の行を ⇧クリックすると、語の終わりから伸ばす——語は選択に残る。
  func testShiftPressingANumberAfterAWordKeepsTheWord() throws {
    let opened = try open(twenty)
    _ = host(opened)
    try click(opened, row: 8, column: 1, clicks: 2)
    let word = NSRange(location: line(8, opened).location, length: 4)
    XCTAssertEqual(opened.surface.selectedRange, word, "前提: 語を選んだ")
    try pressGutter(opened, 5, flags: .shift)
    let start = line(5, opened).location
    XCTAssertEqual(
      opened.surface.selectedRange, NSRange(location: start, length: NSMaxRange(word) - start))
  }

  /// 見えている最後の行の番号を押すと、動く側の端（次の行頭）が見えるところまで縦に、行頭が見えるところまで横に、
  /// 最小限スクロールする。
  func testPressingANumberRevealsTheMovingEnd() throws {
    let long =
      (1...60).map { "line \($0) " + String(repeating: "x", count: 200) }
      .joined(separator: "\n") + "\n"
    let opened = try open(long, size: CGSize(width: 600, height: 300))
    _ = host(opened, size: CGSize(width: 600, height: 300))
    opened.surface.scroll(toX: 200)
    _ = opened.surface.snapshot()
    let lineHeight = Double(opened.surface.config.lineHeight)
    let lastVisible =
      Int((opened.surface.scrollState().limits.viewport.y / lineHeight).rounded(.down)) - 1
    try pressGutter(opened, lastVisible)
    _ = opened.surface.snapshot()
    let position = opened.surface.scrollPosition
    XCTAssertEqual(position.x, 0, "行頭が見えるところまで左へ")
    XCTAssertGreaterThan(position.y, 0, "次の行頭が見えるところまで下へ")
    XCTAssertLessThanOrEqual(position.y, 2 * lineHeight, "最小限")
  }

  /// ポインタは、行番号と印の列では矢印、本文と最終行の下の空き地では I ビーム、⌘ を押した URL の上では指（焦点があるとき）。
  func testThePointerShapeFollowsTheArea() throws {
    let opened = try open("see https://example.com/a now\n")
    _ = host(opened)
    opened.surface.updateFocus(true)
    let view = opened.surface.view
    let pointer = opened.surface.textView.pointer
    func shape(at point: CGPoint, _ flags: NSEvent.ModifierFlags = []) -> NSCursor {
      pointer.updateCursor(at: view.convert(point, to: nil), flags: flags, in: view)
      return NSCursor.current
    }
    XCTAssertEqual(shape(at: gutter(opened, 0)), .arrow, "行番号の列")
    let marks = CGPoint(
      x: opened.surface.config.columnWidth(lineCount: 2) - 3, y: point(opened, row: 0, column: 0).y)
    XCTAssertEqual(shape(at: marks), .arrow, "印の列")
    XCTAssertEqual(shape(at: point(opened, row: 0, column: 1)), .iBeam, "本文")
    XCTAssertEqual(shape(at: point(opened, row: 10, column: 1)), .iBeam, "最終行の下の空き地")
    XCTAssertEqual(shape(at: point(opened, row: 0, column: 10), .command), .pointingHand, "⌘ と URL")
    XCTAssertEqual(shape(at: point(opened, row: 0, column: 10)), .iBeam, "⌘ が無ければ URL の上も I ビーム")
  }
}
