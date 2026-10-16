import OrbeTestSupport
import XCTest

@testable import Orbe

/// MCP シム（`app/agent-plugin/.../mcp/orbe-mcp.sh`）と空サーバー（`mcp/empty-server.pl`）を実 `/bin/sh`・
/// 実 perl で機械検証する。プラグインは本番の実体化に通す（チャネルの刻印は実体化が書いたもの）。
/// CLI は有効なプラグインの MCP サーバーを全セッションで起こすので、シムは自分のチャネルの Orbe のタブでだけタブの `orbe-mcp` へつなぎ、それ以外ではツール 0 個のサーバーとして
/// 正常に応答する。チャネルの規則は状態追跡のシム（`AgentShimChannelGateTests`）と同じ。シムは claude と agy の
/// MCP 定義から起こし方を取る（codex の定義は `AgentMcpPathTests` が通す）。
///
/// 壊れると何が起きるか: dev のタブの agent が release の Orbe を操作する（その逆も）。あるいは Orbe の外の
/// claude / codex が毎セッション接続失敗を警告する。
final class AgentMcpShimTests: OrbeTestCase {
  private static let delegatedMarker = "delegated"
  /// 実体化が刻むのとは別のチャネル。
  private static let otherChannel = "dev.orbe.app.other"

  private var work: URL!
  private var pluginRoot: URL!
  private var mcpBin: URL!  // stdin を記録し、目印の 1 行を返す fake orbe-mcp
  private var mcpLog: URL!

  override func setUpWithError() throws {
    work = TestScratch.caseDir.appendingPathComponent("AgentMcpShimTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    pluginRoot = try ControlProcess.stagePlugin()
    mcpLog = work.appendingPathComponent("mcp.log")
    mcpBin = work.appendingPathComponent("orbe-mcp")
    let script = """
      #!/bin/sh
      cat > "\(mcpLog.path)"
      echo \(Self.delegatedMarker)
      """
    try Data(script.utf8).write(to: mcpBin)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcpBin.path)
  }

  /// シムを起こす MCP 定義。
  private enum Definition: CaseIterable {
    /// プラグインルート変数を展開した絶対パスで呼ぶ。プラグインの外から起こし、`$0` 相対の解決を突く。
    case claude
    /// cwd＝ステージ済みプラグインルートからの相対で呼ぶ。
    case agy
  }

  /// 定義ファイルから、サーバー名＝プラグイン名のサーバーの起こし方（コマンドと cwd）を取る。
  private func launch(_ definition: Definition) throws -> (command: String, cwd: String) {
    let file = definition == .claude ? ".claude-plugin/plugin.json" : "mcp_config.json"
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: pluginRoot.appendingPathComponent(file)))
        as? [String: Any])
    let servers = try XCTUnwrap(manifest["mcpServers"] as? [String: [String: Any]], file)
    let command = try XCTUnwrap(
      servers[pluginRoot.lastPathComponent]?["command"] as? String, "\(file): サーバー名＝プラグイン名")
    switch definition {
    case .claude:
      return (
        command.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginRoot.path), work.path
      )
    case .agy:
      return (command, pluginRoot.path)
    }
  }

  /// シムを定義どおりに実 `/bin/sh` で起こし、stdout の行を返す。
  private func runShim(
    _ definition: Definition, bundleId: String?, withMcpBin: Bool = true, stdin: [String]
  ) throws -> [String] {
    var env = ["PATH": "/usr/bin:/bin"]
    if withMcpBin { env["ORBE_MCP_BIN"] = mcpBin.path }
    if let bundleId { env["ORBE_BUNDLE_ID"] = bundleId }
    let (command, cwd) = try launch(definition)
    let outcome = ControlProcess.run(
      URL(fileURLWithPath: "/bin/sh"), [command], env: env,
      stdin: stdin.joined(separator: "\n") + "\n", cwd: cwd)
    XCTAssertEqual(outcome.status, 0, "\(definition): \(outcome.stderr)")
    return outcome.stdout.split(separator: "\n").map(String.init)
  }

  private let toolsList = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#

  private func assertDelegated(_ out: [String], file: StaticString = #filePath, line: UInt = #line)
  {
    XCTAssertEqual(out, [Self.delegatedMarker], file: file, line: line)
    XCTAssertEqual(
      try? String(contentsOf: mcpLog, encoding: .utf8), toolsList + "\n", "stdin がそのまま渡る",
      file: file, line: line)
  }

  private func assertEmptyServer(
    _ out: [String], file: StaticString = #filePath, line: UInt = #line
  ) {
    let reply = out.count == 1 ? try? JSONSerialization.jsonObject(with: Data(out[0].utf8)) : nil
    let result = (reply as? [String: Any])?["result"] as? [String: Any]
    XCTAssertEqual((reply as? [String: Any])?["id"] as? Int, 1, "\(out)", file: file, line: line)
    XCTAssertEqual((result?["tools"] as? [Any])?.isEmpty, true, "\(out)", file: file, line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: mcpLog.path), "orbe-mcp は起こさない", file: file, line: line
    )
  }

  func testMatchingChannelExecsTheTabsBridge() throws {
    for definition in Definition.allCases {
      try? FileManager.default.removeItem(at: mcpLog)
      assertDelegated(try runShim(definition, bundleId: StateDir.bundleId, stdin: [toolsList]))
    }
  }

  /// 別チャネルの Orbe のタブでは、そのタブの Orbe につながない。
  func testMismatchedChannelIsEmptyServer() throws {
    for definition in Definition.allCases {
      assertEmptyServer(try runShim(definition, bundleId: Self.otherChannel, stdin: [toolsList]))
    }
  }

  /// Orbe の外（`ORBE_MCP_BIN` 無し）。
  func testOutsideOrbeIsEmptyServer() throws {
    for definition in Definition.allCases {
      assertEmptyServer(
        try runShim(definition, bundleId: nil, withMcpBin: false, stdin: [toolsList]))
    }
  }

  /// 空サーバーは MCP の握手に応え、ツールを名乗らない。id の型を保ち、通知と読めない行には応えない。
  func testEmptyServerAnswersHandshakeWithoutTools() throws {
    let out = try runShim(
      .claude, bundleId: nil, withMcpBin: false,
      stdin: [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        "not json",
        #"{"jsonrpc":"2.0","id":"s","method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_tasks"}}"#,
      ])
    let replies = out.compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    XCTAssertEqual(replies.count, 4, "\(out)")
    guard replies.count == 4 else { return }

    let initialize = replies[0]["result"] as? [String: Any]
    XCTAssertEqual(initialize?["protocolVersion"] as? String, "2025-03-26", "要求の版をそのまま返す")
    XCTAssertEqual((initialize?["capabilities"] as? [String: Any])?.isEmpty, true, "tools を名乗らない")
    XCTAssertEqual(replies[1]["id"] as? String, "s")
    XCTAssertEqual(((replies[1]["result"] as? [String: Any])?["tools"] as? [Any])?.isEmpty, true)
    XCTAssertEqual(replies[2]["id"] as? Int, 3)
    XCTAssertNotNil(replies[2]["result"])
    XCTAssertEqual((replies[3]["error"] as? [String: Any])?["code"] as? Int, -32601)
  }
}
