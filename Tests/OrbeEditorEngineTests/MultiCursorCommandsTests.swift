import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 複数カーソルの規則のうち、VS Code の正解表（`VSCodeMultiCursorCases`）に無いもの（純関数）——日本語の文中の語の ⌘D・
/// ⌘D の続きの終わり・全カーソルへの大小文字・入れ替え・キル。壊れると、日本語の文中で ⌘D が語を足さない・関係の無い
/// コマンドの後も ⌘D の続きが残る・⌃K や大小文字が主にしか当たらない。
@MainActor
final class MultiCursorCommandsTests: XCTestCase {
  // MARK: - ⌘D

  /// 日本語の並びの中の語も、⌥←→ と同じ語の分類で選び、同じ語を次の一致として見つける。
  func testAddNextOccurrenceFindsJapaneseWordsInsideARun() {
    let d = EditCommand.addNextOccurrence
    XCTAssertEqual(Editing.runAll([d], on: "東京|都に行く。東京タワー").0, "[東京]都に行く。東京タワー")
    XCTAssertEqual(Editing.runAll([d, d], on: "東京|都に行く。東京タワー").0, "[東京]都に行く。[東京]タワー")
  }

  /// 日本語の文中の英数字の語も、⌘D が選んだ語と同じ語を次の一致として見つける。
  func testAddNextOccurrenceFindsLatinWordsInsideJapaneseText() {
    let d = EditCommand.addNextOccurrence
    let (text, state) = Editing.runAll([d, d], on: "iPh|one15を買った。iPhone15")
    XCTAssertEqual(state.cursors.count, 2, text)
    XCTAssertEqual(
      Editing.runAll([d, d], on: "言語は「Sw|ift」です。Swift").1.cursors.count, 2)
  }

  /// ⌘D の続きは ⌘D・⌘⇧L の結果にだけ残り、それ以外のコマンドで消える。
  func testContinuationEndsWithAnyOtherCommand() {
    let d = EditCommand.addNextOccurrence
    XCTAssertNotNil(Editing.runAll([d, .selectAllOccurrences], on: "a|b ab").1.continuation)
    XCTAssertNil(Editing.runAll([d, .move(.right, extending: true)], on: "a|b ab").1.continuation)
    XCTAssertNil(Editing.runAll([d, .insert("x")], on: "a|b ab").1.continuation)
  }

  // MARK: - 全カーソルでの編集

  /// 大小文字・入れ替え・行頭までの削除・⌃K・⌃Y は、全カーソルに 1 回の操作として当たる。
  func testTextCommandsReachEveryCursor() {
    XCTAssertEqual(Editing.runAll([.changeCase(.upper)], on: "a|b c|d").0, "[AB] [CD]")
    XCTAssertEqual(Editing.runAll([.transpose], on: "ab|\ncd|").0, "ba|\ndc|")
    XCTAssertEqual(Editing.runAll([.deleteToLineStart], on: "ab|\ncd|").0, "|\n|")
    let (text, state) = Editing.parseAll("a|b\nc|d")
    let kill = EditCommands.run(.kill(forward: true), state, Editing.environment(text))
    XCTAssertEqual(Editing.renderAll(kill.edits.applied(to: text), kill.state.cursors), "a|\nc|")
    XCTAssertNotNil(kill.kill)
    let yank = EditCommands.run(.yank, state, Editing.environment(text, killBuffer: "Z"))
    XCTAssertEqual(
      Editing.renderAll(yank.edits.applied(to: text), yank.state.cursors), "aZ|b\ncZ|d")
  }
}
