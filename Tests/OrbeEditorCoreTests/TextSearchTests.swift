import Foundation
import XCTest

@testable import OrbeEditorCore

/// ファイル内検索の規則——一致の列はリテラル・大小無視・重ならず、「現在」は選択の関数、次／前は循環する。
/// 壊れると Enter が同じ一致に留まる、⇧Enter が末尾へ回らない、キャレットの手前の一致へ飛ぶ。
final class TextSearchTests: XCTestCase {
  func testMatchesAreLiteralCaseInsensitiveAndNonOverlapping() {
    XCTAssertEqual(
      TextSearch.matches(of: "aa", in: TextRope("aaaa AA")),
      [
        NSRange(location: 0, length: 2), NSRange(location: 2, length: 2),
        NSRange(location: 5, length: 2),
      ])
    XCTAssertEqual(
      TextSearch.matches(of: ".", in: TextRope("a.b")), [NSRange(location: 1, length: 1)],
      "正規表現ではない")
    XCTAssertEqual(TextSearch.matches(of: "", in: TextRope("abc")), [])
    XCTAssertEqual(TextSearch.matches(of: "zz", in: TextRope("abc")), [])
  }

  /// 一致は上限（19999）で打ち切り、上限ちょうども打ち切りとして見せる（VS Code の「19999+」）。
  func testMatchesStopAtTheLimit() {
    let many = String(repeating: "ab", count: 20_001)
    let matches = TextSearch.matches(of: "a", in: TextRope(many))
    XCTAssertEqual(matches.count, 19999)
    XCTAssertTrue(TextSearch.isLimited(matches))
    XCTAssertFalse(TextSearch.isLimited(Array(matches.prefix(19998))))
  }

  func testExactFindsTheMatchTheSelectionCoversExactly() {
    let matches = [NSRange(location: 2, length: 3), NSRange(location: 8, length: 3)]
    XCTAssertEqual(TextSearch.exact(in: matches, selection: NSRange(location: 8, length: 3)), 1)
    XCTAssertNil(TextSearch.exact(in: matches, selection: NSRange(location: 8, length: 0)))
    XCTAssertNil(TextSearch.exact(in: matches, selection: NSRange(location: 3, length: 3)))
    XCTAssertNil(TextSearch.exact(in: [], selection: NSRange(location: 0, length: 0)))
  }

  /// Enter は選択の終わりから、⇧Enter は選択の先頭から。選択が一致ならその次・前、キャレットが一致の中ならその一致を
  /// 飛ばす、接して並ぶ一致へも進む。
  func testNextStartsFromTheSelectionEndAndPreviousFromItsStart() {
    let matches = [
      NSRange(location: 2, length: 2), NSRange(location: 4, length: 2),
      NSRange(location: 20, length: 2),
    ]
    XCTAssertEqual(TextSearch.next(in: matches, from: matches[0]), 1, "接して並ぶ次の一致")
    XCTAssertEqual(TextSearch.next(in: matches, from: matches[2]), 0, "末尾で先頭へ")
    XCTAssertEqual(TextSearch.next(in: matches, from: NSRange(location: 5, length: 0)), 2, "中は飛ばす")
    XCTAssertEqual(
      TextSearch.next(in: matches, from: NSRange(location: 0, length: 5)), 2, "選択の終わりから")
    XCTAssertEqual(TextSearch.previous(in: matches, from: matches[1]), 0)
    XCTAssertEqual(TextSearch.previous(in: matches, from: matches[0]), 2, "先頭で末尾へ")
    XCTAssertEqual(
      TextSearch.previous(in: matches, from: NSRange(location: 21, length: 0)), 1, "中は飛ばす")
    XCTAssertEqual(
      TextSearch.previous(in: matches, from: NSRange(location: 6, length: 10)), 1, "選択の先頭から")
  }
}
