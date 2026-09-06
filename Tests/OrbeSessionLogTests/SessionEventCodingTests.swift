import Foundation
import XCTest

@testable import OrbeSessionLog

/// wire 形（1 行の JSON）の契約。壊れると Orbe が書いた行を `orb` が読めなくなるか、opened に
/// 終わり方が付いた嘘の行が通る。
final class SessionEventCodingTests: XCTestCase {
  private func json(_ event: SessionEvent) throws -> [String: Any] {
    let data = try SessionLogWriter.encodeLine(event)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testOpenedCarriesNoOriginOrReason() throws {
    let obj = try json(Fixture.opened("a", at: 0))
    XCTAssertEqual(obj["event"] as? String, "opened")
    XCTAssertNil(obj["origin"])
    XCTAssertNil(obj["reason"])
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

  func testTimestampIsUTCWithMillisecondsAndZ() throws {
    let obj = try json(Fixture.opened("a", at: 0.5))
    XCTAssertEqual(obj["ts"] as? String, "2027-01-15T08:00:00.500Z")
  }

  func testRoundTripPreservesEvent() throws {
    for event in [
      Fixture.opened("a", at: 1.25),
      Fixture.closed("b", at: 2, origin: .unresolved),
      Fixture.closed("c", at: 3, origin: .gesture, reason: "x"),
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

  func testOpenedWithOriginIsUndecodable() {
    let line = """
      {"ts":"2027-01-15T08:00:00Z","event":"opened","origin":"process",\
      "workspace":{"name":"w","rootPath":"/r"},"cwd":"/r",\
      "agent":{"command":"claude","sessionId":"a"}}
      """
    XCTAssertThrowsError(try JSONDecoder().decode(SessionEvent.self, from: Data(line.utf8)))
  }

  func testISO8601HelpersAgree() {
    let date = Fixture.base.addingTimeInterval(12.345)
    let text = SessionEvent.iso8601(date)
    XCTAssertEqual(text, "2027-01-15T08:00:12.345Z")
    XCTAssertEqual(SessionEvent.parseISO8601(text), date)
    XCTAssertNil(SessionEvent.parseISO8601("yesterday"))
  }
}
