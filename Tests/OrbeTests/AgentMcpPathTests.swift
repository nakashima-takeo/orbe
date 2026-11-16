import Foundation
import OrbeTestSupport
import XCTest

@testable import Orbe

/// プラグインの MCP 定義からの実経路を継ぎ目ごと 1 本で通す——タブへ注入された env の**実値**で
/// 同梱の MCP シムを実 `/bin/sh` から起動し、シムが exec した実 `orbe-mcp` が実 `ControlServer` へ
/// つながり、呼び出し元のタブとして扱われるまで。
///
/// サーバーは codex の MCP 定義（`.codex-plugin/plugin.json`）どおりに起動する。codex は MCP サーバーへ
/// 親の環境のうち既定の数個（`HOME`・`PATH` など）と定義が名指しした変数しか渡さない——3 CLI で最も狭いので、
/// これで足りれば他の CLI でも足りる。codex はサーバーを会話を動かしているプロセスの直接の子として起動するので、
/// デーモンを使わない codex はタブの端末の中から、デーモン経由の codex は端末を持たない親から起動する。
///
/// 区間ごとの検証は別に在る（シムのチャネル判定と空サーバーは `AgentMcpShimTests`、ブリッジが
/// `ORBE_TAB` を呼び出し元に添えることは `OrbeMcpTaskProcessTests`）。
///
/// 壊れると何が起きるか: Orbe のタブの agent に Orbe のツールが 1 つも出ない、または別の workspace に
/// タスクを足す。しかもエラーにならない——シムは選べなければ空サーバーとして正常に応答する。
final class AgentMcpPathTests: OrbeTestCase {
  /// codex の MCP 定義のうち、起動方法を決める 4 つ。
  private struct CodexServer {
    let command: String
    let args: [String]
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
      args: server["args"] as? [String] ?? [],
      cwd: server["cwd"] as? String ?? ".",
      envVars: server["env_vars"] as? [String] ?? [])
  }

  private func requestLines(_ requests: [[String: Any]]) throws -> String {
    try requests.map {
      try XCTUnwrap(String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8))
    }.joined(separator: "\n") + "\n"
  }

  private func responses(_ stdout: String) -> [[String: Any]] {
    stdout.split(separator: "\n").compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }

  private func tools(_ responses: [[String: Any]], id: Int) -> [Any]? {
    (responses.first { $0["id"] as? Int == id }?["result"] as? [String: Any])?["tools"] as? [Any]
  }

  private let toolsList: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
  private let addTask: [String: Any] = [
    "jsonrpc": "2.0", "id": 2, "method": "tools/call",
    "params": ["name": "add_task", "arguments": ["title": "タブから"]],
  ]

  /// タブの端末で動く codex が起動したのと同じ形——タブの中のシェルの子として、タブの env のうち codex が通す分だけで——
  /// 注入 env → MCP シム → 同梱 `orbe-mcp` → control の経路で、add_task が呼んだタブの workspace に付く。
  func testCodexDeclarationConnectsBridgeAsTheCallingTab() throws {
    let control = try startControlProcess()
    let pluginRoot = try ControlProcess.stagePlugin()
    let server = try codexServer(in: pluginRoot)
    let background = try XCTUnwrap(control.target.workspaces.first { $0.name == "background" })
    let requests = TestScratch.caseDir.appendingPathComponent("requests")
    let out = TestScratch.caseDir.appendingPathComponent("responses")
    try Data(try requestLines([toolsList, addTask]).utf8).write(to: requests)
    // codex が既定で通す変数のうち PATH だけを置き、名指しされた変数はタブの env の実値を渡す。
    let passed = ["PATH=/usr/bin:/bin"] + server.envVars.map { "\($0)=\"$\($0)\"" }
    // サーバーは新しいセッションで起動し、端末を持つのは親（タブのシェル）だけにする。`orbe-mcp` が応答するかを
    // 決めるのは、親が端末を持つかどうか。
    let launch = ControlProcess.shellCommandInNewSession(["/bin/sh", server.command] + server.args)
    let script = TestScratch.caseDir.appendingPathComponent("codex-mcp.sh")
    try Data(
      """
      cd \(ShellWord.quoted(pluginRoot.appendingPathComponent(server.cwd).path))
      /usr/bin/env -i \(passed.joined(separator: " ")) \(launch) \
        < \(ShellWord.quoted(requests.path)) > \(ShellWord.quoted(out.path)).part
      mv \(ShellWord.quoted(out.path)).part \(ShellWord.quoted(out.path))
      exec /bin/sleep 600
      """.utf8
    ).write(to: script)
    let tabId = try XCTUnwrap(
      control.target.controlSpawn(
        workspaceId: background.id, cwd: nil, command: "/bin/sh \(ShellWord.quoted(script.path))",
        selects: false))
    var injected: [String: String] = [:]
    OrbeRuntimeEnv.inject(into: &injected, tabId: tabId)
    XCTAssertEqual(
      injected["ORBE_MCP_BIN"], BundledResources.root?.appendingPathComponent("bin/orbe-mcp").path,
      "同梱 orbe-mcp の絶対パスが注入される")
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        FileManager.default.fileExists(atPath: out.path)
      }, "タブの中で起動したサーバーが終わらない")
    let replies = responses((try? String(contentsOf: out, encoding: .utf8)) ?? "")

    XCTAssertFalse((tools(replies, id: 1) ?? []).isEmpty, "Orbe のツールが並ぶ（空サーバーに落ちていない）")
    let call = replies.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any]
    let text = try XCTUnwrap(
      (call?["content"] as? [[String: Any]])?.first?["text"] as? String, "\(replies)")
    let task =
      (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["task"]
      as? [String: Any]
    XCTAssertEqual(task?["workspaceName"] as? String, "background", "呼んだタブの workspace に付く: \(text)")
  }

  /// 端末から切り離されたプロセス（デーモン経由の codex）が codex の定義どおりに起動したサーバーは、タブの env を
  /// 受け継いでいてもツールを出さず、呼ばれてもエラーを返す。同じ親・同じ env でも CLI 名を渡さない定義（claude・agy）なら
  /// ツールが並ぶ——判定は codex だけに掛かる。
  func testCodexDeclarationFromADetachedProcessServesNoTools() throws {
    let control = try startControlProcess()
    let pluginRoot = try ControlProcess.stagePlugin()
    let server = try codexServer(in: pluginRoot)
    let tab = try XCTUnwrap(control.target.workspaces.first { $0.name == "background" }?.tabs.first)
    var injected: [String: String] = [:]
    OrbeRuntimeEnv.inject(into: &injected, tabId: tab.id)
    var env = injected.filter { server.envVars.contains($0.key) }
    env["PATH"] = "/usr/bin:/bin"
    let stdin = try requestLines([toolsList, addTask])
    func runDetached(_ args: [String]) -> [[String: Any]] {
      responses(
        ControlProcess.runDetached(
          URL(fileURLWithPath: "/bin/sh"), [server.command] + args, env: env, stdin: stdin,
          cwd: pluginRoot.appendingPathComponent(server.cwd).path, child: .newGroup
        ).stdout)
    }

    let codex = runDetached(server.args)
    XCTAssertEqual(tools(codex, id: 1)?.isEmpty, true, "ツールを出さない: \(codex)")
    XCTAssertNotNil(
      codex.first { $0["id"] as? Int == 2 }?["error"], "呼ばれてもエラーを返す: \(codex)")
    XCTAssertTrue(
      control.target.taskStore.tasks.isEmpty, "タスクが足されない")

    XCTAssertFalse(
      (tools(runDetached([]), id: 1) ?? []).isEmpty, "CLI 名を渡さない定義ではツールが並ぶ")
  }
}
