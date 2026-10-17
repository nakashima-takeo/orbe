import XCTest

@testable import Orbe

/// 部品の JSON の形——外から受けた定義と保存の読み書き。
///
/// 壊れると何が起きるか: AI が書いた部品が別の意味で読まれる（`none` が報告に化ける・入力が落ちる）。保存して読み直した部品の
/// モデルが解いた値で固まり、役割が変わっても前の既定で走る。コマンドに書いたツールや知らない行き先が黙って捨てられ、書いた
/// AI が誤りの場所を知らされない。
final class AutomationPartTests: OrbeTestCase {
  func testTheJSONFormReadsIntoPartsAndWritesBackTheSame() throws {
    let json = #"""
      [
        {"key": "gh", "name": "GitHub", "trigger": {"kind": "interval", "minutes": 10},
         "command": "gh search prs", "directory": "/Users/me/repo", "coverage": "currentSet"},
        {"key": "judge", "name": "判定", "trigger": {"kind": "cron", "expression": "0 9 * * *"},
         "from": ["gh"], "instruction": "判定して", "deliver": "taskCandidates",
         "inboxLimit": {"maxAgeHours": 72}, "timeoutMinutes": 10},
        {"key": "post", "name": "投稿", "trigger": {"kind": "manual"}, "agent": "claude",
         "model": "opus", "tools": ["mcp__slack__post"], "instruction": "投稿して", "deliver": "report"},
        {"key": "say", "name": "知らせ", "trigger": {"kind": "arrival"}, "from": ["gh"],
         "command": "say hi", "deliver": "none"}
      ]
      """#
    let expected = [
      AutomationPart(
        key: "gh", name: "GitHub", trigger: .scheduled(.every(600)), inputs: [],
        method: .command(BackgroundCommand(script: "gh search prs", directory: "/Users/me/repo")),
        timeoutMinutes: nil, coverage: .currentSet, destination: .nextPart, inboxLimit: nil),
      AutomationPart(
        key: "judge", name: "判定", trigger: .scheduled(.cron(try BackgroundCron("0 9 * * *"))),
        inputs: ["gh"],
        method: .agent(
          AutomationPartAgent(cli: "claude", model: nil, tools: [], instruction: "判定して")),
        timeoutMinutes: 10, coverage: nil, destination: .taskCandidates,
        inboxLimit: .init(maxAgeHours: 72, maxItems: nil)),
      AutomationPart(
        key: "post", name: "投稿", trigger: .manual, inputs: [],
        method: .agent(
          AutomationPartAgent(
            cli: "claude", model: "opus", tools: ["mcp__slack__post"], instruction: "投稿して")),
        timeoutMinutes: nil, coverage: nil, destination: .report, inboxLimit: nil),
      AutomationPart(
        key: "say", name: "知らせ", trigger: .arrival, inputs: ["gh"],
        method: .command(BackgroundCommand(script: "say hi", directory: nil)),
        timeoutMinutes: nil, coverage: nil, destination: .sideEffect, inboxLimit: nil),
    ]

    let parts = try AutomationWire.decoder.decode([AutomationPart].self, from: Data(json.utf8))

    XCTAssertEqual(parts, expected)
    XCTAssertEqual(
      try AutomationWire.decoder.decode(
        [AutomationPart].self, from: AutomationWire.encoder().encode(parts)),
      parts, "書いて読み直しても同じ値（省略したモデルは省略のまま）")
  }

  /// 形の誤りは読む時点で断り、誤りの場所（部品の位置と欄）を持つ。制御 API はこの場所を `parts[1].tools` の形で返す。
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
      ("知らない取得の性質", manual, #""command": "x", "coverage": "all""#, "[1].coverage"),
      ("知らない行き先", manual, #""command": "x", "deliver": "slack""#, "[1].deliver"),
    ] {
      let json =
        #"[{"key": "ok", "name": "ok", "trigger": {"kind": "manual"}, "command": "x"}, "#
        + #"{"key": "a", "name": "a", "trigger": \#(trigger), \#(fields)}]"#
      XCTAssertThrowsError(
        try AutomationWire.decoder.decode([AutomationPart].self, from: Data(json.utf8)), label
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
