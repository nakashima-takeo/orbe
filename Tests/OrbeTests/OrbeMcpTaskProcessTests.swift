import XCTest

@testable import Orbe

/// 実 `orbe-mcp` を子プロセスで起こし、タスクの 5 ツールが control へ届くこと、ブリッジがツール引数ではなく
/// 自分の環境の `ORBE_TAB` を呼び出し元タブとして添えることを固定する。
///
/// 壊れると何が起きるか: ブリッジが `callerTabId` を添え損ねると、タブ内の claude が MCP で足したタスクが
/// どの workspace にも付かず、追加者も残らない。agent が引数に書いた値を通すと、名乗り間違い 1 つで
/// 別のタブの workspace に付き、別の agent の名前が残る。ツールの schema から必須や null の許容が
/// 抜けると、AI は外す操作（null）を組めなくなる。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続する（GhosttyKit 必須）。純ロジック検証ではない。
final class OrbeMcpTaskProcessTests: OrbeTestCase {
  private let taskTools = ["list_tasks", "add_task", "update_task", "move_task", "delete_task"]

  private func properties(_ tool: [String: Any]) -> [String: Any] {
    (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
  }

  private func acceptsNull(_ tool: [String: Any], _ key: String) -> Bool {
    ((properties(tool)[key] as? [String: Any])?["type"] as? [String])?.contains("null") ?? false
  }

  private func tab(_ control: ControlProcess, in workspace: String) throws -> TerminalTab {
    try XCTUnwrap(control.target.workspaces.first { $0.name == workspace }?.tabs.first)
  }

  func testToolsListExposesTheTaskToolsWithoutTheCallerTab() throws {
    let tools = ControlProcess.mcpToolsList()
    func tool(_ name: String) throws -> [String: Any] {
      try XCTUnwrap(tools.first { $0["name"] as? String == name }, "\(name) が tools/list に無い")
    }

    for (name, required) in [
      ("add_task", ["title"]), ("update_task", ["taskId"]), ("move_task", ["taskId"]),
      ("delete_task", ["taskId"]),
    ] {
      XCTAssertEqual(
        (try tool(name)["inputSchema"] as? [String: Any])?["required"] as? [String], required,
        "\(name) の必須")
    }
    XCTAssertNotNil(
      properties(try tool("list_tasks"))["workspaceId"], "list_tasks は workspace で絞れる")

    let add = try tool("add_task")
    XCTAssertTrue(acceptsNull(add, "workspaceId"), "add_task の workspaceId は null（なし）を受ける")
    XCTAssertTrue(
      (add["description"] as? String ?? "").contains("呼び出し元タブ"),
      "add_task の description が「省略 = 呼び出し元タブの workspace」を書く")
    let update = try tool("update_task")
    for key in ["due", "waitingReason", "workspaceId", "worktree"] {
      XCTAssertTrue(acceptsNull(update, key), "update_task の \(key) は null（外す）を受ける")
    }
    XCTAssertNotNil(properties(add)["worktree"], "add_task は worktree を付けられる")
    for tool in [add, update] {
      XCTAssertNotNil(
        properties(tool)["description"], "\(tool["name"] ?? "") はタスクの詳細を control と同じ名前で書ける")
    }
    for tool in [add, update] {
      let links = properties(tool)["links"] as? [String: Any]
      let item = links?["items"] as? [String: Any]
      XCTAssertEqual(links?["type"] as? String, "array", "\(tool["name"] ?? "") の links は配列")
      XCTAssertEqual(
        Set(item?["required"] as? [String] ?? []), ["kind", "repo", "number"],
        "\(tool["name"] ?? "") の links の要素は kind・repo・number を必ず持つ")
    }
    let move = try tool("move_task")
    XCTAssertEqual(Set(properties(move).keys), ["taskId", "beforeTaskId", "afterTaskId"])

    for name in taskTools {
      XCTAssertNil(
        properties(try tool(name))["callerTabId"],
        "\(name) の引数に callerTabId を出さない（ブリッジが環境から添える）")
    }
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

  /// 5 ツールの `tools/call` が control へ届き、control の拒否は `isError` へ畳まれる。
  func testTaskToolsReachControlThroughTheBridge() throws {
    let control = try startControlProcess()
    func added(_ title: String) throws -> Int {
      let task = control.mcpJSON("add_task", ["title": title])["task"] as? [String: Any]
      return try XCTUnwrap(task?["taskId"] as? Int)
    }
    let first = try added("a")
    let second = try added("b")

    let updated = control.mcpJSON(
      "update_task", ["taskId": first, "status": "done", "due": NSNull()])
    XCTAssertEqual((updated["task"] as? [String: Any])?["status"] as? String, "done")
    XCTAssertEqual(
      control.mcpJSON("move_task", ["taskId": second, "beforeTaskId": first])["ok"] as? Bool, true)
    XCTAssertEqual(control.mcpJSON("delete_task", ["taskId": first])["ok"] as? Bool, true)
    XCTAssertEqual(
      (control.mcpJSON("list_tasks")["tasks"] as? [[String: Any]])?.compactMap {
        $0["taskId"] as? Int
      },
      [second])

    let rejected = control.mcpCall("update_task", ["taskId": first, "title": "x"])
    XCTAssertTrue(rejected.isError, "消したタスクの変更は isError")
    XCTAssertTrue(rejected.text.contains("task not found"), "本文に理由が残る: \(rejected.text)")
  }
}
