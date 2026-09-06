import Foundation
import XCTest

@testable import OrbeSessionLog

/// 派生（閉じたまま戻っていないもの・事故の群）の契約。壊れると復元一覧に生きているセッションが
/// 混ざるか、群の 1 件を戻した瞬間に群の時刻が動いて `--at` とパレットの錨が外れる。
final class SessionLogQueryTests: XCTestCase {
  // MARK: closedNotPresent

  func testOnlyIdsWhoseLastEventIsClosedAndAbsentAreReturned() {
    let events = [
      Fixture.opened("live", at: 0),
      Fixture.opened("gone", at: 1), Fixture.closed("gone", at: 2),
      Fixture.opened("back", at: 3), Fixture.closed("back", at: 4), Fixture.opened("back", at: 5),
      Fixture.opened("present", at: 6), Fixture.closed("present", at: 7),
      Fixture.opened("again", at: 8), Fixture.closed("again", at: 9),
      Fixture.opened("again", at: 10), Fixture.closed("again", at: 11),
    ]
    let gone = SessionLogQuery.closedNotPresent(events: events, present: ["present"])
    XCTAssertEqual(gone.map(\.sessionId), ["gone", "again"], "ファイル順で、最後が closed の id だけ")
    XCTAssertEqual(gone.last?.ts, Fixture.base.addingTimeInterval(11), "再 opened 後の最後の closed")
  }

  // MARK: bursts

  func testSameOriginWithinWindowJoinsAndAtIsTheOldest() {
    let bursts = SessionLogQuery.bursts([
      Fixture.closed("c", at: 4), Fixture.closed("a", at: 0), Fixture.closed("b", at: 2),
    ])
    XCTAssertEqual(bursts.count, 1)
    XCTAssertEqual(bursts[0].at, Fixture.base, "at は最古の closed")
    XCTAssertEqual(bursts[0].sessions.map(\.sessionId), ["a", "b", "c"], "群内は時刻昇順")
  }

  func testSameTimestampKeepsInputOrder() {
    let ids = (0..<20).map { "s\($0)" }
    let bursts = SessionLogQuery.bursts(ids.map { Fixture.closed($0, at: 1) })
    XCTAssertEqual(bursts.count, 1)
    XCTAssertEqual(bursts[0].sessions.map(\.sessionId), ids, "同時刻の closed はファイル順で安定")
  }

  func testWindowIsMeasuredFromThePreviousMember() {
    let chain = SessionLogQuery.bursts([
      Fixture.closed("a", at: 0), Fixture.closed("b", at: 4), Fixture.closed("c", at: 8),
    ])
    XCTAssertEqual(chain.count, 1, "直前の要素から 5 秒以内なら繋がる（先頭からではない）")
    let split = SessionLogQuery.bursts([Fixture.closed("a", at: 0), Fixture.closed("b", at: 5.5)])
    XCTAssertEqual(split.count, 2, "5 秒超で切れる")
  }

  func testDifferentOriginSplitsAndGestureIsAlwaysAlone() {
    let bursts = SessionLogQuery.bursts([
      Fixture.closed("a", at: 0, origin: .process),
      Fixture.closed("b", at: 1, origin: .controlAPI),
      Fixture.closed("c", at: 2, origin: .gesture),
      Fixture.closed("d", at: 3, origin: .gesture),
      Fixture.closed("e", at: 4, origin: .agent),
      Fixture.closed("f", at: 5, origin: .agent),
    ])
    XCTAssertEqual(bursts.map(\.origin), [.process, .controlAPI, .gesture, .gesture, .agent])
    XCTAssertEqual(bursts.map { $0.sessions.count }, [1, 1, 1, 1, 2])
  }

  // MARK: closedGroups

  func testGroupAtStaysWhenAMemberComesBack() {
    let events = [
      Fixture.opened("a", at: 0), Fixture.opened("b", at: 0),
      Fixture.closed("a", at: 10), Fixture.closed("b", at: 12),
    ]
    let before = SessionLogQuery.closedGroups(events: events, present: [])
    XCTAssertEqual(before.map { $0.sessions.map(\.sessionId) }, [["a", "b"]])

    let after = SessionLogQuery.closedGroups(events: events, present: ["a"])
    XCTAssertEqual(after.map { $0.sessions.map(\.sessionId) }, [["b"]])
    XCTAssertEqual(after[0].at, before[0].at, "a を戻しても群の at は動かない")
  }

  func testGroupDisappearsWhenEveryMemberIsPresent() {
    let events = [Fixture.opened("a", at: 0), Fixture.closed("a", at: 10)]
    XCTAssertTrue(SessionLogQuery.closedGroups(events: events, present: ["a"]).isEmpty)
  }

  func testReclosedIdStaysOnlyInItsLastGroup() {
    let events = [
      Fixture.opened("a", at: 0), Fixture.closed("a", at: 10),
      Fixture.opened("a", at: 20), Fixture.closed("a", at: 100),
    ]
    let groups = SessionLogQuery.closedGroups(events: events, present: [])
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].at, Fixture.base.addingTimeInterval(100))
  }

  func testGroupsAreAscendingAndAtISOMatchesWire() {
    let events = [
      Fixture.opened("a", at: 0), Fixture.closed("a", at: 1.5),
      Fixture.opened("b", at: 0), Fixture.closed("b", at: 60, origin: .gesture),
    ]
    let groups = SessionLogQuery.closedGroups(events: events, present: [])
    XCTAssertEqual(groups.map(\.atISO), ["2027-01-15T08:00:01.500Z", "2027-01-15T08:01:00.000Z"])
  }
}
