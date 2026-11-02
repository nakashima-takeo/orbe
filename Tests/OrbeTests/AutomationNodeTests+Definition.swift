import XCTest

@testable import Orbe

/// 定義の JSON の読み（`AutomationDefinition.decode`）。読めない箇所を定義の中の場所付きの文で断る。
///
/// 壊れると何が起きるか: ノードの書き忘れが形の上で通り、何もしない自動化ができる。ノードがコマンドと agent の両方の形を持っても
/// 黙ってどちらかに落ちる。取得の性質や予定の書き損じが黙ってどちらかに落ち、AI の意図と違う予定で回る。断りの文が定義の
/// どこを直せばよいかを言わず、AI が直せない。
extension AutomationNodeTests {
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

  /// cron 式は前後の空白を除いて受けたまま読む。ノードの id・入力の取り方・件数の上限も読む。
  func testTheDefinitionReadsFromItsJSONObject() throws {
    XCTAssertEqual(
      try AutomationDefinition.decode(["name": "Slack: 自分宛", "nodes": [fetch, judge]]),
      AutomationDefinition(
        name: "Slack: 自分宛", notify: nil,
        nodes: [
          AutomationDefinition.Node(
            id: nil, key: "slack", name: "Slack: 自分宛",
            trigger: .scheduled(.cron(try BackgroundCron("*/10 9-18 * * 1-5"))), from: [],
            action: AutomationActionDef(
              method: .agent(
                AutomationNodeAgent(
                  cli: "claude", model: "haiku", tools: ["mcp__slack__search"], instruction: "DM")),
              timeoutMinutes: nil, coverage: .newArrivals, destination: .nextNode),
            maxItems: nil),
          AutomationDefinition.Node(
            id: AutomationNodeID(4), key: "judge", name: "判定", trigger: .arrival,
            from: [AutomationDefinition.Input(nodeKey: "slack", maxAgeHours: 24)],
            action: AutomationActionDef(
              method: .agent(
                AutomationNodeAgent(
                  cli: "claude", model: "opus", tools: [], instruction: "自分がやること")),
              timeoutMinutes: nil, coverage: nil, destination: .taskCandidates),
            maxItems: 30),
        ]),
      "agent は省略で claude")
  }

  func testAnIncompleteOrAmbiguousDefinitionIsRefusedWithItsPlace() {
    func with(_ key: String, _ value: Any?) -> [String: Any] {
      var changed = fetch
      changed[key] = value
      return ["name": "x", "nodes": [changed, judge]]
    }

    for (label, object, message) in [
      ("ノードが無い", ["name": "x"], "missing nodes"),
      (
        "知らない通知先", ["name": "x", "notify": "mail", "nodes": [fetch, judge]],
        "invalid notify: pass menuBar or notificationCenter"
      ),
      ("予定が無い", with("trigger", nil), "missing nodes[0].trigger"),
      ("agent のモデルが無い", with("model", nil), "missing nodes[0].model"),
      ("数でない出来事の日数", with("retentionDays", "long"), "invalid nodes[0].retentionDays"),
      (
        "ノードが 2 つの形", with("command", "gh api"),
        "invalid nodes[0]: pass either command (a shell command) or instruction (an agent)"
      ),
      (
        "毎回全件の取得の性質", with("coverage", "everything"),
        "invalid nodes[0].coverage: pass currentSet or newArrivals"
      ),
      (
        "知らない取り方", with("from", [["node": "x", "take": "some"]]),
        "invalid nodes[0].from[0].take: pass new or all"
      ),
      ("数でない件数の上限", with("maxItems", "many"), "invalid nodes[0].maxItems"),
      (
        "知らない予定の種類", with("trigger", ["kind": "daily"]),
        "invalid nodes[0].trigger.kind: pass interval, cron, manual or arrival"
      ),
      (
        "cron の欄が範囲外", with("trigger", ["kind": "cron", "expression": "0 24 * * *"]),
        "invalid nodes[0].trigger.expression: invalid hour field: 24"
      ),
      (
        "間隔が文字列", with("trigger", ["kind": "interval", "minutes": "30"]),
        "invalid nodes[0].trigger.minutes"
      ),
      (
        "agent に workspace", with("workspace", UUID().uuidString),
        "invalid nodes[0].workspace: an agent node has no workspace"
      ),
    ] {
      XCTAssertThrowsError(try AutomationDefinition.decode(object), label) {
        XCTAssertEqual($0 as? AutomationError, .invalid(message), label)
      }
    }
  }
}
