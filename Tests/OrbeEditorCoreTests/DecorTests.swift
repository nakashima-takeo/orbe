import Foundation
import XCTest

@testable import OrbeEditorCore

/// 装備の規則——インデント単位の検出・段の数と境・見せる空白・行の URL。壊れるとインデント線が違う桁に立つ、
/// 単語間の 1 個のスペースに点が出る、URL の末尾の句読点までブラウザへ渡る。
final class DecorTests: XCTestCase {
  // MARK: - インデント単位

  func testIndentUnitIsTheMostFrequentNeighbourDifference() {
    XCTAssertEqual(IndentUnit.detect(in: "a\n  b\n    c\n  d\ne\n"), 2)
    XCTAssertEqual(IndentUnit.detect(in: "a\n    b\n        c\n    d\n"), 4)
    XCTAssertEqual(IndentUnit.detect(in: "a\n        b\na\n        b\n"), 8)
    XCTAssertEqual(IndentUnit.detect(in: "flat\nflat\n"), 4, "候補が無ければ 4")
    XCTAssertEqual(IndentUnit.detect(in: ""), 4)
    XCTAssertEqual(IndentUnit.detect(in: "a\n   b\n      c\n"), 4, "3 の段は候補に無い")
  }

  func testIndentUnitTiesPreferTheSmallerAndSkipBlankAndTabLines() {
    XCTAssertEqual(IndentUnit.detect(in: "a\n  b\nc\n    d\n"), 2, "2 と 4 が 1 回ずつなら 2")
    XCTAssertEqual(IndentUnit.detect(in: "a\n\n    \n    b\n"), 4, "空行・空白だけの行は隣として数えない")
    XCTAssertEqual(IndentUnit.detect(in: "a\n\tb\n  c\n"), 4, "タブの行はその前後の差に入れない")
  }

  // MARK: - 段

  func testIndentGuideBoundariesAndLevels() {
    XCTAssertEqual(IndentGuides.boundaries(of: "    x", unit: 2), [2, 4])
    XCTAssertEqual(IndentGuides.boundaries(of: "     x", unit: 2), [2, 4], "端数は段にならない")
    XCTAssertEqual(IndentGuides.boundaries(of: "\t\tx", unit: 4), [1, 2], "タブは 1 段")
    XCTAssertEqual(IndentGuides.boundaries(of: "  \tx", unit: 4), [3], "タブは次の段の境まで")
    XCTAssertEqual(IndentGuides.boundaries(of: "x", unit: 4), [])
    XCTAssertEqual(IndentGuides.boundaries(of: "", unit: 4), [])
    XCTAssertEqual(
      IndentGuides.level(of: "    x", unit: 2, previousNonBlank: nil, nextNonBlank: nil), 2)
  }

  func testBlankLinesTakeTheShallowerNeighbour() {
    XCTAssertEqual(
      IndentGuides.level(of: "", unit: 2, previousNonBlank: "    a", nextNonBlank: "  b"), 1)
    XCTAssertEqual(
      IndentGuides.level(of: "  \r", unit: 2, previousNonBlank: "  a", nextNonBlank: "      b"), 1,
      "空白だけの行も空行")
    XCTAssertEqual(
      IndentGuides.level(of: "", unit: 2, previousNonBlank: "    a", nextNonBlank: nil), 0)
    XCTAssertEqual(
      IndentGuides.level(of: "", unit: 2, previousNonBlank: nil, nextNonBlank: "  a"), 0)
  }

  // MARK: - 空白

  func testBoundaryWhitespaceOnly() {
    XCTAssertEqual(WhitespaceRuns.boundary(in: "a b"), [], "単語間の 1 個には出ない")
    XCTAssertEqual(WhitespaceRuns.boundary(in: "  a  b c "), [0..<2, 3..<5, 8..<9])
    XCTAssertEqual(WhitespaceRuns.boundary(in: " a"), [0..<1], "行頭は 1 個でも出る")
    XCTAssertEqual(WhitespaceRuns.boundary(in: "a \r"), [1..<2], "CR は行の外（行末の 1 個が出る）")
    XCTAssertEqual(WhitespaceRuns.boundary(in: "\ta\tb"), [], "タブには出ない")
    XCTAssertEqual(WhitespaceRuns.boundary(in: "a\u{00A0}b"), [], "NBSP には出ない")
    XCTAssertEqual(WhitespaceRuns.boundary(in: "   "), [0..<3])
    XCTAssertEqual(WhitespaceRuns.boundary(in: ""), [])
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

  func testTrailingPunctuationAndUnbalancedClosersAreTrimmed() {
    XCTAssertEqual(urls("https://a.b/c."), ["https://a.b/c"])
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
