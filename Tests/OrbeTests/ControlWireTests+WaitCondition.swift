import Foundation
import XCTest

@testable import Orbe

/// 待ちの条件の口（`set_wait_condition`）の params の形と日時の読み方、呼び出し元タブを target へ届けること、帳簿の動詞
/// （`add_task` / `update_task`）が条件を受けないこと。値の規則（期限が未来・間隔の下限）はストアが持ち、ここは形だけを
/// 見る。
///
/// 壊れると何が起きるか: 時差の無い期限が UTC と読まれ、Mac の時刻で 9 時間ずれて解ける。`null`（条件だけを外す）が
/// 「変えない」になり、外したつもりの条件が裏で走り続ける。呼び出し元タブが届かず、条件に作業ディレクトリも会話も
/// 入らない。帳簿の動詞を「常に許可」した agent に、裏で走る任意のコマンドを登録させる抜け道ができる。
extension ControlWireTests {
  private var condition: [String: Any] {
    [
      "description": "レビューが付いたら", "command": "gh pr view 214", "everyMinutes": 10,
      "deadline": "2026-10-13T09:00:00+09:00",
    ]
  }

  func testSetWaitConditionCarriesTheConditionAndTheCallerTab() throws {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "set_wait_condition",
      params: ["taskId": 7, "condition": condition, "callerTabId": 42])

    let set = try XCTUnwrap(fake.setWaitConditions.last)
    XCTAssertEqual(set.taskId, 7)
    XCTAssertEqual(set.callerTabId, 42)
    guard case .set(let request) = set.condition else { return XCTFail("条件が届いていない") }
    XCTAssertEqual(request.description, "レビューが付いたら")
    XCTAssertEqual(request.command, "gh pr view 214")
    XCTAssertEqual(request.everyMinutes, 10)
    XCTAssertEqual(request.deadline, Date(timeIntervalSince1970: 1_791_849_600))
    XCTAssertNil(request.directory, "作業ディレクトリと会話は target が呼び出し元タブから入れる")
    XCTAssertNil(request.conversation)

    _ = wire.request(
      id: 2, method: "set_wait_condition", params: ["taskId": 7, "condition": NSNull()])
    guard case .clear = fake.setWaitConditions.last?.condition else {
      return XCTFail("null は条件だけを外す")
    }
  }

  func testDeadlineWithoutAnOffsetIsReadInTheMacsTimeZone() throws {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var local = condition
    local["deadline"] = "2026-10-13T09:00"

    _ = wire.request(
      id: 1, method: "set_wait_condition", params: ["taskId": 7, "condition": local])

    guard case .set(let request) = fake.setWaitConditions.last?.condition else {
      return XCTFail("条件が届いていない")
    }
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
      ("description", 1), ("command", NSNull()), ("everyMinutes", "10"),
      ("everyMinutes", true), ("deadline", "来週"), ("deadline", "2026-10-13"),
    ] as [(String, Any)] {
      var value = condition
      value[key] = bad
      rejected.append(value)
    }

    for (index, value) in rejected.enumerated() {
      XCTAssertEqual(
        errorCode(
          wire.request(
            id: index, method: "set_wait_condition", params: ["taskId": 7, "condition": value])),
        -32602, "\(value) は -32602")
    }
    XCTAssertEqual(
      errorCode(wire.request(id: 99, method: "set_wait_condition", params: ["taskId": 7])), -32602,
      "condition を省けない（外すのは null）")
    XCTAssertTrue(fake.setWaitConditions.isEmpty)
  }

  /// 帳簿の動詞は条件を受けない（届いても無視され、target に条件は渡らない）。
  func testTaskVerbsDoNotCarryAWaitingCondition() throws {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "update_task",
      params: ["taskId": 7, "title": "t", "waitingCondition": condition])

    XCTAssertNil(try XCTUnwrap(fake.updatedTasks.last).update.waitingCondition)
    XCTAssertTrue(fake.setWaitConditions.isEmpty)
  }
}
