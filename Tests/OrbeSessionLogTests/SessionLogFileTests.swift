import Foundation
import XCTest

@testable import OrbeSessionLog

/// 書き手（追記・原子的書き直し）と読み手（改行で終わらない末尾行の読み飛ばし・絞り込み・truncated）の契約。
/// 壊れると、改行の着地前の行を読んで壊れた 1 件が混ざるか、`--since` が効かずに全件が返る。
final class SessionLogFileTests: XCTestCase {
  func testAppendWritesOneLinePerEventWithOwnerOnlyPermissions() throws {
    let url = try tempLogFile()
    try SessionLogWriter.append(Fixture.opened("a", at: 0), to: url)
    try SessionLogWriter.append(Fixture.closed("a", at: 1), to: url)

    let text = try String(contentsOf: url, encoding: .utf8)
    XCTAssertEqual(text.split(separator: "\n").count, 2)
    XCTAssertTrue(text.hasSuffix("\n"))
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
    XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(try SessionLogReader.read(url).events.map(\.sessionId), ["a", "a"])
  }

  func testMissingFileReadsAsEmpty() throws {
    let url = try tempLogFile("nope.jsonl")
    let result = try SessionLogReader.read(url)
    XCTAssertEqual(result.events, [])
    XCTAssertFalse(result.truncated)
  }

  func testReaderSkipsUnterminatedTailAndBrokenLines() throws {
    let url = try tempLogFile()
    var data = try SessionLogWriter.encodeLine(Fixture.opened("a", at: 0))
    data.append(Data("not json\n".utf8))
    data.append(try SessionLogWriter.encodeLine(Fixture.closed("a", at: 1)))
    data.append(try SessionLogWriter.encodeLine(Fixture.opened("b", at: 2)).dropLast(1))
    try data.write(to: url)

    let events = try SessionLogReader.read(url).events
    XCTAssertEqual(events, [Fixture.opened("a", at: 0), Fixture.closed("a", at: 1)])
  }

  func testReaderFiltersBySinceUntilAndSessionId() throws {
    let url = try tempLogFile()
    for event in [
      Fixture.opened("a", at: 0), Fixture.opened("b", at: 10), Fixture.closed("a", at: 20),
      Fixture.closed("b", at: 30),
    ] {
      try SessionLogWriter.append(event, to: url)
    }
    let since = Fixture.base.addingTimeInterval(10)
    let until = Fixture.base.addingTimeInterval(20)
    XCTAssertEqual(
      try SessionLogReader.read(url, since: since, until: until).events,
      [Fixture.opened("b", at: 10), Fixture.closed("a", at: 20)], "閉区間で絞る")
    XCTAssertEqual(
      try SessionLogReader.read(url, sessionId: "b").events.map { $0.closeOrigin == nil },
      [true, false])
  }

  func testReaderKeepsNewestWhenOverLimit() throws {
    let url = try tempLogFile()
    for i in 0..<5 { try SessionLogWriter.append(Fixture.opened("s\(i)", at: Double(i)), to: url) }
    let result = try SessionLogReader.read(url, limit: 2)
    XCTAssertEqual(result.events.map(\.sessionId), ["s3", "s4"])
    XCTAssertTrue(result.truncated)
    XCTAssertFalse(try SessionLogReader.read(url, limit: 5).truncated)
  }

  func testRewriteReplacesContentAndLeavesNoTempFile() throws {
    let url = try tempLogFile()
    try SessionLogWriter.append(Fixture.opened("old", at: 0), to: url)
    try SessionLogWriter.rewrite([Fixture.opened("new", at: 1)], to: url)

    XCTAssertEqual(try SessionLogReader.read(url).events.map(\.sessionId), ["new"])
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path)
    XCTAssertEqual(siblings, [url.lastPathComponent])
  }
}
