import XCTest

@testable import Orbe

/// 部品の JSON の形——外から受けた定義の読み書き。
///
/// 壊れると何が起きるか: AI が書いた部品が別の意味で読まれる（`none` が報告に化ける・入力や取り方が落ちる・部品の id が
/// 落ちて別の部品になる）。読み直した部品のモデルが解いた値で固まり、役割が変わっても前の既定で走る。コマンドに書いたツールや
/// 知らない行き先・取り方が黙って捨てられ、書いた AI が誤りの場所を知らされない。
final class AutomationNodeTests: OrbeTestCase {
  private func definitionNode(
    _ id: Int?, _ key: String, _ name: String, _ trigger: AutomationNode.Trigger,
    from: [AutomationDefinition.Input] = [], _ action: AutomationActionDef, maxItems: Int? = nil
  ) -> AutomationDefinition.Node {
    AutomationDefinition.Node(
      id: id.map(AutomationNodeID.init), key: key, name: name, trigger: trigger, from: from,
      action: action, maxItems: maxItems)
  }

  func testTheJSONFormReadsIntoNodesAndWritesBackTheSame() throws {
    let json = #"""
      [
        {"id": 3, "key": "gh", "name": "GitHub", "trigger": {"kind": "interval", "minutes": 10},
         "command": "gh search prs", "directory": "/Users/me/repo", "coverage": "currentSet"},
        {"key": "judge", "name": "判定", "trigger": {"kind": "cron", "expression": "0 9 * * *"},
         "from": [{"node": "gh", "maxAgeHours": 72}], "instruction": "判定して",
         "deliver": "taskCandidates", "maxItems": 30, "timeoutMinutes": 10},
        {"key": "post", "name": "投稿", "trigger": {"kind": "manual"}, "agent": "claude",
         "model": "opus", "tools": ["mcp__slack__post"], "instruction": "投稿して", "deliver": "report"},
        {"key": "say", "name": "知らせ", "trigger": {"kind": "arrival"},
         "from": ["gh", {"node": "post", "take": "all"}], "command": "say hi", "deliver": "none"},
        {"key": "sum", "name": "まとめ", "trigger": {"kind": "arrival"},
         "from": [{"node": "gh", "take": "all"}], "instruction": "まとめて", "coverage": "currentSet"}
      ]
      """#
    let expected = [
      definitionNode(
        3, "gh", "GitHub", .scheduled(.every(600)),
        AutomationActionDef(
          method: .command(BackgroundCommand(script: "gh search prs", directory: "/Users/me/repo")),
          timeoutMinutes: nil, coverage: .currentSet, destination: .nextNode)),
      definitionNode(
        nil, "judge", "判定", .scheduled(.cron(try BackgroundCron("0 9 * * *"))),
        from: [.init(nodeKey: "gh", maxAgeHours: 72)],
        AutomationActionDef(
          method: .agent(
            AutomationNodeAgent(cli: "claude", model: nil, tools: [], instruction: "判定して")),
          timeoutMinutes: 10, coverage: nil, destination: .taskCandidates), maxItems: 30),
      definitionNode(
        nil, "post", "投稿", .manual,
        AutomationActionDef(
          method: .agent(
            AutomationNodeAgent(
              cli: "claude", model: "opus", tools: ["mcp__slack__post"], instruction: "投稿して")),
          timeoutMinutes: nil, coverage: nil, destination: .report)),
      definitionNode(
        nil, "say", "知らせ", .arrival,
        from: [.init(nodeKey: "gh"), .init(nodeKey: "post", take: .all)],
        AutomationActionDef(
          method: .command(BackgroundCommand(script: "say hi", directory: nil)),
          timeoutMinutes: nil, coverage: nil, destination: .sideEffect)),
      definitionNode(
        nil, "sum", "まとめ", .arrival, from: [.init(nodeKey: "gh", take: .all)],
        AutomationActionDef(
          method: .agent(
            AutomationNodeAgent(cli: "claude", model: nil, tools: [], instruction: "まとめて")),
          timeoutMinutes: nil, coverage: .currentSet, destination: .nextNode)),
    ]

    let definitionNodes = try AutomationWire.decoder.decode(
      [AutomationDefinition.Node].self, from: Data(json.utf8))
    let written = try AutomationWire.encoder().encode(definitionNodes)
    let from = try XCTUnwrap(
      (JSONSerialization.jsonObject(with: written) as? [[String: Any]])?[3]["from"] as? [Any])

    XCTAssertEqual(definitionNodes, expected)
    XCTAssertEqual(
      try AutomationWire.decoder.decode([AutomationDefinition.Node].self, from: written),
      definitionNodes, "書いて読み直しても同じ値（省略したモデルは省略のまま）")
    XCTAssertEqual(from.first as? String, "gh", "取り方も古さの上限も省いた入力は鍵だけで書く")
  }

  /// 形の誤りは読む時点で断り、誤りの場所（部品の位置と欄）を持つ。制御 API はこの場所を `nodes[1].tools` の形で返す。
  func testShapeErrorsAreRefusedAtTheirPlace() {
    let manual = #"{"kind": "manual"}"#
    for (label, trigger, fields, place) in [
      ("コマンドと指示文の両方", manual, #""command": "x", "instruction": "y""#, "[1]"),
      ("手段が無い", manual, #""coverage": "currentSet""#, "[1]"),
      ("コマンドにツール", manual, #""command": "x", "tools": ["mcp__a__b"]"#, "[1].tools"),
      ("コマンドにモデル", manual, #""command": "x", "model": "haiku""#, "[1].model"),
      ("agent に作業ディレクトリ", manual, #""instruction": "y", "directory": "/a""#, "[1].directory"),
      ("知らない予定", #"{"kind": "weekly"}"#, #""command": "x""#, "[1].trigger.kind"),
      (
        "cron 式の誤り", #"{"kind": "cron", "expression": "0 25 * * *"}"#, #""command": "x""#,
        "[1].trigger.expression"
      ),
      ("毎回全件の性質", manual, #""command": "x", "coverage": "everything""#, "[1].coverage"),
      (
        "知らない取り方", manual, #""command": "x", "from": [{"node": "ok", "take": "x"}]"#,
        "[1].from[0].take"
      ),
      (
        "数でない件数の上限", manual, #""command": "x", "maxItems": "many""#, "[1].maxItems"
      ),
      ("知らない行き先", manual, #""command": "x", "deliver": "slack""#, "[1].deliver"),
    ] {
      let json =
        #"[{"key": "ok", "name": "ok", "trigger": {"kind": "manual"}, "command": "x"}, "#
        + #"{"key": "a", "name": "a", "trigger": \#(trigger), \#(fields)}]"#
      XCTAssertThrowsError(
        try AutomationWire.decoder.decode([AutomationDefinition.Node].self, from: Data(json.utf8)),
        label
      ) {
        XCTAssertEqual(location(of: $0), place, label)
      }
    }
  }

  /// 読む誤りの場所（`[1].trigger.kind` の形）。
  private func location(of error: Error) -> String? {
    let keys: [CodingKey]
    switch error as? DecodingError {
    case .dataCorrupted(let context)?, .typeMismatch(_, let context)?,
      .valueNotFound(_, let context)?:
      keys = context.codingPath
    case .keyNotFound(let key, let context)?: keys = context.codingPath + [key]
    default: return nil
    }
    return keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
  }
}
