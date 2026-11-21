import XCTest

@testable import Orbe

/// `tools/list` のツールが添える MCP の注釈。
extension OrbeMcpProcessTests {
  /// 状態を変えないツールだけが `readOnlyHint: true` を持ち、ほかのツールは注釈を何も持たない。codex は注釈で承認の要否を決めるので、
  /// 状態を変えるツールに注釈が付くと、その呼び出しに承認を求めなくなる。
  func testOnlyToolsThatChangeNothingDeclareReadOnly() {
    let readOnly: Set = [
      "list_workspaces", "list_tabs", "list_agents", "get_tab_text", "session_log",
      "wait_for_event", "list_tasks", "list_automations", "list_automation_runs",
      "get_automation_trial", "list_automation_proposals", "list_board_widgets",
    ]
    let tools = ControlProcess.mcpToolsList()
    XCTAssertTrue(
      readOnly.isSubset(of: tools.compactMap { $0["name"] as? String }), "読むだけのツールが tools/list に無い")
    for tool in tools {
      let name = tool["name"] as? String ?? ""
      let annotations = tool["annotations"] as? [String: Bool]
      if readOnly.contains(name) {
        XCTAssertEqual(annotations, ["readOnlyHint": true], name)
      } else {
        XCTAssertNil(tool["annotations"], "\(name) は状態を変えるので注釈を持たない")
      }
    }
  }
}
