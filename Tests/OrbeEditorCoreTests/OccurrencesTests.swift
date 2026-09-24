import Foundation
import XCTest

@testable import OrbeEditorCore

/// 出現の強調の規則（VS Code の `SelectionHighlighter` と `WordHighlighter` の textual provider）。壊れると、選択した
/// 文字列の他の出現が出ない・選択自身に地が被る・空白の選択で全体が光る、キャレットの語が区切りを越えて広がる・
/// 部分一致まで光る、検索バーの一致と二重に出る。
final class OccurrencesTests: XCTestCase {
  func testSelectionOccurrencesAreCaseInsensitiveAndExcludeTheSelection() {
    let text = "foo Foo foo\nfoofoo"
    let selection = NSRange(location: 4, length: 3)
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: selection, in: text, findNeedle: nil, findFieldFocused: false),
      [
        NSRange(location: 0, length: 3), NSRange(location: 8, length: 3),
        NSRange(location: 12, length: 3), NSRange(location: 15, length: 3),
      ], "大小無視・語の境界なし・選択自身は除く")
  }

  func testSelectionOccurrencesDropMatchesStartingBeforeAndOverlappingTheSelection() {
    let text = "aaaa"
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: NSRange(location: 1, length: 2), in: text, findNeedle: nil, findFieldFocused: false),
      [NSRange(location: 2, length: 2)], "選択より前に始まって交差する一致（0..<2）は除き、選択の中から始まる一致は残す")
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: NSRange(location: 0, length: 2), in: "aaaaa", findNeedle: nil, findFieldFocused: false),
      [NSRange(location: 2, length: 2)])
  }

  func testSelectionOccurrencesNeedASingleLineNonBlankShortSelection() {
    let text = "ab ab\nab  ab"
    let none = { (range: NSRange) in
      Occurrences.selectionOccurrences(
        of: range, in: text, findNeedle: nil, findFieldFocused: false)
    }
    XCTAssertEqual(none(NSRange(location: 0, length: 0)), [], "空の選択")
    XCTAssertEqual(none(NSRange(location: 3, length: 4)), [], "複数行")
    XCTAssertEqual(none(NSRange(location: 8, length: 2)), [], "空白だけ")
    let long = String(repeating: "x", count: 201)
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: NSRange(location: 0, length: 201), in: long + " " + long, findNeedle: nil,
        findFieldFocused: false), [], "200 字を超える")
  }

  func testSelectionOccurrencesStepAsideForTheFindBar() {
    let text = "ab ab ab"
    let selection = NSRange(location: 0, length: 2)
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: selection, in: text, findNeedle: "AB", findFieldFocused: false), [],
      "検索バーが同じ文字列（大小無視）を探している")
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: selection, in: text, findNeedle: "zz", findFieldFocused: true), [],
      "検索語が空でない入力欄に焦点がある")
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: selection, in: text, findNeedle: "zz", findFieldFocused: false
      ).count, 2)
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: selection, in: text, findNeedle: "", findFieldFocused: true
      ).count, 2)
  }

  func testWordAtTheCaretUsesTheDefaultWordDefinition() {
    let line = "  let foo_bar = a.b(-1.5e3)"
    func word(_ location: Int, _ length: Int = 0) -> String? {
      Occurrences.word(
        at: NSRange(location: 100 + location, length: length), line: line, lineStart: 100
      )
      .map {
        (line as NSString).substring(with: NSRange(location: $0.location - 100, length: $0.length))
      }
    }
    XCTAssertEqual(word(7), "foo_bar")
    XCTAssertEqual(word(6), "foo_bar", "語の先頭に接する")
    XCTAssertEqual(word(13), "foo_bar", "語の末尾に接する")
    XCTAssertEqual(word(17), "a", "区切り文字で切れる（左の語が先）")
    XCTAssertEqual(word(18), "b")
    XCTAssertEqual(word(22), "-1.5e3", "数は小数点と符号を含む")
    XCTAssertNil(word(1), "空白の中")
    XCTAssertEqual(word(6, 3), "foo_bar", "語の内側の選択")
    XCTAssertEqual(word(6, 7), "foo_bar", "ちょうど 1 語の選択")
    XCTAssertNil(word(6, 9), "語をはみ出す選択")
  }

  func testWordOccurrencesAreCaseSensitiveWithWordBoundaries() {
    let text = "foo foo_x Foo (foo) xfoo foo"
    XCTAssertEqual(
      Occurrences.wordOccurrences(of: NSRange(location: 0, length: 3), in: text),
      [
        NSRange(location: 0, length: 3), NSRange(location: 15, length: 3),
        NSRange(location: 25, length: 3),
      ])
  }
}
