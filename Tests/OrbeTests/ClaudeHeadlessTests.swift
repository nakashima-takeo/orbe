import XCTest

@testable import Orbe

/// claude を裏で非対話に回す契約——MCP のツールを指定しなければ利用者の設定も MCP サーバーも読まずに閉じ、指定すれば
/// 利用者の MCP サーバーを使うが、どちらでも指定以外は問わずに拒否し、会話を残さない。最終応答は最後の `result` から取る。
///
/// 壊れると何が起きるか。外部の文面を読む判定役が、利用者が常に許可したツールや bypassPermissions を引き継いで何でもできる。
/// 行を読むだけの agent が、Orbe の口のほかに利用者の設定や MCP サーバーまで使える。
/// 裏の実行が /resume の履歴を埋める。MCP のツールを指定した取得役が、利用者の MCP サーバーを読めずに何も取れない。
final class ClaudeHeadlessTests: OrbeTestCase {
  func testBuiltinOnlyCallIsSealedFromUserSettingsAndMCP() {
    XCTAssertEqual(
      ClaudeHeadless.arguments(model: "haiku", tools: ["Read", "Grep"], server: nil),
      [
        "-p", "--model", "haiku", "--tools", "Read,Grep", "--allowedTools", "Read,Grep",
        "--permission-mode", "dontAsk", "--no-session-persistence",
        "--output-format", "stream-json", "--verbose", "--setting-sources", "",
        "--strict-mcp-config",
      ])
  }

  func testCallWithoutToolsDisablesAllTools() {
    let args = ClaudeHeadless.arguments(model: "haiku", tools: [], server: nil)

    XCTAssertEqual(Array(args[3...4]), ["--tools", ""])
    XCTAssertFalse(args.contains("--allowedTools"))
    XCTAssertTrue(args.contains("--strict-mcp-config"))
  }

  /// Orbe の口のサーバーは `--mcp-config` で足し、そのツールだけを許すものに足す。サーバーの環境は `${名前}` の参照で書く。利用者の MCP のツールが無ければ、利用者の
  /// 設定も MCP サーバーも読まない閉じた形のまま。
  func testOrbeServerIsAddedWithOnlyItsTools() throws {
    let server = HeadlessServer(
      name: "orbe_run", command: "/A/orbe-mcp", environment: ["ORBE_RUN_TOKEN": "t"],
      tools: ["mcp__orbe_run__read_run_rows"])
    let args = ClaudeHeadless.arguments(model: "haiku", tools: [], server: server)

    XCTAssertEqual(
      Array(args[3...6]), ["--tools", "", "--allowedTools", "mcp__orbe_run__read_run_rows"])
    let config = try XCTUnwrap(args.firstIndex(of: "--mcp-config")).advanced(by: 1)
    XCTAssertEqual(
      args[config],
      #"{"mcpServers":{"orbe_run":{"args":[],"command":"/A/orbe-mcp","#
        + #""env":{"ORBE_RUN_TOKEN":"${ORBE_RUN_TOKEN}"},"type":"stdio"}}}"#,
      "環境は参照だけで、値（回の札）はコマンド行に出さない")
    XCTAssertFalse(args.contains { $0.contains(#""t""#) })
    XCTAssertTrue(args.contains("--strict-mcp-config"))
    XCTAssertEqual(Array(args.suffix(3)), ["--setting-sources", "", "--strict-mcp-config"])
  }

  /// MCP のツールは利用者の MCP サーバーを名前で使うので、設定を読む。組み込みは指定したものだけ。
  func testMCPToolCallReadsUserSettingsButStillAllowsOnlyTheNamedTools() {
    let args = ClaudeHeadless.arguments(
      model: "haiku", tools: ["Read", "mcp__slack__search"], server: nil)

    XCTAssertEqual(
      Array(args[3...6]), ["--tools", "Read", "--allowedTools", "Read,mcp__slack__search"])
    XCTAssertFalse(args.contains("--setting-sources"))
    XCTAssertFalse(args.contains("--strict-mcp-config"))
    XCTAssertTrue(args.contains("dontAsk"))
    XCTAssertTrue(args.contains("--no-session-persistence"))
  }

  /// `Bash(<接頭>:*)` の規則は、ツール名だけを `--tools` に（重ねず）、規則そのものを `--allowedTools` に渡す——Bash を持たせて
  /// 名指しの接頭のコマンドだけを許す。MCP を含まなければ閉じたまま。
  func testBashRulesGiveBashButAllowOnlyTheNamedPrefixes() {
    XCTAssertEqual(
      ClaudeHeadless.arguments(
        model: "sonnet", tools: ["Bash(gh search prs:*)", "Bash(date -u:*)"], server: nil),
      [
        "-p", "--model", "sonnet", "--tools", "Bash", "--allowedTools",
        "Bash(gh search prs:*),Bash(date -u:*)", "--permission-mode", "dontAsk",
        "--no-session-persistence", "--output-format", "stream-json", "--verbose",
        "--setting-sources", "", "--strict-mcp-config",
      ])

    let mixed = ClaudeHeadless.arguments(
      model: "sonnet", tools: ["Bash(gh search prs:*)", "mcp__slack__post"], server: nil)
    XCTAssertEqual(
      Array(mixed[3...6]),
      ["--tools", "Bash", "--allowedTools", "Bash(gh search prs:*),mcp__slack__post"])
    XCTAssertFalse(mixed.contains("--strict-mcp-config"), "MCP を混ぜると利用者の MCP サーバーを読む")
  }

  /// 利用者の CLAUDE.md と auto memory は、設定を読む呼び出しでも混ぜない（外部の文面を判定する役の判断が揺れる）。
  func testUserMemoryIsNeverLoaded() {
    XCTAssertEqual(
      ClaudeHeadless.environment(tools: ["Read"]),
      ["CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"])
  }

  /// MCP のツールを指定した呼び出しだけ、MCP サーバーの接続を待ってから始める（起動に数秒かかるサーバーのツールを失わない）。
  /// 待ちは無出力の上限より短い（待っている間に無出力で打ち切られない）。
  func testMCPToolCallWaitsForServersWithinTheIdleLimit() throws {
    let env = ClaudeHeadless.environment(tools: ["mcp__slack__search"])

    XCTAssertEqual(env["CLAUDE_CODE_MCP_STARTUP_WAIT_MS"], "60000")
    XCTAssertEqual(env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"], "1")
    XCTAssertLessThan(ClaudeHeadless.mcpStartupWait, try XCTUnwrap(BackgroundLimits.agent.idle))
  }

  func testAvailableToolsComeFromTheInitEvent() {
    XCTAssertEqual(
      ClaudeHeadless.availableTools(
        Data(#"{"type":"system","subtype":"init","tools":["Read","mcp__slack__search"]}"#.utf8)),
      ["Read", "mcp__slack__search"])
    XCTAssertNil(
      ClaudeHeadless.availableTools(Data(#"{"type":"system","subtype":"status"}"#.utf8)))
    XCTAssertNil(ClaudeHeadless.availableTools(Data(#"{"type":"result","result":"x"}"#.utf8)))
  }

  /// 揃っているかを見るのは MCP のツールだけ。
  func testMissingToolsAreTheRequestedMCPToolsNotInTheSession() {
    XCTAssertEqual(
      HeadlessCLI.missingTools(
        ["Read", "mcp__slack__search", "mcp__linear__issues"],
        available: ["mcp__slack__search", "mcp__github__issues"]),
      ["mcp__linear__issues"])
  }

  func testReplyComesFromTheResultEvent() {
    XCTAssertEqual(
      ClaudeHeadless.reply(Data(#"{"is_error":false,"result":"done","type":"result"}"#.utf8)),
      BackgroundAgentReply(text: "done", isError: false))
    XCTAssertEqual(
      ClaudeHeadless.reply(
        Data(
          #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["a","b"]}"#
            .utf8)),
      BackgroundAgentReply(text: "a\nb", isError: true), "失敗の回は errors を理由として返す")
    XCTAssertNil(ClaudeHeadless.reply(Data(#"{"type":"assistant","result":"x"}"#.utf8)))
    XCTAssertNil(ClaudeHeadless.reply(Data("not json".utf8)))
  }
}
