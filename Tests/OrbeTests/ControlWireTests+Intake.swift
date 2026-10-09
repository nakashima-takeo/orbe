import Foundation
import XCTest

@testable import Orbe

/// 受信の 6 動詞の params の語と型検査。定義は intakes.json と同じ形で読み、読めない箇所を -32602 の文に入れる。
///
/// 壊れると何が起きるか: 定義の片方だけの書き換えが形の上で通り、取得か判定が消えた受信ができる。`fetch` がコマンドと
/// agent の両方の形を持っても黙ってどちらかに落ちる。`paused` に文字列を渡して止めたつもりが再開になる。
extension ControlWireTests {
  /// 受信の 6 動詞の正しい params 一式（`validRequests` の一部）。
  var intakeRequests: [(method: String, params: [String: Any])] {
    [
      ("list_intakes", [:]),
      (
        "set_intake",
        [
          "name": "GitHub: レビュー依頼", "fetch": ["command": "gh api notifications"],
          "judge": ["model": "haiku", "instruction": "自分がやること"],
          "when": ["everyMinutes": 30],
        ]
      ),
      ("run_intake", ["intakeId": 2]),
      ("pause_intake", ["intakeId": 2, "paused": true]),
      ("delete_intake", ["intakeId": 2]),
      ("list_intake_proposals", ["intakeId": 2]),
    ]
  }

  private var definitionParams: [String: Any] {
    [
      "name": "Slack: 自分宛",
      "fetch": [
        "agent": "claude", "model": "haiku", "tools": ["mcp__slack__search"], "request": "DM",
      ],
      "judge": ["model": "sonnet", "instruction": "自分がやること"],
      "when": ["dailyAt": ["13:00", "09:00"]],
    ]
  }

  func testSetIntakeCarriesTheDefinitionToTheTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var params = definitionParams
    params["intakeId"] = 3
    params["callerTabId"] = 7

    let response = wire.request(id: 1, method: "set_intake", params: params)

    XCTAssertNil(response?["error"])
    XCTAssertEqual(fake.setIntakes.last?.intakeId, 3)
    XCTAssertEqual(
      fake.setIntakes.last?.definition,
      IntakeDefinition(
        name: "Slack: 自分宛",
        fetch: .agent(
          IntakeAgentFetch(
            cli: "claude", model: "haiku", tools: ["mcp__slack__search"], request: "DM")),
        judge: IntakeJudge(cli: "claude", model: "sonnet", instruction: "自分がやること"),
        when: .daily([.init(hour: 9, minute: 0), .init(hour: 13, minute: 0)])),
      "judge の agent は省略で claude")
  }

  func testSetIntakeRejectsAnIncompleteOrAmbiguousDefinition() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var missingWhen = definitionParams
    missingWhen["when"] = nil
    var both = definitionParams
    both["fetch"] = ["command": "gh api", "request": "x", "model": "m", "tools": ["Read"]]
    var badTime = definitionParams
    badTime["when"] = ["dailyAt": ["9:00"]]
    var minutesAsText = definitionParams
    minutesAsText["when"] = ["everyMinutes": "30"]

    for (label, params, message) in [
      ("いつが無い", missingWhen, "missing when"),
      (
        "取得が 2 つの形", both,
        "invalid fetch: pass either command (a shell command) or request (an agent fetch)"
      ),
      ("HH:MM でない", badTime, "invalid when.dailyAt: not HH:MM: 9:00"),
      ("間隔が文字列", minutesAsText, "invalid when.everyMinutes"),
    ] {
      let response = wire.request(id: 1, method: "set_intake", params: params)
      XCTAssertEqual(errorCode(response), -32602, label)
      XCTAssertEqual((response?["error"] as? [String: Any])?["message"] as? String, message, label)
    }
    XCTAssertTrue(fake.setIntakes.isEmpty, "不正な定義は target へ届かない")
  }

  func testIntakeVerbsCheckTheirParams() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    XCTAssertEqual(
      errorCode(wire.request(id: 1, method: "run_intake", params: ["intakeId": true])), -32602)
    XCTAssertEqual(
      errorCode(
        wire.request(id: 2, method: "pause_intake", params: ["intakeId": 1, "paused": "yes"])),
      -32602)
    XCTAssertEqual(
      errorCode(wire.request(id: 3, method: "pause_intake", params: ["intakeId": 1, "paused": 1])),
      -32602, "真偽値でない 1 を true と読まない")
    _ = wire.request(id: 4, method: "pause_intake", params: ["intakeId": 2, "paused": false])
    _ = wire.request(id: 5, method: "run_intake", params: ["intakeId": 2])
    _ = wire.request(id: 6, method: "delete_intake", params: ["intakeId": 2])
    _ = wire.request(id: 7, method: "list_intake_proposals", params: [:])
    _ = wire.request(id: 8, method: "list_intake_proposals", params: ["intakeId": 2])

    XCTAssertEqual(fake.pausedIntakes.map(\.paused), [false])
    XCTAssertEqual(fake.ranIntakeIds, [2])
    XCTAssertEqual(fake.deletedIntakeIds, [2])
    XCTAssertEqual(fake.proposalLists, [nil, 2])
  }
}
