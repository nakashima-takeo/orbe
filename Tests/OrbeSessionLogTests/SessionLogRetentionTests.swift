import Foundation
import XCTest

@testable import OrbeSessionLog

/// 保持規則。壊れるとログが際限なく育つか、30 日以内の行が消える。
final class SessionLogRetentionTests: XCTestCase {
  func testDropsRowsOlderThanRetention() {
    let now = Fixture.base.addingTimeInterval(30 * 86400)
    let events = [
      Fixture.opened("old", at: -1), Fixture.opened("edge", at: 0), Fixture.opened("new", at: 1),
    ]
    XCTAssertEqual(
      SessionLogRetention.prune(events, now: now).map(\.sessionId), ["edge", "new"],
      "ちょうど 30 日は残り、それより古い行が落ちる")
  }

  func testDropsOldestUntilUnderByteBudget() throws {
    let events = (0..<10).map { Fixture.opened("s\($0)", at: Double($0)) }
    let lineBytes = try SessionLogWriter.encodeLine(events[0]).count
    let kept = SessionLogRetention.prune(
      events, now: Fixture.base.addingTimeInterval(100), maxBytes: lineBytes * 3)
    XCTAssertEqual(kept.map(\.sessionId), ["s7", "s8", "s9"], "古い側から落として予算に収める")
  }

  func testNothingToPruneReturnsSameEvents() {
    let events = [Fixture.opened("a", at: 0), Fixture.closed("a", at: 1)]
    XCTAssertEqual(
      SessionLogRetention.prune(events, now: Fixture.base.addingTimeInterval(2)), events)
  }
}
