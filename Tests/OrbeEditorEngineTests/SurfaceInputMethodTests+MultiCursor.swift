import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 複数カーソルの日本語入力（VS Code の composition）——変換中の文字は全カーソルに同じに出て、確定・取り消し・範囲を指した
/// 置き換えも全カーソルに同じ相対位置で当たる。相対で当てる範囲は各カーソルの行の中に収まる。壊れると、変換中の文字が主に
/// しか出ない・確定で他のカーソルの字がずれる・行頭のカーソルが前の行の改行を消す・⌘Z で一部のカーソルの字だけ残る。
extension SurfaceInputMethodTests {
  private func place(_ opened: Opened, _ cursors: [Cursor]) {
    opened.surface.inputScope {
      opened.surface.editor.select(
        CursorList(cursors[0], others: Array(cursors.dropFirst())), reveal: .none)
    }
  }

  /// 変換中の文字は全カーソルに出て、確定すると全カーソルに同じ字が入り、⌘Z 1 回で本文とカーソルの並びが戻る。
  func testCompositionReachesEveryCursor() throws {
    let opened = try open("ab\ncd\n")
    _ = host(opened)
    fakeInputMethod(opened)
    place(opened, [Cursor(1), Cursor(4)])
    replay([.mark("か"), .mark("かな")], on: opened)
    XCTAssertEqual(text(opened.document), "aかなb\ncかなd\n")
    XCTAssertEqual(
      opened.surface.drawn.caret.marked?.ranges,
      [NSRange(location: 1, length: 2), NSRange(location: 6, length: 2)], "未確定は全カーソルに出る")
    XCTAssertEqual(opened.surface.drawn.caret.carets, [3, 8], "キャレットは各カーソルの注目位置")
    replay([.insert("仮名")], on: opened)
    XCTAssertEqual(text(opened.document), "a仮名b\nc仮名d\n")
    XCTAssertEqual(
      opened.surface.cursorSelections, [3, 8].map { NSRange(location: $0, length: 0) })
    opened.surface.textView.undoManager?.undo()
    XCTAssertEqual(text(opened.document), "ab\ncd\n")
    XCTAssertEqual(
      opened.surface.cursorSelections, [1, 4].map { NSRange(location: $0, length: 0) },
      "カーソルの並びも戻る")
  }

  /// 選択のあるカーソル（⌘D の後など）で変換を始めると、選択の向きに依らず全選択が同じ未確定に置き換わり、確定は ⌘Z 1 回で
  /// 選択ごと戻る。
  func testCompositionReplacesEverySelection() throws {
    let opened = try open("ab ab\n")
    _ = host(opened)
    fakeInputMethod(opened)
    let selections = [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)]
    place(opened, [.selecting(selections[0]), .selecting(selections[1], reversed: true)])
    replay([.mark("か")], on: opened)
    XCTAssertEqual(text(opened.document), "か か\n")
    XCTAssertEqual(
      opened.surface.drawn.caret.marked?.ranges,
      [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
    replay([.insert("火")], on: opened)
    XCTAssertEqual(text(opened.document), "火 火\n")
    opened.surface.textView.undoManager?.undo()
    XCTAssertEqual(text(opened.document), "ab ab\n")
    XCTAssertEqual(opened.surface.cursorSelections, selections)
  }

  /// IME が未確定の外の範囲を指して置き換えると、各カーソルにも同じ相対位置で当たる。行頭に近いカーソルでは行の中に
  /// 収まり、前の行の改行を消さない。
  func testRelativeReplacementsStayInsideEachCursorsLine() throws {
    let opened = try open("ab\ncd\n")
    _ = host(opened)
    fakeInputMethod(opened)
    place(opened, [Cursor(2), Cursor(3)])
    replay([.mark("x", replacement: NSRange(location: 1, length: 1))], on: opened)
    XCTAssertEqual(text(opened.document), "ax\nxcd\n", "行頭のカーソルは改行を消さずに入れる")
    XCTAssertEqual(
      opened.surface.drawn.caret.marked?.ranges,
      [NSRange(location: 1, length: 1), NSRange(location: 3, length: 1)])
    replay([.insert("y")], on: opened)
    XCTAssertEqual(text(opened.document), "ay\nycd\n")
    opened.surface.textView.undoManager?.undo()
    XCTAssertEqual(text(opened.document), "ab\ncd\n")
  }

  /// 変換の取り消し（⌘Z）は全カーソルの未確定を消し、変換の前のカーソルへ戻す。
  func testCancellingTheCompositionRestoresEveryCursor() throws {
    let opened = try open("ab ab\n")
    _ = host(opened)
    fakeInputMethod(opened)
    place(opened, [Cursor(1), Cursor(4)])
    replay([.mark("か")], on: opened)
    XCTAssertEqual(text(opened.document), "aかb aかb\n")
    opened.surface.textView.undo(nil)
    XCTAssertEqual(text(opened.document), "ab ab\n")
    XCTAssertEqual(
      opened.surface.cursorSelections, [1, 4].map { NSRange(location: $0, length: 0) })
  }

  /// 変換の外で範囲を指した確定（長押しのアクセント）も、全カーソルに同じ相対位置で当たる。
  func testAccentReplacementsReachEveryCursor() throws {
    let opened = try open("ex\ny\n")
    _ = host(opened)
    fakeInputMethod(opened)
    place(opened, [Cursor(2), Cursor(3)])
    replay([.insert("é", replacement: NSRange(location: 1, length: 1))], on: opened)
    XCTAssertEqual(text(opened.document), "eé\néy\n", "行頭のカーソルは前の行の改行を消さない")
    XCTAssertEqual(
      opened.surface.cursorSelections, [2, 4].map { NSRange(location: $0, length: 0) })
  }

  /// 主と重なって変換から外れたカーソルは、変換が終わるまで外れたまま——次の候補送りや確定で入り直して、主と同じ字を
  /// もう一度入れない。
  func testACursorLeftOutOfTheCompositionStaysOut() throws {
    let opened = try open("abcdef")
    _ = host(opened)
    fakeInputMethod(opened)
    place(opened, [Cursor(6), Cursor(5)])
    replay(
      [.mark("ABC", replacement: NSRange(location: 3, length: 3)), .insert("ABC")], on: opened)
    XCTAssertEqual(text(opened.document), "abcABC")

    let other = try open("abcdef")
    _ = host(other)
    fakeInputMethod(other)
    place(other, [Cursor(4), Cursor(5)])
    replay([.mark("x", replacement: NSRange(location: 2, length: 2)), .mark("xy")], on: other)
    XCTAssertEqual(text(other.document), "abxyef")
  }

  /// 相対位置で当てた範囲は書記素の境へ外側に寄る——他のカーソルの前の絵文字のサロゲート対を割らない。
  func testRelativeTargetsDoNotSplitGraphemes() throws {
    let opened = try open("a😀")
    _ = host(opened)
    fakeInputMethod(opened)
    place(opened, [Cursor(1), Cursor(3)])
    replay([.mark("X", replacement: NSRange(location: 0, length: 1)), .insert("X")], on: opened)
    XCTAssertEqual(text(opened.document), "XX")
  }

  /// 確定した変換の正味の変化が全カーソルで同じ文字列なら、前の打鍵と同じまとまりで undo に載る（⌘Z 1 回で打鍵ごと戻る）。
  func testCommittedCompositionCoalescesWithTypingAcrossCursors() throws {
    let opened = try open("ab\ncd\n")
    _ = host(opened)
    fakeInputMethod(opened)
    place(opened, [Cursor(1), Cursor(4)])
    type(opened, "x")
    replay([.mark("か"), .insert("か")], on: opened)
    XCTAssertEqual(text(opened.document), "axかb\ncxかd\n")
    opened.surface.textView.undoManager?.undo()
    XCTAssertEqual(text(opened.document), "ab\ncd\n")
  }

  /// 行末のカーソルへ後ろへ広がる範囲を当てても、次の行の改行を消さない（行の中身に収める）。
  func testRelativeTargetsStopAtTheEndOfTheLine() throws {
    let opened = try open("ab\ncd\n")
    _ = host(opened)
    fakeInputMethod(opened)
    place(opened, [Cursor(1), Cursor(2)])
    replay([.insert("X", replacement: NSRange(location: 1, length: 1))], on: opened)
    XCTAssertEqual(text(opened.document), "aXX\ncd\n")
  }

  /// 主が文書の後ろにあっても、IME に答えるのは主の未確定とその中の選択で、確定の後の並び（主が先頭）も保つ。
  func testThePrimaryMayComeAfterTheOtherCursors() throws {
    let opened = try open("ab\ncd\n")
    _ = host(opened)
    fakeInputMethod(opened)
    place(opened, [Cursor(4), Cursor(1)])
    replay([.mark("かな")], on: opened)
    XCTAssertEqual(text(opened.document), "aかなb\ncかなd\n")
    XCTAssertEqual(opened.surface.textView.markedRange(), NSRange(location: 6, length: 2))
    XCTAssertEqual(opened.surface.textView.selectedRange(), NSRange(location: 8, length: 0))
    XCTAssertEqual(opened.surface.drawn.caret.carets, [3, 8])
    replay([.insert("仮名")], on: opened)
    XCTAssertEqual(
      opened.surface.cursorSelections, [8, 3].map { NSRange(location: $0, length: 0) })
  }
}
