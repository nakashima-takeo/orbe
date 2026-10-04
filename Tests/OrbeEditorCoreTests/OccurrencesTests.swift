import Foundation
import XCTest

@testable import OrbeEditorCore

/// 出現の強調の規則（VS Code の `SelectionHighlighter` と `WordHighlighter` の textual provider）。壊れると、選択した
/// 文字列の他の出現が出ない・選択自身に地が被る・空白の選択で全体が光る、キャレットの語が区切りを越えて広がる・
/// 部分一致まで光る、検索バーの一致と二重に出る。
final class OccurrencesTests: XCTestCase {
  /// 選択 1 つから決めた問いの出現（1 本のカーソルの強調）。
  private static func selectionOccurrences(
    of selection: NSRange, in text: TextRope, findNeedle: String?, findFieldFocused: Bool
  ) -> [NSRange] {
    guard let question = SearchQuestion.of([selection], continuing: nil, in: text) else {
      return []
    }
    return Occurrences.selectionOccurrences(
      of: question, selections: [selection], in: text, findNeedle: findNeedle,
      findFieldFocused: findFieldFocused)
  }

  func testSelectionOccurrencesAreCaseInsensitiveAndExcludeTheSelection() {
    let text = "foo Foo foo\nfoofoo"
    let selection = NSRange(location: 4, length: 3)
    XCTAssertEqual(
      Self.selectionOccurrences(
        of: selection, in: TextRope(text), findNeedle: nil, findFieldFocused: false),
      [
        NSRange(location: 0, length: 3), NSRange(location: 8, length: 3),
        NSRange(location: 12, length: 3), NSRange(location: 15, length: 3),
      ], "大小無視・語の境界なし・選択自身は除く")
  }

  func testSelectionOccurrencesDropMatchesStartingBeforeAndOverlappingTheSelection() {
    let text = "aaaa"
    XCTAssertEqual(
      Self.selectionOccurrences(
        of: NSRange(location: 1, length: 2), in: TextRope(text), findNeedle: nil,
        findFieldFocused: false),
      [NSRange(location: 2, length: 2)], "選択より前に始まって交差する一致（0..<2）は除き、選択の中から始まる一致は残す")
    XCTAssertEqual(
      Self.selectionOccurrences(
        of: NSRange(location: 0, length: 2), in: TextRope("aaaaa"), findNeedle: nil,
        findFieldFocused: false),
      [NSRange(location: 2, length: 2)])
  }

  func testSelectionOccurrencesNeedASingleLineNonBlankShortSelection() {
    let text = "ab ab\nab  ab"
    let none = { (range: NSRange) in
      Self.selectionOccurrences(
        of: range, in: TextRope(text), findNeedle: nil, findFieldFocused: false)
    }
    XCTAssertEqual(none(NSRange(location: 0, length: 0)), [], "空の選択")
    XCTAssertEqual(none(NSRange(location: 3, length: 4)), [], "複数行")
    XCTAssertEqual(none(NSRange(location: 8, length: 2)), [], "空白だけ")
    let long = String(repeating: "x", count: 201)
    XCTAssertEqual(
      Self.selectionOccurrences(
        of: NSRange(location: 0, length: 201), in: TextRope(long + " " + long), findNeedle: nil,
        findFieldFocused: false), [], "200 字を超える")
  }

  func testSelectionOccurrencesStepAsideForTheFindBar() {
    let text = "ab ab ab"
    let selection = NSRange(location: 0, length: 2)
    XCTAssertEqual(
      Self.selectionOccurrences(
        of: selection, in: TextRope(text), findNeedle: "AB", findFieldFocused: false), [],
      "検索バーが同じ文字列（大小無視）を探している")
    XCTAssertEqual(
      Self.selectionOccurrences(
        of: selection, in: TextRope(text), findNeedle: "zz", findFieldFocused: true), [],
      "検索語が空でない入力欄に焦点がある")
    XCTAssertEqual(
      Self.selectionOccurrences(
        of: selection, in: TextRope(text), findNeedle: "zz", findFieldFocused: false
      ).count, 2)
    XCTAssertEqual(
      Self.selectionOccurrences(
        of: selection, in: TextRope(text), findNeedle: "", findFieldFocused: true
      ).count, 2)
  }

  func testWordAtTheCaretUsesTheDefaultWordDefinition() {
    let line = "  let foo_bar = a.b(-1.5e3)"
    func word(_ location: Int, _ length: Int = 0) -> String? {
      Occurrences.word(
        at: NSRange(location: 100 + location, length: length), text: line, textStart: 100
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

  /// 数の語の `\d`・`\w` は JS（VS Code）と同じく ASCII だけ——全角数字や漢字に接しても語の切れ目は VS Code と同じ。
  func testNumberWordsUseAsciiClassesLikeJavaScript() {
    func words(_ text: String) -> [String] {
      let string = text as NSString
      var ranges: [NSRange] = []
      for position in 0...string.length {
        guard
          let word = Occurrences.word(
            at: NSRange(location: position, length: 0), text: text, textStart: 0),
          !ranges.contains(word)
        else { continue }
        ranges.append(word)
      }
      return ranges.map(string.substring(with:))
    }
    XCTAssertEqual(words("0.5秒"), ["0.5", "秒"])
    XCTAssertEqual(words("3.14π"), ["3.14", "π"])
    XCTAssertEqual(words("１.５"), ["１", "５"], "全角数字は数の語にならない")
  }

  /// 長い行は [キャレット − 499, キャレット + 501) の窓で語を探す（VS Code の maxLen 1000 を 1 始まりの桁の前後に
  /// 取る。窓の端の語は窓で切れる）。
  func testLongLinesAreSearchedInAWindowAroundTheCaret() {
    let line = NSRange(location: 10, length: 3000)
    XCTAssertEqual(
      Occurrences.wordWindow(caret: 2000, line: line), NSRange(location: 1501, length: 1000))
    XCTAssertEqual(
      Occurrences.wordWindow(caret: 20, line: line), NSRange(location: 10, length: 511), "行頭で止まる")
    XCTAssertEqual(
      Occurrences.wordWindow(caret: 2900, line: line), NSRange(location: 2401, length: 609),
      "行末で止まる")
    let short = NSRange(location: 10, length: 1000)
    XCTAssertEqual(Occurrences.wordWindow(caret: 500, line: short), short, "上限以下なら行全体")
  }

  func testWordOccurrencesAreCaseSensitiveWithWordBoundaries() {
    let text = "foo foo_x Foo (foo) xfoo foo"
    XCTAssertEqual(
      Occurrences.wordOccurrences(of: NSRange(location: 0, length: 3), in: TextRope(text)),
      [
        NSRange(location: 0, length: 3), NSRange(location: 15, length: 3),
        NSRange(location: 25, length: 3),
      ])
  }

  /// 選択が複数でも、どの選択とも同じ区間の出現と、選択より前に始まって選択に重なる出現は除く（VS Code の
  /// `SelectionHighlighter`）。
  func testSelectionOccurrencesExcludeEverySelection() {
    let text = TextRope("ab ab ab ab")
    let selections = [NSRange(location: 3, length: 2), NSRange(location: 9, length: 2)]
    let question = SearchQuestion.of(selections, continuing: nil, in: text)
    XCTAssertEqual(question, SearchQuestion(needle: "ab", rule: .find))
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: question!, selections: selections, in: text, findNeedle: nil, findFieldFocused: false),
      [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
  }

  /// 問いは、続きがあればそれ。無ければ、どの選択も空でなく文字列が大小を無視して同じときだけ、主の文字列を ⌘F の規則で。
  func testQuestionNeedsTheSameTextInEverySelection() {
    let text = TextRope("Foo foo bar")
    let foo = NSRange(location: 0, length: 3)
    XCTAssertEqual(
      SearchQuestion.of([foo, NSRange(location: 4, length: 3)], continuing: nil, in: text),
      SearchQuestion(needle: "Foo", rule: .find), "大小を無視して同じ")
    XCTAssertNil(
      SearchQuestion.of([foo, NSRange(location: 8, length: 3)], continuing: nil, in: text), "文字列が違う"
    )
    XCTAssertNil(
      SearchQuestion.of([foo, NSRange(location: 8, length: 0)], continuing: nil, in: text),
      "空の選択がある")
    XCTAssertNil(SearchQuestion.of([NSRange(location: 1, length: 0)], continuing: nil, in: text))
    let word = SearchQuestion(needle: "foo", rule: .word)
    XCTAssertEqual(
      SearchQuestion.of([foo, NSRange(location: 8, length: 3)], continuing: word, in: text), word,
      "続きがあればそれ")
  }

  /// 語の規則の問いは、大小を区別し語の境で切れる一致だけを出す（⌘D が語から続いている間）。
  func testWordQuestionHighlightsWholeWordsOnly() {
    let text = TextRope("foo Foo foobar foo")
    let selections = [NSRange(location: 0, length: 3)]
    XCTAssertEqual(
      Occurrences.selectionOccurrences(
        of: SearchQuestion(needle: "foo", rule: .word), selections: selections, in: text,
        findNeedle: nil, findFieldFocused: false),
      [NSRange(location: 15, length: 3)])
  }

  /// 語の規則の境は、⌘D・⌥←→ と同じ語の分類——日本語の並びの中でも、OS の語の分割の境で切れる一致は語の一致。
  func testWordRuleSplitsJapaneseRunsLikeWordMotion() {
    let text = TextRope("東京都に行く。東京タワー。京都")
    XCTAssertEqual(
      TextSearch.matches(of: "東京", in: text, rule: .word),
      [NSRange(location: 0, length: 2), NSRange(location: 7, length: 2)])
    XCTAssertEqual(
      TextSearch.matches(of: "京", in: text, rule: .word), [], "語の途中の一致は語の一致でない")
  }

  /// 区切りでも CJK でもない約物（「」、。（））や英字と数字の境に接する語も、その位置を含む並びに CJK があれば、⌘D の語と
  /// 同じ OS の語の分割で切れる。英字だけの並びは分割しない。
  func testWordRuleSplitsRunsThatContainJapaneseAnywhere() {
    func count(_ needle: String, _ text: String) -> Int {
      TextSearch.matches(of: needle, in: TextRope(text), rule: .word).count
    }
    XCTAssertEqual(count("Swift", "言語は「Swift」です"), 1)
    XCTAssertEqual(count("iPhone15", "iPhone15を買った。iPhone15"), 2)
    XCTAssertEqual(count("API", "まず、APIを呼ぶ（API）を使う"), 2)
    XCTAssertEqual(count("foo_bar", "設定のfoo_barを"), 1)
    XCTAssertEqual(
      TextSearch.matches(of: "foo", in: TextRope("foobar foo"), rule: .word),
      [NSRange(location: 7, length: 3)], "英字だけの並びは分割しない")
  }

  /// 次の一致は、位置以降に始まる最初の一致。無ければ先頭へ回る。
  func testFirstMatchWrapsAround() {
    let text = TextRope("ab x ab x AB")
    XCTAssertEqual(
      TextSearch.firstMatch(of: "ab", in: text, rule: .find, from: 3),
      NSRange(location: 5, length: 2))
    XCTAssertEqual(
      TextSearch.firstMatch(of: "AB", in: text, rule: .word, from: 11),
      NSRange(location: 10, length: 2))
    XCTAssertEqual(
      TextSearch.firstMatch(of: "ab", in: text, rule: .word, from: 8),
      NSRange(location: 0, length: 2), "末尾まで無ければ先頭から")
    XCTAssertNil(TextSearch.firstMatch(of: "zz", in: text, rule: .find, from: 3))
  }
}
