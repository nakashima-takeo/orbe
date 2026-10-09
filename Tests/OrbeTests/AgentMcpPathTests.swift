import Foundation
import XCTest

@testable import Orbe

/// プラグインの MCP 定義からの実経路を継ぎ目ごと 1 本で通す——タブへ注入された env の**実値**で
/// 同梱の MCP シムを実 `/bin/sh` から起こし、シムが exec した実 `orbe-mcp` が実 `ControlServer` へ
/// つながり、呼び出し元のタブとして扱われるまで。
///
/// サーバーは codex の MCP 定義（`.codex-plugin/plugin.json`）どおりに起こす。codex は MCP サーバーへ
/// 親の環境を渡さず、定義が名指しした変数だけを通す——3 CLI で最も狭いので、これで足りれば他の CLI でも足りる。
///
/// 区間ごとの検証は別に在る（シムのチャネル判定と空サーバーは `AgentMcpShimTests`、ブリッジが
/// `ORBE_TAB` を呼び出し元に添えることは `OrbeMcpTaskProcessTests`）。
///
/// 壊れると何が起きるか: Orbe のタブの agent に Orbe のツールが 1 つも出ない、または別の workspace に
/// タスクを足す。しかもエラーにならない——シムは選べなければ空サーバーとして正常に応答する。
final class AgentMcpPathTests: OrbeTestCase {
  /// codex の MCP 定義のうち、起こし方を決める 3 つ。
  private struct CodexServer {
    let command: String
    let cwd: String
    let envVars: [String]
  }

  private func codexServer(in pluginRoot: URL) throws -> CodexServer {
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: pluginRoot.appendingPathComponent(".codex-plugin/plugin.json")))
        as? [String: Any])
    let servers = try XCTUnwrap(manifest["mcpServers"] as? [String: [String: Any]])
    let server = try XCTUnwrap(servers[pluginRoot.lastPathComponent], "サーバー名＝プラグイン名")
    return CodexServer(
      command: try XCTUnwrap(server["command"] as? String),
      cwd: server["cwd"] as? String ?? ".",
      envVars: server["env_vars"] as? [String] ?? [])
  }

  private func runServer(
    _ server: CodexServer, in pluginRoot: URL, env: [String: String], requests: [[String: Any]],
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> [[String: Any]] {
    let lines = try requests.map {
      try XCTUnwrap(String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8))
    }
    let outcome = ControlProcess.run(
      URL(fileURLWithPath: "/bin/sh"), [server.command], env: env,
      stdin: lines.joined(separator: "\n") + "\n",
      cwd: pluginRoot.appendingPathComponent(server.cwd).path, file: file, line: line)
    return outcome.stdout.split(separator: "\n").compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }

  /// 注入 env（codex が通す分だけ）→ MCP シム → 同梱 `orbe-mcp` → control、で add_task が呼んだタブの
  /// workspace に付く。
  func testCodexDeclarationConnectsBridgeAsTheCallingTab() throws {
    let control = try startControlProcess()
    let pluginRoot = try ControlProcess.stagePlugin()
    let server = try codexServer(in: pluginRoot)
    let tab = try XCTUnwrap(control.target.workspaces.first { $0.name == "background" }?.tabs.first)
    var injected: [String: String] = [:]
    OrbeRuntimeEnv.inject(into: &injected, tabId: tab.id)

    XCTAssertEqual(
      injected["ORBE_MCP_BIN"], BundledResources.root?.appendingPathComponent("bin/orbe-mcp").path,
      "同梱 orbe-mcp の絶対パスが注入される")

    var env = injected.filter { server.envVars.contains($0.key) }
    env["PATH"] = "/usr/bin:/bin"  // codex が既定で通す変数の 1 つ
    let responses = try runServer(
      server, in: pluginRoot, env: env,
      requests: [
        ["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
        [
          "jsonrpc": "2.0", "id": 2, "method": "tools/call",
          "params": ["name": "add_task", "arguments": ["title": "タブから"]],
        ],
      ])

    let tools = (responses.first { $0["id"] as? Int == 1 }?["result"] as? [String: Any])?["tools"]
    XCTAssertFalse((tools as? [Any] ?? []).isEmpty, "Orbe のツールが並ぶ（空サーバーに落ちていない）")
    let call = responses.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any]
    let text = try XCTUnwrap(
      (call?["content"] as? [[String: Any]])?.first?["text"] as? String, "\(responses)")
    let task =
      (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["task"]
      as? [String: Any]
    XCTAssertEqual(task?["workspaceName"] as? String, "background", "呼んだタブの workspace に付く: \(text)")
  }
}
