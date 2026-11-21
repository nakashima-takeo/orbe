import XCTest

@testable import Orbe

/// `tools/list` のツールが添える MCP の注釈。
extension OrbeMcpProcessTests {
  /// 状態を変えず、待たずに返り、タブの画面の中身を返さないツールだけが `readOnlyHint: true` を持ち、ほかのツールは注釈を何も
  /// 持たない。codex は注釈で承認の要否を決めるので、状態を変えるツールやタブの画面を読むツールに注釈が付くと、その呼び出しに
  /// 承認を求めなくなる。長く待つツールに付くと、codex・claude が並べて呼び、ブリッジは 1 件ずつ応えるので後ろの呼び出しが時間切れになる。
  func testOnlyToolsThatChangeNothingAndReturnAtOnceDeclareReadOnly() {
    let readOnly: Set = [
      "list_workspaces", "list_tabs", "list_agents", "session_log", "list_tasks",
      "list_automations", "list_automation_runs", "list_automation_proposals",
      "list_board_widgets",
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
        XCTAssertNil(tool["annotations"], "\(name) は注釈を付ける基準に当たらないので注釈を持たない")
      }
    }
  }
}
