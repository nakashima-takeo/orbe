import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorText

/// 行番号の列の操作を VS Code（a890ad31）の既定に照らす——⇧クリックは選択の元の区間（`selectionStart`）から伸ばし、選んだ
/// 後は動く側の端を見せ（`revealAllCursors`）、ドラッグ中の行番号の上は本文の左の外として横に自動スクロールする
/// （`LeftRightDragScrolling`）。
extension EditorLineNumbersTests {
  /// 行を選んで ⇧↓ で伸ばした後の ⇧クリックは、選んだ行（元の区間）から伸ばす——上の行を ⇧クリックすれば元の行も選択に
  /// 残る。
  func testShiftClickAfterExtendingByKeyboardKeepsTheSelectedLine() throws {
    let opened = try open(lines(20))
    let document = opened.document
    try click(opened, row: 5)
    document.surface.responder.perform(
      #selector(NSResponder.moveDownAndModifySelection(_:)), with: nil)
    XCTAssertEqual(
      document.surface.selectedRange,
      NSUnionRange(range(of: 5, in: document), range(of: 6, in: document)), "前提: ⇧↓ で 1 行伸びた")
    try click(opened, row: 3, .shift)
    XCTAssertEqual(
      document.surface.selectedRange,
      NSUnionRange(range(of: 3, in: document), range(of: 5, in: document)), "5 行目を含む")
    XCTAssertEqual(document.surface.caretLocation, range(of: 3, in: document).location)
  }

  /// 語を選んだ（ダブルクリック）後に上の行を ⇧クリックすると、語の終わりから伸ばす——語は選択に残る。
  func testShiftClickAfterSelectingAWordKeepsTheWord() throws {
    let opened = try open(lines(20))
    let document = opened.document
    let word = NSRange(location: range(of: 8, in: document).location, length: 4)
    document.surface.selectedRange = NSRange(location: word.location + 1, length: 0)
    document.surface.responder.perform(#selector(NSTextView.selectWord(_:)), with: nil)
    XCTAssertEqual(document.surface.selectedRange, word, "前提: 語を選んだ")
    try click(opened, row: 5, .shift)
    XCTAssertEqual(
      document.surface.selectedRange,
      NSRange(
        location: range(of: 5, in: document).location,
        length: NSMaxRange(word)
          - range(of: 5, in: document).location))
  }

  /// 見えている最後の行を押すと、動く側の端（次の行頭）が見えるところまで縦に、行頭が見えるところまで横に、最小限
  /// スクロールする。
  func testClickingRevealsTheMovingEnd() throws {
    let long = (1...60).map { "line \($0) " + String(repeating: "x", count: 200) + "\n" }.joined()
    let opened = try open(long)
    let clip = opened.scroll.contentView
    clip.scroll(to: NSPoint(x: 200, y: 0))
    opened.scroll.reflectScrolledClipView(clip)
    let lastVisible = (clip.bounds.height / style.lineHeight).rounded(.down)
    try click(opened, row: lastVisible)
    XCTAssertEqual(clip.bounds.minX, 0, "行頭が見えるところまで左へ")
    XCTAssertGreaterThan(clip.bounds.minY, 0, "次の行頭が見えるところまで下へ")
    XCTAssertLessThanOrEqual(clip.bounds.minY, 2 * style.lineHeight, "最小限")
  }

  /// ドラッグ中、ポインタが行番号の上（本文の左の外）にあれば、止まっていても本文を左へ横スクロールし、ポインタの行まで
  /// 伸ばす。本文の上へ出れば止まる。
  func testDraggingOverTheNumbersScrollsTheTextLeft() throws {
    let long = (1...60).map { "line \($0) " + String(repeating: "x", count: 400) + "\n" }.joined()
    let opened = try open(long)
    let document = opened.document
    let column = opened.column
    let clip = opened.scroll.contentView
    var clock: CFTimeInterval = 0
    column.mouseDown(with: try mouse(.leftMouseDown, opened, row: 3))
    clip.scroll(to: NSPoint(x: 600, y: 0))
    opened.scroll.reflectScrolledClipView(clip)
    column.mouseDragged(with: try mouse(.leftMouseDragged, opened, row: 5))
    XCTAssertTrue(column.isAutoscrolling)
    XCTAssertEqual(
      document.surface.selectedRange,
      NSUnionRange(range(of: 3, in: document), range(of: 5, in: document)))
    frames(column, 3, clock: &clock)
    XCTAssertLessThan(clip.bounds.minX, 600, "左へ送る")
    frames(column, 50, clock: &clock)
    XCTAssertEqual(clip.bounds.minX, 0, "左端で止まる")
    column.mouseDragged(
      with: try mouse(.leftMouseDragged, opened, row: 5, x: column.bounds.width + 30))
    XCTAssertFalse(column.isAutoscrolling, "本文の上へ出れば止まる")
    column.mouseUp(with: try mouse(.leftMouseUp, opened, row: 5, x: column.bounds.width + 30))
  }
}
