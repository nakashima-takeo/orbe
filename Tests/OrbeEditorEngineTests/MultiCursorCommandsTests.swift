import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// カーソルを増やす・減らす規則（純関数。VS Code の `MultiCursorSelectionController`・`CursorMoveCommands.addCursorDown`・
/// `CursorCollection.normalize`・`cancelSelection`）。壊れると、⌘D が大文字違いや語の一部まで足す・空のキャレットから語を
/// 選ばない・⌘⇧L の主が押した場所から飛ぶ・⌥⌘↓ が短い行を越えて横位置を失う・Esc で主の選択まで消える・重なった
/// カーソルの向きが最後に足したものに倣わない。
@MainActor
final class MultiCursorCommandsTests: XCTestCase {
  // MARK: - ⌘D

  /// 空のキャレットからの ⌘D は語を選び、続けると語の単位・大小区別で次の出現を足し、末尾まで無ければ先頭へ回る（選ばれて
  /// いれば変わらない）。
  func testAddNextOccurrenceFromACaretSelectsWholeWords() {
    let d = EditCommand.addNextOccurrence
    let text = "foo b|ar Bar bar barx bar"
    XCTAssertEqual(Editing.runAll([d], on: text).0, "foo [bar] Bar bar barx bar")
    XCTAssertEqual(Editing.runAll([d, d], on: text).0, "foo [bar] Bar [bar] barx bar")
    XCTAssertEqual(Editing.runAll([d, d, d], on: text).0, "foo [bar] Bar [bar] barx [bar]")
    let (wrapped, state) = Editing.runAll([d, d, d, d], on: text)
    XCTAssertEqual(wrapped, "foo [bar] Bar [bar] barx [bar]", "回って選ばれていれば変わらない")
    XCTAssertEqual(state.continuation, SearchQuestion(needle: "bar", rule: .word))
    XCTAssertEqual(state.cursors.primary.selection, NSRange(location: 4, length: 3), "主は最初の語")
  }

  /// 選択からの ⌘D は ⌘F と同じ規則（大小を区別しない素の文字列）で探す。
  func testAddNextOccurrenceFromASelectionUsesTheFindRule() {
    let d = EditCommand.addNextOccurrence
    XCTAssertEqual(Editing.runAll([d], on: "[ab]c AB xab").0, "[ab]c [AB] xab")
    let (all, state) = Editing.runAll([d, d], on: "[ab]c AB xab")
    XCTAssertEqual(all, "[ab]c [AB] x[ab]")
    XCTAssertEqual(state.continuation, SearchQuestion(needle: "ab", rule: .find))
  }

  /// 続きが無く、カーソルが複数で選択がそろっていなければ（空の選択があるか文字列が違えば）、空のカーソルを語に広げるだけ。
  func testAddNextOccurrenceExpandsEmptyCursorsWhenSelectionsDiffer() {
    let d = EditCommand.addNextOccurrence
    let (expanded, state) = Editing.runAll([d], on: "a|bc x|yz abc")
    XCTAssertEqual(expanded, "[abc] [xyz] abc")
    XCTAssertNil(state.continuation, "続きは作らない")
    XCTAssertEqual(Editing.runAll([d], on: "[abc] abc| abc").0, "[abc] [abc] abc")
    XCTAssertEqual(
      Editing.runAll([d, d], on: "a|bc x|yz abc").0, "[abc] [xyz] abc", "広げた後は文字列が違うので広げるだけ")
    XCTAssertEqual(
      Editing.runAll([d, d], on: "[abc] abc| abc").0, "[abc] [abc] [abc]", "そろえば主から続きを作る")
  }

  /// 日本語の並びの中の語も、⌥←→ と同じ語の分類で選び、同じ語を次の一致として見つける。
  func testAddNextOccurrenceFindsJapaneseWordsInsideARun() {
    let d = EditCommand.addNextOccurrence
    XCTAssertEqual(Editing.runAll([d], on: "東京|都に行く。東京タワー").0, "[東京]都に行く。東京タワー")
    XCTAssertEqual(Editing.runAll([d, d], on: "東京|都に行く。東京タワー").0, "[東京]都に行く。[東京]タワー")
  }

  /// 語に接していないキャレットの ⌘D は何もしない。
  func testAddNextOccurrenceWithoutAWordDoesNothing() {
    let (text, state) = Editing.runAll([.addNextOccurrence], on: "a  |  b")
    XCTAssertEqual(text, "a  |  b")
    XCTAssertNil(state.continuation)
  }

  /// ⌘D の続きは ⌘D・⌘⇧L の結果にだけ残り、それ以外のコマンドで消える。
  func testContinuationEndsWithAnyOtherCommand() {
    let d = EditCommand.addNextOccurrence
    XCTAssertNotNil(Editing.runAll([d, .selectAllOccurrences], on: "a|b ab").1.continuation)
    XCTAssertNil(Editing.runAll([d, .move(.right, extending: true)], on: "a|b ab").1.continuation)
    XCTAssertNil(Editing.runAll([d, .insert("x")], on: "a|b ab").1.continuation)
  }

  // MARK: - ⌘⇧L

  /// ⌘⇧L は ⌘D と同じ規則の全出現を選び、押したときの主の選択に重なる出現を主にする。
  func testSelectAllOccurrencesKeepsThePrimaryWhereItWas() {
    let (fromSelection, state) = Editing.runAll(
      [.selectAllOccurrences], on: "x ab y AB [ab] z")
    XCTAssertEqual(fromSelection, "x [ab] y [AB] [ab] z")
    XCTAssertEqual(state.cursors.primary.selection, NSRange(location: 10, length: 2))
    let (fromCaret, caret) = Editing.runAll([.selectAllOccurrences], on: "ab x a|b y abc")
    XCTAssertEqual(fromCaret, "[ab] x [ab] y abc", "空のキャレットからは語の規則")
    XCTAssertEqual(caret.cursors.primary.selection, NSRange(location: 5, length: 2))
  }

  /// 出現が上限を越えても、主の出現は残る（後ろから切る）。
  func testSelectAllOccurrencesBeyondTheLimitKeepsThePrimary() {
    let count = CursorList.limit + 5
    let marked = String(repeating: "a ", count: count - 1) + "|a"
    let (_, state) = Editing.runAll([.selectAllOccurrences], on: marked)
    XCTAssertEqual(state.cursors.count, CursorList.limit)
    XCTAssertEqual(
      state.cursors.primary.selection, NSRange(location: 2 * (count - 1), length: 1), "押した場所の出現が主")
  }

  // MARK: - ⌥⌘↑↓

  /// ⌥⌘↓ は各カーソルの 1 行下に同じ形のカーソルを足す。横位置は↓と同じく覚えた位置へ戻り、選択の両端とも写す。最終行の
  /// 下・先頭行の上には足さない。
  func testInsertCursorBelowAndAboveKeepTheHorizontalPosition() {
    let down = EditCommand.insertCursor(below: true)
    let up = EditCommand.insertCursor(below: false)
    XCTAssertEqual(Editing.runAll([down], on: "ab|c\nx\nabcd").0, "ab|c\nx|\nabcd")
    XCTAssertEqual(
      Editing.runAll([down, down], on: "ab|c\nx\nabcd").0, "ab|c\nx|\nab|cd", "短い行を越えて横位置へ戻る")
    XCTAssertEqual(Editing.runAll([down], on: "a[bc]\nxyz").0, "a[bc]\nx[yz]")
    XCTAssertEqual(Editing.runAll([down], on: "abc\nx|y").0, "abc\nx|y", "最終行の下には足さない")
    XCTAssertEqual(Editing.runAll([up], on: "a|bc\nxy").0, "a|bc\nxy", "先頭行の上には足さない")
    XCTAssertEqual(Editing.runAll([up], on: "abc\nx|y").0, "a|bc\nx|y")
    let (_, state) = Editing.parseAll("ab|c\nx\nabcd")
    let result = EditCommands.run(down, state, Editing.environment(TextRope("abc\nx\nabcd")))
    XCTAssertEqual(result.revealing, NSRange(location: 5, length: 0), "いちばん下のカーソルを見せる")
  }

  // MARK: - Esc

  /// Esc は、カーソルが複数なら主の 1 本に戻し（主の選択は残す）、1 本で選択があれば動く端のキャレットにする。
  func testCancelCollapsesToThePrimaryThenClearsTheSelection() {
    XCTAssertEqual(Editing.runAll([.cancel], on: "[ab] [ab]").0, "[ab] ab")
    XCTAssertEqual(Editing.runAll([.cancel], on: "[ab] [ab]", primary: 1).0, "ab [ab]")
    XCTAssertEqual(Editing.runAll([.cancel, .cancel], on: "[ab] [ab]").0, "ab| ab")
    XCTAssertEqual(Editing.runAll([.cancel], on: "]ab[ x").0, "|ab x", "動く端（前へ伸ばした選択なら先頭）")
    XCTAssertEqual(Editing.runAll([.cancel], on: "a|b").0, "a|b")
  }

  // MARK: - カーソルの列

  /// 重なったカーソルは 1 本にまとまり、列で先にある方の場所に残る。向きは、負けた方が最後に足したカーソルならそちら、
  /// そうでなければ勝った方（VS Code の `normalize`）。
  func testNormalizeFollowsTheLastAddedCursorsDirection() {
    func list(_ cursors: [Cursor]) -> CursorList {
      var list = CursorList(cursors[0], others: Array(cursors.dropFirst()))
      list.normalize()
      return list
    }
    let forward = Cursor.selecting(NSRange(location: 0, length: 3))
    let backward = Cursor.selecting(NSRange(location: 2, length: 3), reversed: true)
    let merged = list([forward, backward])
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged.primary.selection, NSRange(location: 0, length: 5))
    XCTAssertTrue(merged.primary.isReversed, "最後に足した方の向き")
    let notLast = list([forward, backward, Cursor(10)])
    XCTAssertEqual(notLast.count, 2)
    XCTAssertFalse(notLast.primary.isReversed, "最後に足したのでなければ勝った方の向き")
    let same = list([Cursor.selecting(NSRange(location: 1, length: 2)), Cursor(1), Cursor(1)])
    XCTAssertEqual(same.count, 1)
  }

  /// カーソルは上限を越えない——主と先にあるものを残して後ろから切る。
  func testCursorListKeepsThePrimaryAndEarlierCursorsWithinTheLimit() {
    let list = CursorList(Cursor(0), others: (1...CursorList.limit + 4).map { Cursor($0 * 2) })
    XCTAssertEqual(list.count, CursorList.limit)
    XCTAssertEqual(list.primary, Cursor(0))
    XCTAssertEqual(list.last, Cursor((CursorList.limit - 1) * 2))
  }
}
