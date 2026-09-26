import Foundation
import XCTest

@testable import OrbeEditorCore

/// ファイル内検索の規則——一致の列はリテラル・大小無視・重ならず、「現在」は選択の関数、次／前は循環する。
/// 壊れると Enter が同じ一致に留まる、⇧Enter が末尾へ回らない、キャレットの手前の一致へ飛ぶ。
final class TextSearchTests: XCTestCase {
  func testMatchesAreLiteralCaseInsensitiveAndNonOverlapping() {
    XCTAssertEqual(
      TextSearch.matches(of: "aa", in: "aaaa AA"),
      [
        NSRange(location: 0, length: 2), NSRange(location: 2, length: 2),
        NSRange(location: 5, length: 2),
      ])
    XCTAssertEqual(
      TextSearch.matches(of: ".", in: "a.b"), [NSRange(location: 1, length: 1)], "正規表現ではない")
    XCTAssertEqual(TextSearch.matches(of: "", in: "abc"), [])
    XCTAssertEqual(TextSearch.matches(of: "zz", in: "abc"), [])
  }

  /// 一致は上限（19999）で打ち切り、上限ちょうども打ち切りとして見せる（VS Code の「19999+」）。
  func testMatchesStopAtTheLimit() {
    let text = String(repeating: "a", count: 12)
    XCTAssertEqual(TextSearch.matches(of: "a", in: text, limit: 5).count, 5)
    XCTAssertEqual(TextSearch.limit, 19999)
    let many = String(repeating: "ab", count: 20_001)
    let matches = TextSearch.matches(of: "a", in: many)
    XCTAssertEqual(matches.count, 19999)
    XCTAssertTrue(TextSearch.isLimited(matches))
    XCTAssertFalse(TextSearch.isLimited(Array(matches.prefix(19998))))
  }

  /// 本文の変更の間、一致は編集に合わせてずれ、編集に掛かる一致は落ちる（取り直すまで地が字からずれない）。
  func testTrackShiftsRangesAfterTheEditAndDropsTheOnesItTouches() {
    let ranges = [
      NSRange(location: 0, length: 2), NSRange(location: 4, length: 2),
      NSRange(location: 10, length: 2),
    ]
    let edit = TextEdit(range: NSRange(location: 5, length: 2), replacement: "12345")
    XCTAssertEqual(
      edit.track(ranges), [NSRange(location: 0, length: 2), NSRange(location: 13, length: 2)])
    let insert = TextEdit(range: NSRange(location: 2, length: 0), replacement: "x")
    XCTAssertEqual(
      insert.track(ranges),
      [
        NSRange(location: 0, length: 2), NSRange(location: 5, length: 2),
        NSRange(location: 11, length: 2),
      ],
      "端に接する挿入は区間を伸ばさない")
  }

  func testExactFindsTheMatchTheSelectionCoversExactly() {
    let matches = [NSRange(location: 2, length: 3), NSRange(location: 8, length: 3)]
    XCTAssertEqual(TextSearch.exact(in: matches, selection: NSRange(location: 8, length: 3)), 1)
    XCTAssertNil(TextSearch.exact(in: matches, selection: NSRange(location: 8, length: 0)))
    XCTAssertNil(TextSearch.exact(in: matches, selection: NSRange(location: 3, length: 3)))
    XCTAssertNil(TextSearch.exact(in: [], selection: NSRange(location: 0, length: 0)))
  }

  /// 位置以降に始まる最初の一致・位置までに終わる最後の一致（両端で循環）。VS Code `matchAfterPosition` /
  /// `matchBeforePosition`。
  func testFirstFromAndLastUpToAPosition() {
    let matches = [NSRange(location: 2, length: 3), NSRange(location: 8, length: 3)]
    XCTAssertEqual(TextSearch.first(in: matches, from: 2), 0, "その位置に始まる一致を含む")
    XCTAssertEqual(TextSearch.first(in: matches, from: 3), 1, "中にある一致は飛ばす")
    XCTAssertEqual(TextSearch.first(in: matches, from: 9), 0, "以降に無ければ先頭へ")
    XCTAssertEqual(TextSearch.last(in: matches, upTo: 11), 1, "その位置に終わる一致を含む")
    XCTAssertEqual(TextSearch.last(in: matches, upTo: 10), 0, "中にある一致は飛ばす")
    XCTAssertEqual(TextSearch.last(in: matches, upTo: 4), 1, "手前に無ければ末尾へ")
    XCTAssertNil(TextSearch.first(in: [], from: 0))
    XCTAssertNil(TextSearch.last(in: [], upTo: 0))
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
