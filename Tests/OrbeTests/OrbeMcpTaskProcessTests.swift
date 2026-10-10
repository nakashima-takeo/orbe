import XCTest

@testable import Orbe

/// 実 `orbe-mcp` を子プロセスで起こし、ブリッジがツール引数ではなく自分の環境の `ORBE_TAB` を
/// 呼び出し元タブとして添えることを固定する（タスクのツールが control へ届くことは
/// `OrbeMcpProcessTests` の全ツールの導通が持つ）。
///
/// 壊れると何が起きるか: ブリッジが `callerTabId` を添え損ねると、タブ内の claude が MCP で足したタスクが
/// どの workspace にも付かず、追加者も残らない。agent が引数に書いた値を通すと、名乗り間違い 1 つで
/// 別のタブの workspace に付き、別の agent の名前が残る。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続する（GhosttyKit 必須）。純ロジック検証ではない。
final class OrbeMcpTaskProcessTests: OrbeTestCase {
  private func tab(_ control: ControlProcess, in workspace: String) throws -> TerminalTab {
    try XCTUnwrap(control.target.workspaces.first { $0.name == workspace }?.tabs.first)
  }

  func testAddTaskAttachesToTheBridgesTabRegardlessOfTheArguments() throws {
    let control = try startControlProcess()
    let background = try tab(control, in: "background")
    let main = try tab(control, in: "main")
    control.target.controlReportAgent(
      tab: background, report: AgentHookReport(agent: "claude", state: "working", sessionId: "s-1"))
    let bridgeInBackground = ["ORBE_TAB": String(background.id)]

    let fromTab = control.mcpJSON("add_task", ["title": "タブから"], env: bridgeInBackground)
    let spoofed = control.mcpJSON(
      "add_task", ["title": "名乗り違い", "callerTabId": main.id], env: bridgeInBackground)
    let outside = control.mcpJSON("add_task", ["title": "タブの外", "callerTabId": background.id])

    for (label, result) in [("タブから", fromTab), ("名乗り違い", spoofed)] {
      let task = result["task"] as? [String: Any]
      XCTAssertEqual(
        task?["workspaceName"] as? String, "background", "\(label): ブリッジのタブの workspace に付く")
      XCTAssertEqual(task?["createdBy"] as? String, "claude", "\(label): ブリッジのタブの agent が追加者")
    }
    let outsideTask = outside["task"] as? [String: Any]
    XCTAssertNil(outsideTask?["workspaceId"], "タブの外のブリッジでは、引数の callerTabId を使わない")
    XCTAssertNil(outsideTask?["createdBy"])
  }

  /// 裏で走るコマンドを登録する口は `set_wait_condition` だけで、帳簿の動詞（`add_task` / `update_task`）は条件を
  /// 受けない——agent CLI のツール許可はツール単位なので、帳簿の動詞を「常に許可」してもコマンドの登録は許可されない。
  func testOnlySetWaitConditionTakesAWaitingCondition() throws {
    let tools = ControlProcess.mcpToolsList()
    func properties(_ name: String) throws -> [String: Any] {
      let tool = try XCTUnwrap(tools.first { $0["name"] as? String == name }, "\(name) が無い")
      let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
      return try XCTUnwrap(schema["properties"] as? [String: Any])
    }

    XCTAssertNil(try properties("add_task")["waitingCondition"])
    XCTAssertNil(try properties("update_task")["waitingCondition"])
    XCTAssertNotNil(try properties("set_wait_condition")["condition"])
  }
}
