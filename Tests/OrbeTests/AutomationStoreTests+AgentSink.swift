import XCTest

@testable import Orbe

/// 出力先の agent の定義。名指しは MCP のツールの完全名と `Bash(<コマンドの接頭>:*)` だけで、取得元も段も任意。書き換えの後も
/// 全件を見直さず、モデルは省略を sonnet と解いて比べる。定義も回の記録も外の口・保存と同じ形で往復する。
///
/// 壊れると何が起きるか: 裸の Bash や Write を名指しした agent が何でもできる。`,` や `*` を混ぜた接頭で、名指しの外のコマンド
/// まで許される。指示を 1 文字直しただけで agent が起き直して二重に投稿する。保存した定義が読めず自動化が消える。
extension AutomationStoreTests {
  private func agentDefinition(
    tools: [String] = ["Bash(gh search prs:*)", "mcp__slack__post"], request: String = "投稿して",
    model: String? = nil, cli: String = "claude"
  ) -> AutomationDefinition {
    var definition = Self.definition()
    definition.source = nil
    definition.steps = []
    definition.sink = .agent(
      AutomationSinkAgent(cli: cli, model: model, tools: tools, request: request))
    return definition
  }

  func testAnAgentSinkTakesOnlyMCPToolNamesAndBashRules() throws {
    let store = try store()
    XCTAssertNoThrow(try store.replace(1, with: agentDefinition()))
    XCTAssertNoThrow(try store.replace(1, with: agentDefinition(tools: ["Bash(git log:*)"])))
    XCTAssertNoThrow(try store.replace(1, with: agentDefinition(tools: ["mcp__slack__post"])))
    var sourced = Self.definition(coverage: .everything)
    sourced.sink = agentDefinition().sink
    XCTAssertNoThrow(try store.replace(1, with: sourced), "取得元も段も持てる")

    let refused = { (tool: String) in
      "sink: \(tool) is neither a full MCP tool name (mcp__<server>__<tool>) nor a Bash rule "
        + "(Bash(<command prefix>:*)); other built-in tools, whole servers and wildcards are refused"
    }
    for tool in [
      "Bash", "Write", "Read", "mcp__slack", "mcp__slack__*", "Bash(*)", "Bash(gh:*", "Bash( :*)",
      "Bash(gh,curl:*)", "Bash(gh*:*)", "Bash(gh (x):*)", "Bash(gh\n:*)", "Bash(gh search prs)",
    ] {
      XCTAssertThrowsError(try store.replace(1, with: agentDefinition(tools: [tool])), tool) {
        XCTAssertEqual($0 as? AutomationError, .invalid(refused(tool)), tool)
      }
    }
    for (label, definition, message) in [
      ("ツールなし", agentDefinition(tools: []), "sink: tools are empty"),
      ("依頼文が空", agentDefinition(request: " \n"), "sink: request is empty"),
      ("モデルが空", agentDefinition(model: " "), "sink: model is empty"),
      ("知らない CLI", agentDefinition(cli: "nope"), "sink: agent nope is not supported"),
    ] {
      XCTAssertThrowsError(try store.replace(1, with: definition), label) {
        XCTAssertEqual($0 as? AutomationError, .invalid(message), label)
      }
    }
  }

  /// 書き換えても見直さない。モデルは省略を sonnet と解いて比べ、依頼文・ツールが変われば走っている回を止める。
  func testEditingAnAgentSinkDoesNotReviewAndComparesTheResolvedModel() throws {
    let store = try store()
    _ = try store.replace(1, with: Self.definition(instruction: "別の指示"))
    XCTAssertTrue(store.automation(1)!.reviewAll)
    XCTAssertTrue(try store.replace(1, with: agentDefinition()).reworked)
    XCTAssertFalse(store.automation(1)!.reviewAll, "agent へ替えたら前からの印も下ろす")

    XCTAssertFalse(try store.replace(1, with: agentDefinition(model: "sonnet")).reworked)
    XCTAssertTrue(try store.replace(1, with: agentDefinition(model: "opus")).reworked)
    XCTAssertTrue(try store.replace(1, with: agentDefinition(request: "別の依頼")).reworked)
    XCTAssertTrue(try store.replace(1, with: agentDefinition(tools: ["mcp__slack__post"])).reworked)
    XCTAssertFalse(store.automation(1)!.reviewAll)
  }

  /// 定義の形は `agent` の省略で claude、モデルは省略のまま往復する。回の記録も種類ごと往復する。
  func testTheAgentSinkAndItsRecordRoundTrip() throws {
    let json =
      #"{"name": "n", "trigger": {"dailyAt": ["09:00"]}, "steps": [], "sink": {"kind": "agent", "#
      + #""tools": ["Bash(gh search prs:*)"], "request": "投稿して"}}"#
    let definition = try AutomationWire.decoder.decode(
      AutomationDefinition.self, from: Data(json.utf8))
    XCTAssertEqual(
      definition.sink,
      .agent(
        AutomationSinkAgent(
          cli: "claude", model: nil, tools: ["Bash(gh search prs:*)"], request: "投稿して")))
    XCTAssertEqual(
      try AutomationWire.decoder.decode(
        AutomationDefinition.self, from: AutomationWire.encoder().encode(definition)),
      definition)

    for report in [
      AutomationAgentReport(commandLine: "claude -p", ending: "exited 0", text: "投稿した"),
      AutomationAgentReport(commandLine: "claude -p", ending: "exited 1", text: nil),
    ] {
      let sink = AutomationSinkReport.agent(report)
      XCTAssertEqual(
        try AutomationWire.decoder.decode(
          AutomationSinkReport.self, from: AutomationWire.encoder().encode(sink)),
        sink)
    }
  }

  /// 保存した自動化の出力先ごとの状態は、agent では中身を持たない。
  func testAnAgentAutomationSurvivesARestart() throws {
    let store = AutomationStore(file: nil)
    let created = try store.create(agentDefinition(), now: t0)
    let data = try AutomationWire.encoder().encode(created)
    XCTAssertFalse(try XCTUnwrap(String(bytes: data, encoding: .utf8)).contains("sinkState"))
    let reread = try AutomationWire.decoder.decode(Automation.self, from: data)
    XCTAssertEqual(reread, created)
    XCTAssertEqual(reread.sinkState, .agent)
  }
}
