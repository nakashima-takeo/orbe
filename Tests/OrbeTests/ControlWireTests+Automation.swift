import Foundation
import XCTest

@testable import Orbe

/// 自動化の 9 動詞の params の語と型検査。定義は `definition` の欄がオブジェクトであることだけを見て、外の形の JSON のまま
/// target へ運ぶ。定義の読みと値・組み合わせ（グラフ）の検証は target が持つ。
///
/// 壊れると何が起きるか: 定義の欄が別の値に化けて target へ届く。`paused` に文字列を渡して止めたつもりが再開になる。
extension ControlWireTests {
  /// 自動化の 9 動詞の正しい params 一式（`validRequests` の一部）。
  var automationRequests: [(method: String, params: [String: Any])] {
    [
      ("list_automations", [:]),
      ("set_automation", ["definition": definition]),
      ("list_automation_runs", ["automationId": 2, "nodeKey": "judge", "before": 9, "limit": 5]),
      ("run_automation", ["automationId": 2]),
      ("pause_automation", ["automationId": 2, "paused": true]),
      ("delete_automation", ["automationId": 2]),
      ("list_automation_proposals", ["automationId": 2]),
      (
        "try_automation",
        [
          "automationId": 2, "from": ["slack"], "to": ["judge"],
          "rows": [["id": "a", "link": "https://example.com/a"]], "limit": 3,
        ]
      ),
      ("get_automation_trial", ["automationId": 2, "wait": true, "timeoutMs": 500]),
      ("run_tool", ["token": "t", "name": "read_run_rows", "arguments": ["offset": 50]]),
    ]
  }

  private var fetch: [String: Any] {
    [
      "key": "slack", "name": "Slack: 自分宛",
      "trigger": ["kind": "cron", "expression": " */10 9-18 * * 1-5 "],
      "agent": "claude", "model": "haiku", "tools": ["mcp__slack__search"], "instruction": "DM",
      "coverage": "newArrivals",
    ]
  }

  private var judge: [String: Any] {
    [
      "id": 4, "key": "judge", "name": "判定", "trigger": ["kind": "arrival"],
      "from": [["node": "slack", "maxAgeHours": 24]], "maxItems": 30,
      "model": "opus", "instruction": "自分がやること", "deliver": "taskCandidates",
    ]
  }

  private var definition: [String: Any] {
    ["name": "Slack: 自分宛", "nodes": [fetch, judge]]
  }

  /// 定義は外の形の JSON のまま target へ運ぶ（workspace の席の写しと読みは target が持つ）。書き換えの版も運ぶ。
  func testSetAutomationCarriesTheDefinitionToTheTarget() throws {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let params: [String: Any] = [
      "automationId": 3, "version": 5, "callerTabId": 7, "definition": definition,
    ]

    let response = wire.request(id: 1, method: "set_automation", params: params)

    XCTAssertNil(response?["error"])
    XCTAssertEqual(fake.setAutomations.last?.automationId, 3)
    XCTAssertEqual(fake.setAutomations.last?.version, 5)
    XCTAssertEqual(
      fake.setAutomations.last.map { NSDictionary(dictionary: $0.definition) },
      NSDictionary(dictionary: definition))
  }

  func testSetAutomationRejectsADefinitionThatIsNotAnObject() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    for (label, params, message) in [
      ("定義が無い", [String: Any](), "missing definition"),
      ("定義がオブジェクトでない", ["definition": "x"], "invalid definition"),
    ] {
      let response = wire.request(id: 1, method: "set_automation", params: params)
      XCTAssertEqual(errorCode(response), -32602, label)
      XCTAssertEqual((response?["error"] as? [String: Any])?["message"] as? String, message, label)
    }
    XCTAssertTrue(fake.setAutomations.isEmpty, "不正な定義は target へ届かない")
  }

  func testAutomationVerbsCheckTheirParams() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    XCTAssertEqual(
      errorCode(wire.request(id: 1, method: "run_automation", params: ["automationId": true])),
      -32602)
    XCTAssertEqual(
      errorCode(
        wire.request(
          id: 2, method: "pause_automation", params: ["automationId": 1, "paused": "yes"])),
      -32602)
    XCTAssertEqual(
      errorCode(
        wire.request(id: 3, method: "pause_automation", params: ["automationId": 1, "paused": 1])),
      -32602, "真偽値でない 1 を true と読まない")
    _ = wire.request(
      id: 4, method: "pause_automation", params: ["automationId": 2, "paused": false])
    _ = wire.request(
      id: 13, method: "pause_automation",
      params: ["automationId": 2, "nodeKey": "judge", "paused": true])
    XCTAssertEqual(
      errorCode(
        wire.request(id: 9, method: "run_automation", params: ["automationId": 2, "nodeKey": 1])),
      -32602)
    _ = wire.request(id: 5, method: "run_automation", params: ["automationId": 2])
    _ = wire.request(
      id: 10, method: "run_automation", params: ["automationId": 2, "nodeKey": "judge"])
    _ = wire.request(id: 6, method: "delete_automation", params: ["automationId": 2])
    _ = wire.request(id: 7, method: "list_automation_proposals", params: [:])
    _ = wire.request(id: 8, method: "list_automation_proposals", params: ["automationId": 2])
    XCTAssertEqual(
      errorCode(
        wire.request(
          id: 11, method: "list_automation_runs", params: ["automationId": 2, "before": "9"])),
      -32602)
    _ = wire.request(
      id: 12, method: "list_automation_runs",
      params: ["automationId": 2, "nodeKey": "judge", "before": 9, "limit": 5])

    XCTAssertEqual(fake.pausedAutomations.map(\.paused), [false, true])
    XCTAssertEqual(fake.pausedAutomations.map(\.nodeKey), [nil, "judge"])
    XCTAssertEqual(fake.ranAutomations.map(\.automationId), [2, 2])
    XCTAssertEqual(fake.ranAutomations.map(\.nodeKey), [nil, "judge"])
    XCTAssertEqual(fake.deletedAutomationIds, [2])
    XCTAssertEqual(fake.proposalLists, [nil, 2])
    XCTAssertEqual(fake.runLists.map(\.nodeKey), ["judge"])
    XCTAssertEqual(fake.runLists.map(\.before), [9])
    XCTAssertEqual(fake.runLists.map(\.limit), [5])
  }

  /// 裏の agent の回の道具は、札と道具の名前を必ず受け、引数はオブジェクトだけを運ぶ（無ければ空）。
  func testRunToolCarriesTheTokenTheNameAndTheArguments() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    XCTAssertEqual(
      errorCode(wire.request(id: 1, method: "run_tool", params: ["name": "read_run_rows"])), -32602)
    XCTAssertEqual(
      errorCode(
        wire.request(
          id: 2, method: "run_tool", params: ["token": "t", "name": "x", "arguments": [1]])),
      -32602)
    _ = wire.request(id: 3, method: "run_tool", params: ["token": "t", "name": "report_nothing"])
    _ = wire.request(
      id: 4, method: "run_tool",
      params: ["token": "t", "name": "read_run_rows", "arguments": ["limit": 10]])

    XCTAssertEqual(fake.runTools.map(\.name), ["report_nothing", "read_run_rows"])
    XCTAssertEqual(fake.runTools.map(\.token), ["t", "t"])
    XCTAssertEqual(fake.runTools.map { $0.arguments["limit"] as? Int }, [nil, 10])
  }

  /// 試走の範囲は鍵の列、与える行は JSON オブジェクトの列で受け、1 要素 1 行の JSON にして運ぶ。待つ上限の既定は 1 時間。
  func testTrialVerbsCarryTheirParams() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    for (index, params) in [
      ["automationId": 2, "from": "slack"], ["automationId": 2, "to": [1]],
      ["automationId": 2, "rows": ["a"]], ["automationId": 2, "limit": true],
    ].enumerated() {
      XCTAssertEqual(
        errorCode(wire.request(id: index + 1, method: "try_automation", params: params)), -32602,
        "\(params)")
    }
    XCTAssertEqual(
      errorCode(
        wire.request(
          id: 10, method: "get_automation_trial", params: ["automationId": 2, "wait": 1])),
      -32602)
    XCTAssertEqual(
      errorCode(
        wire.request(
          id: 11, method: "get_automation_trial", params: ["automationId": 2, "timeoutMs": 0])),
      -32602)
    XCTAssertTrue(fake.triedAutomations.isEmpty)
    XCTAssertTrue(fake.readTrials.isEmpty)

    _ = wire.request(
      id: 12, method: "try_automation",
      params: [
        "automationId": 2, "from": ["slack"],
        "rows": [["link": "https://example.com/a", "id": "a"]],
      ])
    _ = wire.request(id: 13, method: "try_automation", params: ["automationId": 3])
    _ = wire.request(id: 14, method: "get_automation_trial", params: ["automationId": 2])

    XCTAssertEqual(
      fake.triedAutomations.map(\.request),
      [
        AutomationTrial.Request(
          from: ["slack"], to: nil, rows: [#"{"id":"a","link":"https://example.com/a"}"#],
          limit: nil),
        AutomationTrial.Request(),
      ])
    XCTAssertEqual(fake.readTrials.last?.wait, false)
    XCTAssertEqual(fake.readTrials.last?.timeoutMs, WaitTimeout.promptDefaultMs)
  }
}
