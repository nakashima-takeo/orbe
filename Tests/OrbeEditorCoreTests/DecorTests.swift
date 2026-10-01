import Foundation
import XCTest

@testable import OrbeEditorCore

/// 装備の規則——インデント単位の検出・段の数と境・見せる空白・行の URL。壊れるとインデント線が違う桁に立つ、
/// 単語間の 1 個のスペースに点が出る、URL の末尾の句読点までブラウザへ渡る。
@MainActor
final class DecorTests: XCTestCase {
  // MARK: - インデント単位

  func testIndentUnitIsTheMostFrequentNeighbourDifference() {
    XCTAssertEqual(Indentation.detect(in: "a\n  b\n    c\n  d\ne\n".utf16).unit, 2)
    XCTAssertEqual(Indentation.detect(in: "a\n    b\n        c\n    d\n".utf16).unit, 4)
    XCTAssertEqual(Indentation.detect(in: "a\n        b\na\n        b\n".utf16).unit, 8)
    XCTAssertEqual(Indentation.detect(in: "flat\nflat\n".utf16).unit, 4, "候補が無ければ 4")
    XCTAssertEqual(Indentation.detect(in: "".utf16).unit, 4)
    XCTAssertEqual(Indentation.detect(in: "a\n   b\n      c\n".utf16).unit, 4, "3 の段は候補に無い")
  }

  /// 同数は小さい方。空行・空白だけの行は隣として数えず（飛ばして前後の非空行が対になる）、タブの行は
  /// その前後の非空行の対も切る。
  func testIndentUnitTiesPreferTheSmallerAndSkipBlankAndTabLines() {
    XCTAssertEqual(Indentation.detect(in: "a\n  b\n      c\n".utf16).unit, 2, "2 と 4 が 1 回ずつなら 2")
    XCTAssertEqual(
      Indentation.detect(in: "      a\n\n    b\n".utf16).unit, 2, "空行を飛ばして 6 と 4 が対（飛ばさなければ 4）")
    XCTAssertEqual(Indentation.detect(in: "  a\n    \n  b\n".utf16).unit, 4, "空白だけの行は隣でない（数えれば 2）")
    XCTAssertEqual(
      Indentation.detect(in: "  a\r\n    \r\n  b\r\n".utf16).unit, 4, "CRLF の空白だけの行も隣でない（数えれば 2）")
    XCTAssertEqual(Indentation.detect(in: "a\n\tb\n  c\n".utf16).unit, 4, "タブの行は前後の対を切る（切らなければ 2）")
  }

  /// タブかは、行頭の空白にタブを含む行とスペース 2 個以上で始まる行の数の比べ（VS Code の推定）。同数なら空白、
  /// スペース 1 個の行と空白だけの行は数えない。
  func testIndentationUsesTabsWhenTabIndentedLinesOutnumberSpaceIndentedOnes() {
    XCTAssertTrue(Indentation.detect(in: "a\n\tb\n\t\tc\n    d\n".utf16).usesTabs)
    XCTAssertFalse(Indentation.detect(in: "a\n\tb\n    c\n".utf16).usesTabs, "同数なら空白")
    XCTAssertTrue(Indentation.detect(in: "a\n\tb\n c\n\t\n".utf16).usesTabs, "1 個のスペースと空白だけの行は数えない")
    XCTAssertTrue(Indentation.detect(in: "a\n  \tb\n".utf16).usesTabs, "空白の途中のタブも数える")
    XCTAssertFalse(Indentation.detect(in: "".utf16).usesTabs)
  }

  // MARK: - 段

  /// 改行の作法は CRLF と LF の多い方（同数と改行の無い本文は LF）。揃えるときは `\r\n`・`\r`・`\n` のどれも作法の改行に
  /// する。
  func testLineBreakIsTheMajorityAndNormalizesEveryBreak() {
    func detect(_ text: String) -> LineBreak { LineBreak.detect(in: text.utf16) }
    XCTAssertEqual(detect("a\r\nb\r\nc\n"), .crlf)
    XCTAssertEqual(detect("a\r\nb\nc\n"), .lf)
    XCTAssertEqual(detect("a\r\nb\n"), .lf, "同数は LF")
    XCTAssertEqual(detect("abc"), .lf, "改行の無い本文は LF")
    XCTAssertEqual(LineBreak.crlf.normalize("a\nb\r\nc\rd"), "a\r\nb\r\nc\r\nd")
    XCTAssertEqual(LineBreak.lf.normalize("a\r\nb\rc\n"), "a\nb\nc\n")
    XCTAssertEqual(LineBreak.lf.normalize("🇯🇵\r\n"), "🇯🇵\n", "書記素を割らない")
  }

  func testIndentGuideBoundariesAndLevels() {
    XCTAssertEqual(IndentGuides.boundaries(of: "    x".utf16, unit: 2), [2, 4])
    XCTAssertEqual(IndentGuides.boundaries(of: "     x".utf16, unit: 2), [2, 4], "端数は段にならない")
    XCTAssertEqual(IndentGuides.boundaries(of: "\t\tx".utf16, unit: 4), [1, 2], "タブは 1 段")
    XCTAssertEqual(IndentGuides.boundaries(of: "  \tx".utf16, unit: 4), [3], "タブは次の段の境まで")
    XCTAssertEqual(IndentGuides.boundaries(of: "x".utf16, unit: 4), [])
    XCTAssertEqual(IndentGuides.boundaries(of: "".utf16, unit: 4), [])
    XCTAssertTrue(IndentGuides.isBlank("  \t\r".utf16), "スペース・タブ・CR だけの行は空白だけの行")
    XCTAssertFalse(IndentGuides.isBlank("  x".utf16))
  }

  /// 空白だけの行は前後の非空行の浅い方——並びの中の非空行でも、並びの外の段でも。片側が無ければ 0。
  func testBlankLinesTakeTheShallowerNeighbour() {
    XCTAssertEqual(IndentGuides.levels([2, nil, nil, 1], above: nil, below: nil), [2, 1, 1, 1])
    XCTAssertEqual(IndentGuides.levels([nil, 3], above: 2, below: nil), [2, 3], "上は並びの外")
    XCTAssertEqual(IndentGuides.levels([1, nil], above: nil, below: 4), [1, 1], "下は並びの外")
    XCTAssertEqual(IndentGuides.levels([nil, nil], above: 2, below: 3), [2, 2], "全部が空行")
    XCTAssertEqual(IndentGuides.levels([nil, 2], above: nil, below: nil), [0, 2], "上に非空行が無い")
    XCTAssertEqual(IndentGuides.levels([2, nil], above: 5, below: nil), [2, 0], "下に非空行が無い")
    XCTAssertEqual(IndentGuides.levels([], above: 1, below: 1), [])
  }

  // MARK: - 空白

  func testBoundaryWhitespaceOnly() {
    XCTAssertEqual(WhitespaceRuns.runs(in: "a b".utf16), [], "単語間の 1 個には出ない")
    XCTAssertEqual(WhitespaceRuns.runs(in: "  a  b c ".utf16), [0..<2, 3..<5, 8..<9])
    XCTAssertEqual(WhitespaceRuns.runs(in: " a".utf16), [0..<1], "行頭は 1 個でも出る")
    XCTAssertEqual(WhitespaceRuns.runs(in: "a \r".utf16), [1..<2], "CR は行の外（行末の 1 個が出る）")
    XCTAssertEqual(WhitespaceRuns.runs(in: "\ta\tb".utf16), [], "タブには出ない")
    XCTAssertEqual(WhitespaceRuns.runs(in: "a\u{00A0}b".utf16), [], "NBSP には出ない")
    XCTAssertEqual(WhitespaceRuns.runs(in: "   ".utf16), [0..<3])
    XCTAssertEqual(WhitespaceRuns.runs(in: "".utf16), [])
    XCTAssertEqual(WhitespaceRuns.runs(in: "a \rb".utf16), [], "途中の CR の前の 1 個は単語間")
    XCTAssertEqual(WhitespaceRuns.runs(in: " \r".utf16), [0..<1])
    XCTAssertEqual(WhitespaceRuns.runs(in: "a  b \r".utf16), [1..<3, 4..<5])
  }

  // MARK: - URL

  private func urls(_ line: String) -> [String] {
    LinkDetector.links(in: line).map(\.url.absoluteString)
  }

  func testLinksStartWithHttpAndStopAtStructuralCharacters() {
    XCTAssertEqual(
      urls("see https://example.com/a?b=1#c and http://x.y"),
      [
        "https://example.com/a?b=1#c", "http://x.y",
      ])
    XCTAssertEqual(
      urls("<https://a.b/c> \"https://d.e\" `https://f.g`"),
      [
        "https://a.b/c", "https://d.e", "https://f.g",
      ])
    XCTAssertEqual(urls("ftp://a.b example.com www.x.y"), [], "http(s) 以外・bare domain は取らない")
    XCTAssertEqual(urls("https://"), [], "本体が無ければ取らない")
  }

  /// `://` を含まない行は URL を持たない——字を読まずに単位だけで見分ける口と、字を読む規則の答えが揃う。
  func testLinesWithoutASchemeSeparatorHaveNoLinks() {
    for line in [
      "see https://example.com/a and http://x.y", "https:/a.b", "a :// b", "http:/ /x", "x:/", "",
      "日本語 https://a.b/c 😀",
    ] {
      let may = LinkDetector.mayContainLinks(line.utf16)
      XCTAssertEqual(may, line.contains("://"), line)
      if !may { XCTAssertEqual(urls(line), [], line) }
    }
  }

  /// 刈った後の区間も刈った長さになる（下線と ⌘クリックの当たりが句読点まで伸びない）。
  func testTrailingPunctuationAndUnbalancedClosersAreTrimmed() {
    XCTAssertEqual(urls("https://a.b/c."), ["https://a.b/c"])
    XCTAssertEqual(
      LinkDetector.links(in: "(https://a.b/c).").map(\.range), [NSRange(location: 1, length: 13)])
    XCTAssertEqual(urls("(https://a.b/c)."), ["https://a.b/c"])
    XCTAssertEqual(
      urls("https://en.wikipedia.org/wiki/Foo_(bar)"), ["https://en.wikipedia.org/wiki/Foo_(bar)"])
    XCTAssertEqual(urls("[https://a.b/c]"), ["https://a.b/c"])
    XCTAssertEqual(urls("https://a.b/c?x=1;"), ["https://a.b/c?x=1"])
    XCTAssertEqual(urls("'https://a.b/c'"), ["https://a.b/c"])
    XCTAssertEqual(urls("https://a.b/c!?:,"), ["https://a.b/c"])
  }

  func testLinkRangesAreUTF16OffsetsWithinTheLine() {
    let links = LinkDetector.links(in: "日本語 https://a.b/c 😀 https://d.e/")
    XCTAssertEqual(
      links.map(\.range), [NSRange(location: 4, length: 13), NSRange(location: 21, length: 12)])
    XCTAssertEqual(
      urls("https://例.jp/パス"), ["https://xn--fsq.jp/%E3%83%91%E3%82%B9"],
      "URL として解けない文字は符号化して渡す（ホストは punycode）")
  }
}
