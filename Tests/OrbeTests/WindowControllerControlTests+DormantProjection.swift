import AppKit
import XCTest

@testable import Orbe

/// 休眠（未消費の復元チケット）を含む workspace が、制御 API の一覧へどう写るかを固定する。
/// 本体が `controlActivateWorkspace` ほかメソッド単位の契約を測るのに対し、ここは
/// 「live と休眠が混在した状態を各軸が独立に報告する」という横断の契約を測る。
/// ハーネス（`restore` / `tabbed` / `agentLeaf` / `row`）は本体ファイルが持つ。
extension WindowControllerControlTests {

  /// 全タブ materialize 完了後は復元 agent 由来が live 側へ移り、休眠数は 0 に収束する。
  func testListWorkspacesFullyMaterializedWorkspaceReportsZeroDormantAgentCount() throws {
    let sleepers = PaneNode.split(
      vertical: true, ratio: 0.5, first: agentLeaf("a"), second: agentLeaf("b"))
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed("active", tree: sleepers),  // 活性かつ復元 agent 2（永続 leaf は在る）
        tabbed("dormant", tree: sleepers),  // 非活性で復元 agent 2
      ])
    XCTAssertEqual(row(wc, name: "active")?["activated"] as? Bool, true, "前提: active 側は全タブ起床")
    XCTAssertEqual(
      row(wc, name: "active")?["dormantAgentCount"] as? Int, 0,
      "materialize 時に復元由来を解消する")
    XCTAssertEqual(
      row(wc, name: "dormant")?["dormantAgentCount"] as? Int, 2,
      "非活性 WS は永続 agent leaf 2 を保持")
  }

  /// 背景 workspace へ 1 タブだけ生やすと、live と休眠復元タブが同時に存在する。
  func testListWorkspacesRepresentsBackgroundMixedWorkspaceOnIndependentAxes() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main"), tabbed("mixed", tree: agentLeaf("sleeping"))])
    let mixedId = try XCTUnwrap(row(wc, name: "mixed")?["id"] as? Int)

    _ = try XCTUnwrap(wc.controlSpawn(workspaceId: mixedId, cwd: nil, command: nil))

    let mixed = try XCTUnwrap(row(wc, name: "mixed"))
    XCTAssertEqual(mixed["active"] as? Bool, false, "前面 workspace は奪わない")
    XCTAssertEqual(mixed["activated"] as? Bool, true, "新規タブは off-screen materialize 済み")
    XCTAssertEqual(mixed["dormantAgentCount"] as? Int, 1, "既存復元タブは休眠のまま保つ")
    let owner = try XCTUnwrap(wc.workspaces.first { $0.name == "mixed" })
    XCTAssertEqual(owner.tabs.count, 2)
    XCTAssertEqual(owner.tabs.filter(\.activated).count, 1)
  }

  /// 休眠 workspace の pane も列挙対象で、必須フィールドを live と同じだけ揃える。
  func testListPanesKeepsRequiredFieldsForDormantAndLivePanes() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main"), tabbed("dormant", tree: agentLeaf("sleeping"))])
    let rows = wc.controlListPanes()
    XCTAssertEqual(
      Set(rows.compactMap { $0["workspaceName"] as? String }), ["main", "dormant"],
      "休眠 workspace の pane も列挙する")
    let required = [
      "paneId", "workspaceId", "tabId", "workspaceName", "title", "cwd", "agentState",
      "agentSessionId", "focused",
    ]
    for pane in rows {
      for key in required { XCTAssertNotNil(pane[key], "list_panes は \(key) を保つ") }
    }
  }
}
