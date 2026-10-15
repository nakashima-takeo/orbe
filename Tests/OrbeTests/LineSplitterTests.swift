import XCTest

@testable import Orbe

/// 届いた塊を行に割る——塊の境目をまたぐ行も 1 行で渡す、上限を超えた行は塊をまたいでも捨てて数える、受け手が断ったら止まる。
///
/// 壊れると何が起きるか。pipe の読みの区切りで claude の出来事が割れて、最終応答を読み損ねる。巨大なツールの結果を
/// 1 行まるごと貯め込む。
final class LineSplitterTests: OrbeTestCase {
  private var lines: [String] = []

  private func receive(_ line: Data) -> Bool {
    lines.append(String(bytes: line, encoding: .utf8) ?? "")
    return true
  }

  func testLineSpanningChunksIsDeliveredWhole() {
    var splitter = LineSplitter(maxLength: 100)

    XCTAssertTrue(splitter.feed(Data("ab".utf8), onLine: receive))
    XCTAssertTrue(splitter.feed(Data("c\nd".utf8), onLine: receive))
    XCTAssertTrue(splitter.finish(onLine: receive))

    XCTAssertEqual(lines, ["abc", "d"])
  }

  func testOversizedLineAcrossChunksIsDroppedAndCounted() {
    var splitter = LineSplitter(maxLength: 4)

    _ = splitter.feed(Data("abc".utf8), onLine: receive)
    _ = splitter.feed(Data("def".utf8), onLine: receive)
    _ = splitter.feed(Data("gh\nok\n".utf8), onLine: receive)

    XCTAssertEqual(lines, ["ok"])
    XCTAssertEqual(splitter.dropped, 1)
  }

  func testRefusalStopsDelivery() {
    var splitter = LineSplitter(maxLength: 100)
    var seen: [String] = []

    let accepted = splitter.feed(Data("a\nb\nc\n".utf8)) {
      seen.append(String(bytes: $0, encoding: .utf8) ?? "")
      return seen.count < 2
    }

    XCTAssertFalse(accepted)
    XCTAssertEqual(seen, ["a", "b"])
  }
}
