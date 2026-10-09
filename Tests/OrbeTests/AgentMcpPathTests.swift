import Foundation
import XCTest

@testable import Orbe

/// プラグインの MCP 定義からの実経路を継ぎ目ごと 1 本で通す——タブへ注入された env の**実値**で
/// 同梱の MCP シムを実 `/bin/sh` から起こし、シムが exec した実 `orbe-mcp` が実 `ControlServer` へ
/// つながり、呼び出し元のタブとして扱われるまで。
///
/// 区間ごとの検証は別に在る（シムのチャネル判定と空サーバーは `AgentMcpShimTests`、ブリッジが
/// `ORBE_TAB` を呼び出し元に添えることは `OrbeMcpTaskProcessTests`）。ここが見るのは、注入された env
/// だけでシムがタブの Orbe の `orbe-mcp` を選び、そのブリッジにタブの印が届くこと。
///
/// 壊れると何が起きるか: Orbe のタブの agent に Orbe のツールが 1 つも出ない。しかもエラーにならない——
/// シムは選べなければ空サーバーとして正常に応答する。
final class AgentMcpPathTests: OrbeTestCase {
  private func runShim(
    _ shim: URL, env: [String: String], requests: [[String: Any]],
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> [[String: Any]] {
    let lines = try requests.map {
      try XCTUnwrap(String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8))
    }
    let outcome = ControlProcess.run(
      URL(fileURLWithPath: "/bin/sh"), [shim.path], env: env,
      stdin: lines.joined(separator: "\n") + "\n", file: file, line: line)
    return outcome.stdout.split(separator: "\n").compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }

  /// 注入 env → MCP シム → 同梱 `orbe-mcp` → control、で add_task が呼んだタブの workspace に付く。
  func testInjectedEnvConnectsBridgeAsTheCallingTab() throws {
    let control = try startControlProcess()
    let shim = try ControlProcess.stagePlugin().appendingPathComponent("mcp/orbe-mcp.sh")
    let tab = try XCTUnwrap(control.target.workspaces.first { $0.name == "background" }?.tabs.first)
    var env = ["PATH": "/usr/bin:/bin"]
    OrbeRuntimeEnv.inject(into: &env, tabId: tab.id)

    XCTAssertEqual(
      env["ORBE_MCP_BIN"], BundledResources.root?.appendingPathComponent("bin/orbe-mcp").path,
      "同梱 orbe-mcp の絶対パスが注入される")

    let responses = try runShim(
      shim, env: env,
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
