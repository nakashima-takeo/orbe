import Foundation
import XCTest

@testable import Orbe

/// 自動化の 9 動詞の params の語と型検査。定義は `definition` の欄を保存と同じ形で読み、読めない箇所を定義の中の場所付きで
/// -32602 の文に入れる。値と組み合わせ（グラフ）の検証は target が持つ。
///
/// 壊れると何が起きるか: 部品の書き忘れが形の上で通り、何もしない自動化ができる。部品がコマンドと agent の両方の形を持っても
/// 黙ってどちらかに落ちる。取得の性質や予定の書き損じが黙ってどちらかに落ち、AI の意図と違う予定で回る。断りの文が定義の
/// どこを直せばよいかを言わず、AI が直せない。`paused` に文字列を渡して止めたつもりが再開になる。
extension ControlWireTests {
  /// 自動化の 9 動詞の正しい params 一式（`validRequests` の一部）。
  var automationRequests: [(method: String, params: [String: Any])] {
    [
      ("list_automations", [:]),
      ("set_automation", ["definition": definition]),
      ("list_automation_runs", ["automationId": 2, "partKey": "judge", "before": 9, "limit": 5]),
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
      "agent": "claude", "tools": ["mcp__slack__search"], "instruction": "DM",
      "coverage": "newArrivals",
    ]
  }

  private var judge: [String: Any] {
    [
      "id": 4, "key": "judge", "name": "判定", "trigger": ["kind": "arrival"],
      "from": [["part": "slack", "maxAgeHours": 24]], "maxItems": 30,
      "model": "opus", "instruction": "自分がやること", "deliver": "taskCandidates",
    ]
  }

  private var definition: [String: Any] {
    ["name": "Slack: 自分宛", "parts": [fetch, judge]]
  }

  /// cron 式は前後の空白を除いて受けたまま運ぶ。部品の id・入力の取り方・件数の上限と、書き換えの版も運ぶ。
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
      fake.setAutomations.last?.definition,
      AutomationDefinition(
        name: "Slack: 自分宛", notify: nil,
        parts: [
          AutomationDefinition.Node(
            id: nil, key: "slack", name: "Slack: 自分宛",
            trigger: .scheduled(.cron(try BackgroundCron("*/10 9-18 * * 1-5"))), from: [],
            action: AutomationActionDef(
              method: .agent(
                AutomationNodeAgent(
                  cli: "claude", model: nil, tools: ["mcp__slack__search"], instruction: "DM")),
              timeoutMinutes: nil, coverage: .newArrivals, destination: .nextPart),
            maxItems: nil),
          AutomationDefinition.Node(
            id: AutomationNodeID(4), key: "judge", name: "判定", trigger: .arrival,
            from: [AutomationDefinition.Input(part: "slack", maxAgeHours: 24)],
            action: AutomationActionDef(
              method: .agent(
                AutomationNodeAgent(
                  cli: "claude", model: "opus", tools: [], instruction: "自分がやること")),
              timeoutMinutes: nil, coverage: nil, destination: .taskCandidates),
            maxItems: 30),
        ]),
      "agent は省略で claude・モデルは省略のまま")
  }

  func testSetAutomationRejectsAnIncompleteOrAmbiguousDefinition() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    func with(_ key: String, _ value: Any?) -> [String: Any] {
      var changed = fetch
      changed[key] = value
      return ["definition": ["name": "x", "parts": [changed, judge]]]
    }

    for (label, params, message) in [
      ("定義がオブジェクトでない", ["definition": "x"], "invalid definition"),
      ("部品が無い", ["definition": ["name": "x"]], "missing parts"),
      (
        "知らない通知先", ["definition": ["name": "x", "notify": "mail", "parts": [fetch, judge]]],
        "invalid notify: pass menuBar or notificationCenter"
      ),
      ("予定が無い", with("trigger", nil), "missing parts[0].trigger"),
      (
        "部品が 2 つの形", with("command", "gh api"),
        "invalid parts[0]: pass either command (a shell command) or instruction (an agent)"
      ),
      (
        "毎回全件の取得の性質", with("coverage", "everything"),
        "invalid parts[0].coverage: pass currentSet or newArrivals"
      ),
      (
        "知らない取り方", with("from", [["part": "x", "take": "some"]]),
        "invalid parts[0].from[0].take: pass new or all"
      ),
      (
        "数でない件数の上限", with("maxItems", "many"), "invalid parts[0].maxItems"
      ),
      (
        "知らない予定の種類", with("trigger", ["kind": "daily"]),
        "invalid parts[0].trigger.kind: pass interval, cron, manual or arrival"
      ),
      (
        "cron の欄が範囲外", with("trigger", ["kind": "cron", "expression": "0 24 * * *"]),
        "invalid parts[0].trigger.expression: invalid hour field: 24"
      ),
      (
        "間隔が文字列", with("trigger", ["kind": "interval", "minutes": "30"]),
        "invalid parts[0].trigger.minutes"
      ),
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
    XCTAssertEqual(
      errorCode(
        wire.request(id: 9, method: "run_automation", params: ["automationId": 2, "partKey": 1])),
      -32602)
    _ = wire.request(id: 5, method: "run_automation", params: ["automationId": 2])
    _ = wire.request(
      id: 10, method: "run_automation", params: ["automationId": 2, "partKey": "judge"])
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
      params: ["automationId": 2, "partKey": "judge", "before": 9, "limit": 5])

    XCTAssertEqual(fake.pausedAutomations.map(\.paused), [false])
    XCTAssertEqual(fake.ranAutomations.map(\.automationId), [2, 2])
    XCTAssertEqual(fake.ranAutomations.map(\.partKey), [nil, "judge"])
    XCTAssertEqual(fake.deletedAutomationIds, [2])
    XCTAssertEqual(fake.proposalLists, [nil, 2])
    XCTAssertEqual(fake.runLists.map(\.partKey), ["judge"])
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
