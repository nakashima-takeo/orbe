import Foundation
import XCTest

@testable import Orbe

/// 自動化の 6 動詞の params の語と型検査。定義は `definition` の欄を保存と同じ形で読み、読めない箇所を -32602 の文に入れる。
///
/// 壊れると何が起きるか: 段や出力先の書き忘れが形の上で通り、何も出さない自動化ができる。取得元がコマンドと agent の
/// 両方の形を持っても黙ってどちらかに落ちる。取得の性質の書き忘れが黙ってどちらかに落ち、候補が下がる・下がらないが
/// AI の意図と食い違う。段にツールを渡せてしまう。`paused` に文字列を渡して止めたつもりが再開になる。
extension ControlWireTests {
  /// 自動化の 6 動詞の正しい params 一式（`validRequests` の一部）。
  var automationRequests: [(method: String, params: [String: Any])] {
    [
      ("list_automations", [:]),
      (
        "set_automation",
        [
          "definition": [
            "name": "GitHub: レビュー依頼",
            "trigger": ["everyMinutes": 30],
            "source": ["command": "gh api notifications", "coverage": "currentSet"],
            "steps": [["name": "判定", "instruction": "自分がやること"]],
            "sink": ["kind": "taskCandidates"],
          ]
        ]
      ),
      ("run_automation", ["automationId": 2]),
      ("pause_automation", ["automationId": 2, "paused": true]),
      ("delete_automation", ["automationId": 2]),
      ("list_automation_proposals", ["automationId": 2]),
    ]
  }

  private var definition: [String: Any] {
    [
      "name": "Slack: 自分宛",
      "trigger": ["cron": " */10 9-18 * * 1-5 "],
      "source": [
        "agent": "claude", "tools": ["mcp__slack__search"], "request": "DM",
        "coverage": "newArrivals",
      ],
      "steps": [
        ["name": "絞り込み", "command": "jq -c ."],
        ["name": "判定", "model": "opus", "instruction": "自分がやること"],
      ],
      "sink": ["kind": "taskCandidates"],
    ]
  }

  /// cron 式は前後の空白を除いて受けたまま運ぶ（一覧はそのまま返す）。
  func testSetAutomationCarriesTheDefinitionToTheTarget() throws {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let params: [String: Any] = ["automationId": 3, "callerTabId": 7, "definition": definition]

    let response = wire.request(id: 1, method: "set_automation", params: params)

    XCTAssertNil(response?["error"])
    XCTAssertEqual(fake.setAutomations.last?.automationId, 3)
    XCTAssertEqual(
      fake.setAutomations.last?.definition,
      AutomationDefinition(
        name: "Slack: 自分宛",
        trigger: .cron(try BackgroundCron("*/10 9-18 * * 1-5")),
        source: AutomationSource(
          method: .agent(
            AutomationSourceAgent(
              cli: "claude", model: nil, tools: ["mcp__slack__search"], request: "DM")),
          coverage: .newArrivals),
        steps: [
          AutomationStep(
            name: "絞り込み", method: .command(BackgroundCommand(script: "jq -c ."))),
          AutomationStep(
            name: "判定",
            method: .agent(
              AutomationStepAgent(cli: "claude", model: "opus", instruction: "自分がやること"))),
        ],
        sink: .taskCandidates),
      "段の agent は省略で claude・モデルは省略のまま")
  }

  func testSetAutomationRejectsAnIncompleteOrAmbiguousDefinition() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    func with(_ key: String, _ value: Any?) -> [String: Any] {
      var changed = definition
      changed[key] = value
      return ["definition": changed]
    }

    for (label, params, message) in [
      ("定義がオブジェクトでない", ["definition": "x"], "invalid definition"),
      ("段が無い", with("steps", nil), "missing steps"),
      ("出力先が無い", with("sink", nil), "missing sink"),
      (
        "取得元が 2 つの形", with("source", ["command": "gh api", "request": "x", "tools": ["Read"]]),
        "invalid source: pass either command (a shell command) or request (an agent fetch)"
      ),
      ("取得の性質が無い", with("source", ["command": "gh api notifications"]), "missing source.coverage"),
      (
        "知らない取得の性質", with("source", ["command": "gh api notifications", "coverage": "all"]),
        "invalid source.coverage: pass newArrivals, currentSet or everything"
      ),
      (
        "段にツール", with("steps", [["name": "判定", "instruction": "x", "tools": ["Read"]]]),
        "invalid steps[0].tools: a step has no tools"
      ),
      (
        "段が 2 つの形", with("steps", [["name": "判定", "command": "jq", "instruction": "x"]]),
        "invalid steps[0]: pass either command (a shell command) or instruction (an agent step)"
      ),
      (
        "cron の欄が範囲外", with("trigger", ["cron": "0 24 * * *"]),
        "invalid trigger.cron: invalid hour field: 24"
      ),
      (
        "cron で日と曜日の両方", with("trigger", ["cron": "0 9 1 * 1"]),
        "invalid trigger.cron: leave the day of month or the weekday as *"
      ),
      (
        "間隔と cron の両方", with("trigger", ["everyMinutes": 30, "cron": "0 9 * * *"]),
        "invalid trigger: pass either everyMinutes or cron"
      ),
      ("間隔が文字列", with("trigger", ["everyMinutes": "30"]), "invalid trigger.everyMinutes"),
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
    _ = wire.request(id: 5, method: "run_automation", params: ["automationId": 2])
    _ = wire.request(id: 6, method: "delete_automation", params: ["automationId": 2])
    _ = wire.request(id: 7, method: "list_automation_proposals", params: [:])
    _ = wire.request(id: 8, method: "list_automation_proposals", params: ["automationId": 2])

    XCTAssertEqual(fake.pausedAutomations.map(\.paused), [false])
    XCTAssertEqual(fake.ranAutomationIds, [2])
    XCTAssertEqual(fake.deletedAutomationIds, [2])
    XCTAssertEqual(fake.proposalLists, [nil, 2])
  }
}
