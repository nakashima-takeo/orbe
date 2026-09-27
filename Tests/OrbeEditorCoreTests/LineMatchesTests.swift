import Foundation
import XCTest

@testable import OrbeEditorCore

/// 1 行の中の一致と、本文の写しを行ごとに探す規則——一致は重ならない順で UTF-16 の位置、長さ 0 の一致は数えない、行末の
/// `\r` は見せる本文から外すが一致は外す前の行に当てる、上限と取り消しで止まる。
///
/// 壊れると何が起きるか。絵文字の後ろの一致がずれた字を選ぶ。`x*` のような式で一致の無い行まで結果に出る。CRLF の
/// ファイルでプレビューの末尾に `\r` が出る、`foo$` が当たらない。巨大な文書で上限を越えて集め続ける。
final class LineMatchesTests: XCTestCase {
  private func regex(_ pattern: String) throws -> NSRegularExpression {
    try NSRegularExpression(pattern: pattern)
  }

  func testMatchesInALineAreNonOverlappingUtf16Ranges() throws {
    let line = "😀 aa aaa" as NSString
    XCTAssertEqual(
      LineMatches.ranges(of: try regex("aa"), in: line),
      [NSRange(location: 3, length: 2), NSRange(location: 6, length: 2)])
  }

  func testEmptyMatchesAreNotCounted() throws {
    XCTAssertEqual(LineMatches.ranges(of: try regex("x*"), in: "abc"), [])
    XCTAssertEqual(
      LineMatches.ranges(of: try regex("a*"), in: "baab"), [NSRange(location: 1, length: 2)])
  }

  /// CRLF の行: 一致は `\r` を含む行に当てる（`$` は `\r` の前で当たる）が、プレビューには `\r` を出さない。
  func testCarriageReturnIsMatchedButNotShown() throws {
    let found = try XCTUnwrap(
      LineMatches.matches(of: try regex("(?i)foo$"), inLine: "a FOO\r", row: 4))
    XCTAssertEqual(found.map(\.line), [4])
    XCTAssertEqual(found.map(\.column), [NSRange(location: 2, length: 3)])
    XCTAssertEqual(found.first?.preview, SearchPreview(before: "a ", match: "FOO", after: ""))
  }

  func testMatchesInALineStopAtTheLimit() throws {
    let found = try XCTUnwrap(
      LineMatches.matches(of: try regex("a"), inLine: "aaaa", row: 0, limit: 3))
    XCTAssertEqual(found.map(\.column.location), [0, 1, 2])
  }

  /// 本文を行ごとに探し、一致ごとに行・行の中の位置と、文書の区間（同じ順）を返す。
  func testSearchingTextGivesRowsColumnsAndDocumentRanges() throws {
    let text = TextRope("foo\r\nbar foo\n\n😀foo")
    let found = try XCTUnwrap(LineMatches.search(text, try regex("foo"), limit: .max))
    XCTAssertEqual(found.matches.map(\.line), [0, 1, 3])
    XCTAssertEqual(found.matches.map(\.column.location), [0, 4, 2])
    XCTAssertEqual(
      found.ranges,
      [
        NSRange(location: 0, length: 3), NSRange(location: 9, length: 3),
        NSRange(location: 16, length: 3),
      ])
    for range in found.ranges { XCTAssertEqual(text.substring(range), "foo") }
  }

  func testSearchingTextStopsAtTheLimit() throws {
    let text = TextRope(String(repeating: "x x\n", count: 10))
    let found = try XCTUnwrap(LineMatches.search(text, try regex("x"), limit: 5))
    XCTAssertEqual(found.matches.count, 5)
    XCTAssertEqual(found.ranges.count, 5)
    XCTAssertEqual(found.matches.map(\.line), [0, 0, 1, 1, 2])
  }

  /// 取り消されたら結果を返さない（途中までの一致を最新として置かせない）——1 行の照合の途中でも見る。
  func testCancelledSearchReturnsNothing() throws {
    let text = TextRope(String(repeating: "x\n", count: 1000))
    XCTAssertNil(LineMatches.search(text, try regex("x"), limit: .max, isCancelled: { true }))

    var polls = 0
    let catastrophic = try regex("(a+)+b")
    let line = String(repeating: "a", count: 40) as NSString
    XCTAssertNil(
      LineMatches.ranges(of: catastrophic, in: line) {
        polls += 1
        return polls > 3
      },
      "指数時間に落ちる式でも行の途中で止まる")
  }
}
