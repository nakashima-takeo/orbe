import XCTest

@testable import Orbe

/// 1 行 1 件の JSON の読み取り——使い手の型に合う行だけを受け、合わない行は何行目か・なぜかを残す、上限で切れた最後の行を
/// 完全なものとして読まない。
///
/// 壊れると何が起きるか。取得役の出力の 1 行の崩れで、受信の全件を失う。捨てた理由が分からず、取得役を直せない。
/// 切れた行の断片が、たまたま形に合って項目として取り込まれる。
final class JSONLinesTests: OrbeTestCase {
  private struct Item: Decodable, Equatable {
    let id: Int
    let title: String
    let tags: [String]?
  }

  func testItemsMatchingTheShapeAreAccepted() {
    let lines = JSONLines<Item>(
      """
      {"id":1,"title":"a"}
      {"id":2,"title":"b","tags":["x"],"extra":true}

      """)

    XCTAssertEqual(
      lines.items, [Item(id: 1, title: "a", tags: nil), Item(id: 2, title: "b", tags: ["x"])])
    XCTAssertEqual(lines.rejected, [])
  }

  func testRejectedLinesKeepLineNumberAndReason() {
    let lines = JSONLines<Item>(
      """
      not json

      [1,2]
      "text"
      {"title":"no id"}
      {"id":"1","title":"a"}
      {"id":1,"title":null}
      {"id":1,"title":"a","tags":["x",2]}
      {"id":9,"title":"ok"}
      """)

    XCTAssertEqual(lines.items, [Item(id: 9, title: "ok", tags: nil)])
    XCTAssertEqual(
      lines.rejected,
      [
        .init(line: 1, reason: .notJSON),
        .init(line: 3, reason: .notObject),
        .init(line: 4, reason: .notObject),
        .init(line: 5, reason: .missingKey("id")),
        .init(line: 6, reason: .typeMismatch("id")),
        .init(line: 7, reason: .nullValue("title")),
        .init(line: 8, reason: .typeMismatch("tags[1]")),
      ], "空行は項目にも捨てた行にもならないが、行番号は数える")
  }

  /// 改行が CRLF でも 1 行 1 件として読む（JSON Lines は値の前後の空白を無視するので、`\r\n` も行の区切り）。
  func testCRLFLinesAreReadOneByOne() {
    let lines = JSONLines<Item>("{\"id\":1,\"title\":\"a\"}\r\n{\"id\":2,\"title\":\"b\"}\r\n")

    XCTAssertEqual(lines.items.map(\.id), [1, 2])
    XCTAssertEqual(lines.rejected, [])
  }
}
