import Foundation
import XCTest

@testable import OrbeSessionLog

/// wire 形（1 行の JSON）の契約。壊れると Orbe が書いた行を `orb` が読めなくなるか、opened に
/// 終わり方やタイトルが付いた嘘の行が通る。
final class SessionEventCodingTests: XCTestCase {
  private func json(_ event: SessionEvent) throws -> [String: Any] {
    let data = try SessionLogWriter.encodeLine(event)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testOpenedCarriesNoOriginReasonOrTitle() throws {
    let obj = try json(Fixture.opened("a", at: 0))
    XCTAssertEqual(obj["event"] as? String, "opened")
    XCTAssertNil(obj["origin"])
    XCTAssertNil(obj["reason"])
    XCTAssertNil(obj["title"])
    XCTAssertEqual((obj["agent"] as? [String: Any])?["sessionId"] as? String, "a")
    XCTAssertEqual((obj["workspace"] as? [String: Any])?["rootPath"] as? String, "/repo")
  }

  func testClosedCarriesOriginAndOptionalReason() throws {
    let with = try json(Fixture.closed("a", at: 0, origin: .agent, reason: "logout"))
    XCTAssertEqual(with["event"] as? String, "closed")
    XCTAssertEqual(with["origin"] as? String, "agent")
    XCTAssertEqual(with["reason"] as? String, "logout")
    let without = try json(Fixture.closed("a", at: 0, origin: .controlAPI))
    XCTAssertEqual(without["origin"] as? String, "controlAPI")
    XCTAssertNil(without["reason"])
  }

  func testClosedCarriesTitleOnlyWhenNonEmpty() throws {
    let with = try json(Fixture.closed("a", at: 0, title: "swift test"))
    XCTAssertEqual(with["title"] as? String, "swift test")
    XCTAssertNil(try json(Fixture.closed("a", at: 0))["title"])
    XCTAssertNil(try json(Fixture.closed("a", at: 0, title: ""))["title"], "空のタイトルは省略")
    XCTAssertNil(Fixture.closed("a", at: 0, title: "").closeTitle, "構築時に nil へ正規化")
  }

  func testTimestampIsUTCWithMillisecondsAndZ() throws {
    let obj = try json(Fixture.opened("a", at: 0.5))
    XCTAssertEqual(obj["ts"] as? String, "2027-01-15T08:00:00.500Z")
  }

  func testRoundTripPreservesEvent() throws {
    for event in [
      Fixture.opened("a", at: 1.25),
      Fixture.closed("b", at: 2, origin: .unresolved),
      Fixture.closed("c", at: 3, origin: .gesture, reason: "x"),
      Fixture.closed("d", at: 4, origin: .process, title: "deploy-api"),
    ] {
      let line = try SessionLogWriter.encodeLine(event)
      XCTAssertEqual(try JSONDecoder().decode(SessionEvent.self, from: line), event)
    }
  }

  func testWholeSecondTimestampIsAccepted() throws {
    let line = """
      {"ts":"2027-01-15T08:00:00Z","event":"opened","workspace":{"name":"w","rootPath":"/r"},\
      "cwd":"/r","agent":{"command":"claude","sessionId":"a"}}
      """
    let event = try JSONDecoder().decode(SessionEvent.self, from: Data(line.utf8))
    XCTAssertEqual(event.ts, Fixture.base)
  }

  func testOpenedWithOriginReasonOrTitleIsUndecodable() {
    for extra in [#""origin":"process","#, #""reason":"x","#, #""title":"x","#] {
      let line = """
        {"ts":"2027-01-15T08:00:00Z","event":"opened",\(extra)\
        "workspace":{"name":"w","rootPath":"/r"},"cwd":"/r",\
        "agent":{"command":"claude","sessionId":"a"}}
        """
      XCTAssertThrowsError(
        try JSONDecoder().decode(SessionEvent.self, from: Data(line.utf8)), extra)
    }
  }

  func testEmptyTitleOnTheWireDecodesAsNil() throws {
    let line = """
      {"ts":"2027-01-15T08:00:00Z","event":"closed","origin":"gesture","title":"",\
      "workspace":{"name":"w","rootPath":"/r"},"cwd":"/r",\
      "agent":{"command":"claude","sessionId":"a"}}
      """
    XCTAssertNil(try JSONDecoder().decode(SessionEvent.self, from: Data(line.utf8)).closeTitle)
  }

  func testTimestampIsHeldAtWirePrecision() throws {
    let event = Fixture.opened("a", at: 0.1234567)
    let line = try SessionLogWriter.encodeLine(event)
    XCTAssertEqual(
      try JSONDecoder().decode(SessionEvent.self, from: line), event,
      "メモリの値と読み戻した値が等しい（ミリ秒未満は構築時に落ちる）")
  }

  func testISO8601HelpersAgree() {
    let date = Fixture.base.addingTimeInterval(12.345)
    let text = SessionEvent.iso8601(date)
    XCTAssertEqual(text, "2027-01-15T08:00:12.345Z")
    XCTAssertEqual(SessionEvent.parseISO8601(text), date)
    XCTAssertNil(SessionEvent.parseISO8601("yesterday"))
  }
}
