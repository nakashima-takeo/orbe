import Foundation
import XCTest

@testable import Orbe

/// 待ちの条件の params（`add_task` / `update_task` の `waitingCondition`）の形と日時の読み方、`update_task` が呼び出し元
/// タブを target へ届けること。値の規則（期限が未来・間隔の下限）はストアが持ち、ここは形だけを見る。
///
/// 壊れると何が起きるか: 時差の無い期限が UTC と読まれ、Mac の時刻で 9 時間ずれて解ける。`null`（条件だけを外す）が
/// 「変えない」になり、外したつもりの条件が裏で走り続ける。呼び出し元タブが届かず、`orb task set` で付けた条件に
/// 作業ディレクトリも会話も入らない。
extension ControlWireTests {
  private var condition: [String: Any] {
    [
      "description": "レビューが付いたら", "command": "gh pr view 214", "intervalMinutes": 10,
      "deadline": "2026-10-13T09:00:00+09:00",
    ]
  }

  func testUpdateTaskCarriesTheConditionAndTheCallerTab() throws {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "update_task",
      params: ["taskId": 7, "waitingCondition": condition, "callerTabId": 42])

    let updated = try XCTUnwrap(fake.updatedTasks.last)
    XCTAssertEqual(updated.callerTabId, 42)
    guard case .set(let request) = updated.update.waitingCondition else {
      return XCTFail("条件が届いていない")
    }
    XCTAssertEqual(request.description, "レビューが付いたら")
    XCTAssertEqual(request.command, "gh pr view 214")
    XCTAssertEqual(request.intervalMinutes, 10)
    XCTAssertEqual(request.deadline, Date(timeIntervalSince1970: 1_791_849_600))
    XCTAssertNil(request.directory, "作業ディレクトリと会話は target が呼び出し元タブから入れる")
    XCTAssertNil(request.conversation)

    _ = wire.request(
      id: 2, method: "update_task", params: ["taskId": 7, "waitingCondition": NSNull()])
    guard case .clear = fake.updatedTasks.last?.update.waitingCondition else {
      return XCTFail("null は条件だけを外す")
    }
  }

  func testDeadlineWithoutAnOffsetIsReadInTheMacsTimeZone() throws {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var local = condition
    local["deadline"] = "2026-10-13T09:00"

    _ = wire.request(id: 1, method: "add_task", params: ["title": "a", "waitingCondition": local])

    let request = try XCTUnwrap(fake.addedTasks.last?.draft.waitingCondition)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    XCTAssertEqual(
      request.deadline,
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9)))
  }

  func testMalformedConditionsAreRejectedBeforeReachingTheTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var rejected: [Any] = ["PR が付いたら", ["description": "a"]]
    for (key, bad) in [
      ("description", 1), ("command", NSNull()), ("intervalMinutes", "10"),
      ("intervalMinutes", true), ("deadline", "来週"), ("deadline", "2026-10-13"),
    ] as [(String, Any)] {
      var value = condition
      value[key] = bad
      rejected.append(value)
    }

    for (index, value) in rejected.enumerated() {
      XCTAssertEqual(
        errorCode(
          wire.request(
            id: index, method: "update_task", params: ["taskId": 7, "waitingCondition": value])),
        -32602, "\(value) は -32602")
    }
    XCTAssertTrue(fake.updatedTasks.isEmpty)
  }
}
