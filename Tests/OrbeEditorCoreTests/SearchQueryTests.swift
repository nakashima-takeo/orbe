import Foundation
import XCTest

@testable import OrbeEditorCore

/// プロジェクト検索の問いの規則——素の文字列は字どおり、大小無視は Unicode、単語単位は検索語の端が ASCII の単語の字の
/// ときだけ境界を足し（足した境界は Unicode で判定）、正規表現は ICU の文法。同じ規則でディスク（git の PCRE2）への式も
/// 組み立てる。
///
/// 壊れると何が起きるか。`.` や `(` を含む語が正規表現として探され、関係ない行が結果に出る。単語単位で `日本` が何にも
/// 当たらない、`foo` が `éfoo` の中に当たる。開いている文書とディスクで同じ問いが別の式になり、結果が食い違う。
final class SearchQueryTests: XCTestCase {
  private func matches(_ query: SearchQuery, _ text: String) throws -> [NSRange] {
    let regex = try query.compiled().regex
    return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
      .map(\.range)
  }

  func testPlainTextIsSearchedLiterally() throws {
    let query = SearchQuery(pattern: #"a.b(c)[d]\e^$|*+?{2}"#)
    XCTAssertEqual(
      try matches(query, #"xa.b(c)[d]\e^$|*+?{2}"#), [NSRange(location: 1, length: 20)])
    XCTAssertEqual(try matches(query, #"axb(c)[d]\e^$|*+?{2}"#), [], "`.` は任意の字ではない")
  }

  func testCaseIsIgnoredByUnicodeUnlessMatchCaseIsOn() throws {
    XCTAssertEqual(
      try matches(SearchQuery(pattern: "ärger"), "ÄRGER ärger").count, 2, "既定は大小無視（ASCII の外も）")
    XCTAssertEqual(
      try matches(SearchQuery(pattern: "ärger", matchCase: true), "ÄRGER ärger"),
      [NSRange(location: 6, length: 5)])
  }

  /// 単語単位の境界は、検索語の端の字が ASCII の英数字か `_` のときだけ足す。足した境界は Unicode で判定する。
  func testWholeWordAddsBoundariesOnlyAtAsciiWordEnds() throws {
    let foo = SearchQuery(pattern: "foo", wholeWord: true)
    XCTAssertEqual(
      try matches(foo, "foo foobar barfoo foo."),
      [
        NSRange(location: 0, length: 3), NSRange(location: 18, length: 3),
      ])
    XCTAssertEqual(try matches(foo, "éfoo"), [], "足した境界は Unicode の単語の字で判定する")

    let japanese = SearchQuery(pattern: "日本", wholeWord: true)
    XCTAssertEqual(
      try matches(japanese, "日本語"), [NSRange(location: 0, length: 2)],
      "端が ASCII の単語の字でなければ境界を足さない（VS Code と同じ）")

    let dashed = SearchQuery(pattern: "-foo", wholeWord: true)
    XCTAssertEqual(
      try matches(dashed, "x-foo x-foobar"), [NSRange(location: 1, length: 4)], "先頭には足さず末尾にだけ足す")
  }

  func testRegexUsesTheIcuGrammarAndRejectsWhatItCannotCompile() throws {
    XCTAssertEqual(
      try matches(SearchQuery(pattern: #"f\w+"#, isRegex: true), "a foo fab"),
      [NSRange(location: 2, length: 3), NSRange(location: 6, length: 3)])
    XCTAssertEqual(
      try matches(SearchQuery(pattern: "fo+", wholeWord: true, isRegex: true), "foo fooo xfoo"),
      [NSRange(location: 0, length: 3), NSRange(location: 4, length: 4)], "正規表現にも単語単位が効く")
    XCTAssertThrowsError(try SearchQuery(pattern: "(", isRegex: true).compiled()) {
      XCTAssertEqual($0 as? SearchQuery.Invalid, SearchQuery.Invalid())
    }
    XCTAssertNoThrow(try SearchQuery(pattern: "(").compiled(), "正規表現でなければ字どおりに組める")
  }

  /// ディスクへの式は、開いている文書の式と同じ組み立てに、エンジンの設定を前置したもの（規則は 1 か所。設定の効き目は
  /// 本物の git で見る → `GitGrepTests`）。
  func testTheDiskPatternIsBuiltFromTheSameSource() throws {
    for query in [
      SearchQuery(pattern: "a.b"), SearchQuery(pattern: "foo", matchCase: true, wholeWord: true),
      SearchQuery(pattern: "x+$", isRegex: true),
    ] {
      let compiled = try query.compiled()
      XCTAssertTrue(compiled.pcre.hasSuffix(compiled.regex.pattern), "\(query): \(compiled.pcre)")
    }
  }

  /// 永続の 1 項目が読めなくても、問いの残りは失わない。
  func testDecodingFillsUnreadableFieldsWithDefaults() throws {
    let json = #"{"pattern":"needle","matchCase":"bad","isRegex":true}"#
    XCTAssertEqual(
      try JSONDecoder().decode(SearchQuery.self, from: Data(json.utf8)),
      SearchQuery(pattern: "needle", isRegex: true))
  }
}
