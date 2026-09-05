import AppKit
import XCTest

@testable import Orbe

/// 休眠（未消費の復元チケット）を含む workspace が、制御 API の一覧へどう写るかを固定する。
/// 本体が `controlActivateWorkspace` ほかメソッド単位の契約を測るのに対し、ここは
/// 「live と休眠が混在した状態を各軸が独立に報告する」という横断の契約を測る。
/// ハーネス（`restore` / `tabbed` / `agentTab` / `row`）は本体ファイルが持つ。
extension WindowControllerControlTests {

  /// 全タブ materialize 完了後は復元 agent 由来が live 側へ移り、休眠数は 0 に収束する。
  func testListWorkspacesFullyMaterializedWorkspaceReportsZeroDormantAgentCount() throws {
    let sleepers = [agentTab("a"), agentTab("b")]
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed("active", tabs: sleepers),  // 活性かつ復元 agent 2（永続 agent は在る）
        tabbed("dormant", tabs: sleepers),  // 非活性で復元 agent 2
      ])
    let active = try XCTUnwrap(wc.workspaces.first { $0.name == "active" })
    XCTAssertTrue(
      waitUntil(5) { active.tabs.allSatisfy(\.activated) }, "前提: active 側は隠れタブも遅延 mount で起床")
    XCTAssertEqual(row(wc, name: "active")?["activated"] as? Bool, true)
    XCTAssertEqual(
      row(wc, name: "active")?["dormantAgentCount"] as? Int, 0,
      "materialize 時に復元由来を解消する")
    XCTAssertEqual(
      row(wc, name: "dormant")?["dormantAgentCount"] as? Int, 2,
      "非活性 WS は永続 agent タブ 2 を保持")
  }

  /// 背景 workspace へ 1 タブだけ生やすと、live と休眠復元タブが同時に存在する。
  func testListWorkspacesRepresentsBackgroundMixedWorkspaceOnIndependentAxes() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main"), tabbed("mixed", tabs: [agentTab("sleeping")])])
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

  /// 休眠 workspace のタブも列挙対象で、必須フィールドを live と同じだけ揃える。
  func testListTabsKeepsRequiredFieldsForDormantAndLiveTabs() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main"), tabbed("dormant", tabs: [agentTab("sleeping")])])
    let rows = wc.controlListTabs()
    XCTAssertEqual(
      Set(rows.compactMap { $0["workspaceName"] as? String }), ["main", "dormant"],
      "休眠 workspace のタブも列挙する")
    let required = [
      "tabId", "workspaceId", "workspaceName", "title", "cwd", "agentState", "agentSessionId",
      "active",
    ]
    for tab in rows {
      for key in required { XCTAssertNotNil(tab[key], "list_tabs は \(key) を保つ") }
    }
  }
}
