import XCTest

@testable import Orbe

/// claude を裏で非対話に回す契約——MCP のツールを指定しなければ利用者の設定も MCP サーバーも読まずに閉じ、指定すれば
/// 利用者の MCP サーバーを使うが、どちらでも指定以外は問わずに拒否し、会話を残さない。最終応答は最後の `result` から取る。
/// codex・agy は回せない理由を持つ。
///
/// 壊れると何が起きるか。外部の文面を読む判定役が、利用者が常に許可したツールや bypassPermissions を引き継いで何でもできる。
/// 裏の実行が /resume の履歴を埋める。MCP のツールを指定した取得役が、利用者の MCP サーバーを読めずに何も取れない。
final class ClaudeHeadlessTests: OrbeTestCase {
  func testBuiltinOnlyCallIsSealedFromUserSettingsAndMCP() {
    XCTAssertEqual(
      ClaudeHeadless.arguments(model: "haiku", tools: ["Read", "Grep"]),
      [
        "-p", "--model", "haiku", "--tools", "Read,Grep", "--allowedTools", "Read,Grep",
        "--permission-mode", "dontAsk", "--no-session-persistence",
        "--output-format", "stream-json", "--verbose", "--setting-sources", "",
        "--strict-mcp-config",
      ])
  }

  func testCallWithoutToolsDisablesAllTools() {
    let args = ClaudeHeadless.arguments(model: "haiku", tools: [])

    XCTAssertEqual(Array(args[3...4]), ["--tools", ""])
    XCTAssertFalse(args.contains("--allowedTools"))
    XCTAssertTrue(args.contains("--strict-mcp-config"))
  }

  /// MCP のツールは利用者の MCP サーバーを名前で使うので、設定を読む。組み込みは指定したものだけ。
  func testMCPToolCallReadsUserSettingsButStillAllowsOnlyTheNamedTools() {
    let args = ClaudeHeadless.arguments(model: "haiku", tools: ["Read", "mcp__slack__search"])

    XCTAssertEqual(
      Array(args[3...6]), ["--tools", "Read", "--allowedTools", "Read,mcp__slack__search"])
    XCTAssertFalse(args.contains("--setting-sources"))
    XCTAssertFalse(args.contains("--strict-mcp-config"))
    XCTAssertTrue(args.contains("dontAsk"))
    XCTAssertTrue(args.contains("--no-session-persistence"))
  }

  func testReplyComesFromTheResultEvent() {
    XCTAssertEqual(
      ClaudeHeadless.reply(Data(#"{"is_error":false,"result":"done","type":"result"}"#.utf8)),
      BackgroundAgentReply(text: "done", isError: false))
    XCTAssertEqual(
      ClaudeHeadless.reply(
        Data(#"{"type":"result","subtype":"error_max_turns","is_error":true}"#.utf8)),
      BackgroundAgentReply(text: "", isError: true))
    XCTAssertNil(ClaudeHeadless.reply(Data(#"{"type":"assistant","result":"x"}"#.utf8)))
    XCTAssertNil(ClaudeHeadless.reply(Data("not json".utf8)))
  }

  func testOnlyClaudeRunsHeadless() {
    guard case .runs = AgentCatalog.profile("claude")?.headless else {
      return XCTFail("claude は裏で回せる")
    }
    guard case .refuses(.toolsNotAllowListable) = AgentCatalog.profile("codex")?.headless else {
      return XCTFail("codex は組み込みツールを許可で列挙できない")
    }
    guard case .refuses(.noToolOrSessionControl) = AgentCatalog.profile("agy")?.headless else {
      return XCTFail("agy はツールの指定も会話を残さない指定も無い")
    }
  }
}
