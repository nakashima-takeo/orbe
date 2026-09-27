import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 編集の規則（純関数）——語・書記素・行の移動と削除、字下げ、キル、入れ替え、大小文字、マーク。VS Code の既定と同じ意味で、
/// 語の規則は VS Code を動かした正解（`VSCodeEditCases`）と突き合わせる。壊れると ⌥←→・⌥⌫ が VS Code と違う位置で
/// 止まる、絵文字や CRLF を割る、Tab が文書の作法と違う字を入れる、⌃K を続けても足されない。
@MainActor
final class EditCommandsTests: XCTestCase {
  private func env(_ text: String) -> EditingEnvironment {
    Editing.environment(TextRope(text))
  }

  // MARK: - VS Code との突き合わせ

  /// ⌥←（cursorWordLeft）・⌥→（cursorWordEndRight）・⌥⌫（deleteWordLeft）・⌥⌦（deleteWordRight）・ダブルクリックの語・
  /// ⌘←（cursorHome）が、VS Code を動かした正解と全位置で一致する。
  func testWordRulesMatchVSCode() {
    XCTAssertGreaterThan(VSCodeEditCases.cases.count, 100)
    for c in VSCodeEditCases.cases {
      let text = TextRope(c.text)
      let label = "\(c.text.debugDescription) @\(c.offset)"
      XCTAssertEqual(EditCommands.wordLeft(from: c.offset, text), c.wordLeft, "⌥← \(label)")
      XCTAssertEqual(EditCommands.wordRight(from: c.offset, text), c.wordRight, "⌥→ \(label)")
      let cursor = Cursor(c.offset)
      let left = EditCommands.deleteWordLeftRange(cursor, text)
      XCTAssertEqual(Self.bounds(left), Self.nonEmpty(c.deleteLeft), "⌥⌫ \(label)")
      let right = EditCommands.deleteWordRightRange(cursor, text)
      XCTAssertEqual(Self.bounds(right), Self.nonEmpty(c.deleteRight), "⌥⌦ \(label)")
      let word = EditCommands.wordRange(at: c.offset, text)
      XCTAssertEqual([word.location, NSMaxRange(word)], c.word, "語 \(label)")
      let home = EditCommands.move(
        Cursor(c.offset), .home, extending: false, Editing.environment(text))
      XCTAssertEqual(home.position, c.home, "⌘← \(label)")
    }
  }

  private static func bounds(_ range: NSRange?) -> [Int] {
    range.map { [$0.location, NSMaxRange($0)] } ?? []
  }

  /// 消さない（空の範囲）なら空。
  private static func nonEmpty(_ bounds: [Int]) -> [Int] {
    bounds.count == 2 && bounds[0] == bounds[1] ? [] : bounds
  }

  // MARK: - 書記素と削除の単位

  /// ←→・⌦ は書記素（絵文字の ZWJ・国旗・肌の色・結合文字・CRLF）を割らない。
  func testArrowsAndForwardDeleteMoveByGraphemes() {
    let family = "👨‍👩‍👧‍👦"
    XCTAssertEqual(Editing.run(.move(.right, extending: false), on: "|\(family)x"), "\(family)|x")
    XCTAssertEqual(Editing.run(.move(.left, extending: false), on: "🇯🇵|🇺🇸"), "|🇯🇵🇺🇸")
    XCTAssertEqual(Editing.run(.deleteForward, on: "|👍🏽a"), "|a")
    XCTAssertEqual(Editing.run(.move(.right, extending: false), on: "e\u{301}|x"), "e\u{301}x|")
    XCTAssertEqual(
      Editing.run(.move(.right, extending: false), on: "ab|\r\ncd"), "ab\r\n|cd", "CRLF は 1 つ")
    XCTAssertEqual(Editing.run(.move(.left, extending: false), on: "ab\r\n|cd"), "ab|\r\ncd")
    XCTAssertEqual(Editing.run(.deleteForward, on: "ab|\r\ncd"), "ab|cd")
  }

  /// ⌫ は macOS の後ろ向きの削除の単位——絵文字の並びと CRLF は丸ごと、分解した結合文字は 1 つずつ。
  func testBackspaceDeletesByTheMacOSBackwardDeletionUnit() {
    XCTAssertEqual(Editing.run(.deleteBackward, on: "a👨‍👩‍👧‍👦|"), "a|")
    XCTAssertEqual(Editing.run(.deleteBackward, on: "🇯🇵🇺🇸|"), "🇯🇵|")
    XCTAssertEqual(Editing.run(.deleteBackward, on: "e\u{301}|"), "e|", "分解した濁点は 1 つずつ")
    XCTAssertEqual(Editing.run(.deleteBackward, on: "ab\r\n|cd"), "ab|cd")
    XCTAssertEqual(Editing.run(.deleteBackward, on: "|ab"), "|ab", "先頭は何もしない")
    XCTAssertEqual(Editing.run(.deleteBackwardDecomposing, on: "é|"), "e|", "⌃⌫ は前の字を分解して最後だけ")
  }

  /// ⌫ が字下げの空白の中なら前のタブ位置まで消す（VS Code の useTabStops）。
  func testBackspaceInIndentationDeletesToThePreviousTabStop() {
    XCTAssertEqual(Editing.run(.deleteBackward, on: "      |x"), "    |x")
    XCTAssertEqual(Editing.run(.deleteBackward, on: "    |x"), "|x")
    XCTAssertEqual(Editing.run(.deleteBackward, on: "  x  |y"), "  x |y", "字下げの外は 1 字")
    XCTAssertEqual(Editing.run(.deleteBackward, on: "\t\t|x"), "\t|x")
  }

  // MARK: - 移動

  /// ↑↓は覚えた x で動く——短い行を越えても元の横位置へ戻る。先頭の行の ↑ は文書の先頭、最終行の ↓ は文書の末尾。
  func testUpAndDownRememberTheHorizontalPosition() {
    let down = EditCommand.move(.down, extending: false)
    let up = EditCommand.move(.up, extending: false)
    XCTAssertEqual(Editing.run([down, down], on: "abcd|ef\nxy\nabcdef"), "abcdef\nxy\nabcd|ef")
    XCTAssertEqual(Editing.run([down], on: "abcd|ef\nxy\nabcdef"), "abcdef\nxy|\nabcdef")
    XCTAssertEqual(Editing.run([up], on: "ab|c\nd"), "|abc\nd")
    XCTAssertEqual(Editing.run([up, down], on: "ab|c\nd"), "abc\nd|", "先頭へ行っても横位置は覚えている")
    XCTAssertEqual(Editing.run([down], on: "a\nb|cd"), "a\nbcd|")
    XCTAssertEqual(
      Editing.run([.move(.down, extending: false)], on: "a[bc]\nxyz\n"), "abc\nxyz|\n",
      "選択を畳むときは終わりから動く")
  }

  /// ⌘← は最初の非空白と 1 列目を行き来し、⌃A は 1 列目へ、⌘→ と ⌃E は行末（CRLF の \r の前）へ。
  func testLineEdges() {
    XCTAssertEqual(Editing.run(.move(.home, extending: false), on: "  ab|c"), "  |abc")
    XCTAssertEqual(Editing.run(.move(.home, extending: false), on: "  |abc"), "|  abc")
    XCTAssertEqual(Editing.run(.move(.lineStart, extending: false), on: "  ab|c"), "|  abc")
    XCTAssertEqual(Editing.run(.move(.end, extending: false), on: "a|b\r\nc"), "ab|\r\nc")
    XCTAssertEqual(Editing.run(.move(.lineEnd, extending: true), on: "a|b\nc"), "a[b]\nc")
  }

  /// 伸ばさない ←→ は選択の端へ畳み、伸ばす移動は動かない側を保つ。
  func testCollapsingAndExtending() {
    XCTAssertEqual(Editing.run(.move(.left, extending: false), on: "a[bc]d"), "a|bcd")
    XCTAssertEqual(Editing.run(.move(.right, extending: false), on: "a[bc]d"), "abc|d")
    XCTAssertEqual(Editing.run(.move(.right, extending: true), on: "a[bc]d"), "a[bcd]")
    XCTAssertEqual(Editing.run(.move(.wordLeft, extending: true), on: "foo bar|"), "foo ]bar[")
  }

  // MARK: - 挿入と字下げ

  /// Enter は今の行の字下げ（キャレットより左の空白）を文書の作法で引き継ぐ。⌥↩ などは字下げしない。
  func testNewlineKeepsTheIndentation() {
    XCTAssertEqual(Editing.run(.newline(indents: true), on: "    ab|c"), "    ab\n    |c")
    XCTAssertEqual(Editing.run(.newline(indents: true), on: "  |  abc"), "  \n  |  abc")
    XCTAssertEqual(
      Editing.run(
        .newline(indents: true), on: "\t  ab|", indentation: .init(unit: 4, usesTabs: false)),
      "\t  ab\n      |")
    XCTAssertEqual(
      Editing.run(
        .newline(indents: true), on: "      ab|", indentation: .init(unit: 4, usesTabs: true)),
      "      ab\n\t  |")
    XCTAssertEqual(Editing.run(.newline(indents: false), on: "    ab|"), "    ab\n|")
  }

  /// Tab は文書に合わせる——空白の文書では次のタブ位置までの空白、タブの文書ではタブ文字。行をまたぐ選択は字下げ。
  func testTabFollowsTheDocument() {
    XCTAssertEqual(Editing.run(.tab, on: "ab|c"), "ab  |c")
    XCTAssertEqual(
      Editing.run(.tab, on: "ab|c", indentation: .init(unit: 4, usesTabs: true)), "ab\t|c")
    XCTAssertEqual(Editing.run(.tab, on: "a[b]c"), "a   |c", "1 行の中の選択は、始まりから次のタブ位置までの空白に置き換える")
    XCTAssertEqual(Editing.run(.tab, on: "[ab\ncd]\n"), "[    ab\n    cd]\n")
    XCTAssertEqual(
      Editing.run(.tab, on: "[ab\ncd]\n", indentation: .init(unit: 4, usesTabs: true)),
      "[\tab\n\tcd]\n")
    XCTAssertEqual(Editing.run(.literalTab, on: "a|b"), "a\t|b")
  }

  /// ⇧Tab は字下げを前のタブ位置へ戻す（空白の無い行は飛ばす）。選択の終わりが行頭なら、その行は含めない。
  func testBacktabOutdents() {
    XCTAssertEqual(Editing.run(.backtab, on: "      a|b"), "    a|b")
    XCTAssertEqual(Editing.run(.backtab, on: "[    a\nb\n  c\n]d"), "[a\nb\nc\n]d")
    XCTAssertEqual(
      Editing.run(.backtab, on: "\t\ta|", indentation: .init(unit: 4, usesTabs: true)), "\ta|")
  }

  // MARK: - 行の削除・キル

  /// ⌘⌫ は行頭まで（1 列目なら前の改行）、行末までの削除は行末まで（行末なら改行）。
  func testDeleteToLineEdges() {
    XCTAssertEqual(Editing.run(.deleteToLineStart, on: "ab\ncd|ef"), "ab\n|ef")
    XCTAssertEqual(Editing.run(.deleteToLineStart, on: "ab\n|cd"), "ab|cd")
    XCTAssertEqual(Editing.run(.deleteToLineStart, on: "ab\nc[d]e"), "ab\n|e", "選択は行頭から")
    XCTAssertEqual(Editing.run(.deleteToLineEnd, on: "a|bc\nd"), "a|\nd")
    XCTAssertEqual(Editing.run(.deleteToLineEnd, on: "abc|\r\nd"), "abc|d")
  }

  /// ⌃K は行末まで（行末なら改行）を消してキルバッファへ入れ、続けた ⌃K は後ろへ足す。⌃Y で入れる。
  func testKillAppendsWhileRepeatedAndYankInsertsIt() {
    var (text, state) = Editing.parse("a|bc\ndef\n")
    var kill = "old"
    for _ in 0..<3 {
      let result = EditCommands.run(
        .kill(forward: true), state, Editing.environment(text, killBuffer: kill))
      text = result.edits.applied(to: text)
      state = result.state
      kill = result.kill ?? kill
    }
    XCTAssertEqual(Editing.render(text, state), "a|\n")
    XCTAssertEqual(kill, "bc\ndef", "続けたキルは足す（前のキルバッファは捨てる）")
    let yanked = EditCommands.run(.yank, state, Editing.environment(text, killBuffer: kill))
    XCTAssertEqual(Editing.render(yanked.edits.applied(to: text), yanked.state), "abc\ndef|\n")
    XCTAssertFalse(yanked.state.lastWasKill)
  }

  // MARK: - 入れ替え・大小文字・マーク

  /// ⌃T はキャレットの前後の書記素を入れ替え、行末なら前の 2 つ。
  func testTranspose() {
    XCTAssertEqual(Editing.run(.transpose, on: "ab|cd"), "acb|d")
    XCTAssertEqual(Editing.run(.transpose, on: "abc|"), "acb|")
    XCTAssertEqual(Editing.run(.transpose, on: "a👍🏽|b"), "ab👍🏽|")
    XCTAssertEqual(Editing.run(.transpose, on: "|ab"), "|ab")
    XCTAssertEqual(Editing.run(.transposeWords, on: "foo |bar"), "bar foo|")
  }

  /// 大小文字は選択か、キャレットに接する語。語の外（空白の上）なら何もせず選択も元のまま。変えた範囲を選ぶ。
  func testCaseChangesTouchTheWordOrNothing() {
    XCTAssertEqual(Editing.run(.changeCase(.upper), on: "foo ba|r"), "foo [BAR]")
    XCTAssertEqual(Editing.run(.changeCase(.capitalize), on: "[hello world]"), "[Hello World]")
    XCTAssertEqual(Editing.run(.changeCase(.upper), on: "foo  |  bar"), "foo  |  bar")
    XCTAssertEqual(Editing.run(.changeCase(.lower), on: "a  |  b"), "a  |  b")
    XCTAssertEqual(Editing.run(.changeCase(.upper), on: "straße|"), "[STRASSE]", "長さが変わる字も変えた範囲を選ぶ")
  }

  /// マーク——置いた位置から選ぶ・消す（キルバッファへ）・入れ替える。
  func testMark() {
    let right = EditCommand.move(.right, extending: false)
    XCTAssertEqual(Editing.run([.setMark, right, right, .selectToMark], on: "a|bcd"), "a[bc]d")
    XCTAssertEqual(
      Editing.run([.setMark, .move(.documentEnd, extending: false), .deleteToMark], on: "a|bcd"),
      "a|")
    XCTAssertEqual(
      Editing.run([.setMark, .move(.documentEnd, extending: false), .swapWithMark], on: "a|bcd"),
      "a|bcd")
  }

  // MARK: - 選択

  /// 行の選択は改行まで（単位は行）、語の選択は VS Code の語、全体の選択は先頭から末尾。
  func testSelectLineWordAndAll() {
    XCTAssertEqual(Editing.run(.selectLine, on: "ab\nc|d\nef"), "ab\n[cd\n]ef")
    XCTAssertEqual(Editing.run(.selectWord, on: "foo.ba|r baz"), "foo.[bar] baz")
    XCTAssertEqual(Editing.run(.selectAll, on: "a|b\ncd"), "[ab\ncd]")
  }

  /// 日本語の並びでは OS の語の分割の境でも止まる（記号と空白の規則はそのまま）。
  func testJapaneseRunsStopAtOSWordBoundaries() {
    let text = TextRope("日本語のテキストです。ok")
    XCTAssertEqual(EditCommands.wordRight(from: 0, text), 2)
    XCTAssertEqual(EditCommands.wordLeft(from: 8, text), 4)
    XCTAssertEqual(EditCommands.wordRange(at: 5, text), NSRange(location: 4, length: 4))
    XCTAssertEqual(EditCommands.wordRight(from: 0, TextRope("foo.bar")), 3, "ASCII は区切り文字の規則のまま")
  }
}
