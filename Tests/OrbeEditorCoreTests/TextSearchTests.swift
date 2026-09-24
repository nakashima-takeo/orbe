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
    let edit = TextEdit(range: NSRange(location: 5, length: 2), replacementLength: 5)
    XCTAssertEqual(
      edit.track(ranges), [NSRange(location: 0, length: 2), NSRange(location: 13, length: 2)])
    let insert = TextEdit(range: NSRange(location: 2, length: 0), replacementLength: 1)
    XCTAssertEqual(
      insert.track(ranges),
      [
        NSRange(location: 0, length: 2), NSRange(location: 5, length: 2),
        NSRange(location: 11, length: 2),
      ],
      "端に接する挿入は区間を伸ばさない")
  }

  func testCurrentIsTheSelectionOrTheFirstMatchAtOrAfterIt() {
    let matches = [NSRange(location: 2, length: 1), NSRange(location: 8, length: 1)]
    XCTAssertEqual(TextSearch.current(in: matches, from: NSRange(location: 8, length: 1)), 1)
    XCTAssertEqual(TextSearch.current(in: matches, from: NSRange(location: 3, length: 0)), 1)
    XCTAssertEqual(TextSearch.current(in: matches, from: NSRange(location: 2, length: 0)), 0)
    XCTAssertEqual(
      TextSearch.current(in: matches, from: NSRange(location: 9, length: 0)), 0, "以降に無ければ先頭へ")
    XCTAssertNil(TextSearch.current(in: [], from: NSRange(location: 0, length: 0)))
  }

  func testNextAndPreviousCycleFromAnExactMatchAndSettleFromElsewhere() {
    let matches = [
      NSRange(location: 2, length: 1), NSRange(location: 8, length: 1),
      NSRange(location: 20, length: 1),
    ]
    XCTAssertEqual(TextSearch.next(in: matches, from: matches[1]), 2)
    XCTAssertEqual(TextSearch.next(in: matches, from: matches[2]), 0, "末尾で先頭へ")
    XCTAssertEqual(
      TextSearch.next(in: matches, from: NSRange(location: 5, length: 0)), 1, "一致に乗っていなければ current")
    XCTAssertEqual(TextSearch.previous(in: matches, from: matches[1]), 0)
    XCTAssertEqual(TextSearch.previous(in: matches, from: matches[0]), 2, "先頭で末尾へ")
    XCTAssertEqual(TextSearch.previous(in: matches, from: NSRange(location: 9, length: 0)), 1)
    XCTAssertEqual(
      TextSearch.previous(in: matches, from: NSRange(location: 1, length: 0)), 2, "手前に無ければ末尾へ")
  }
}
