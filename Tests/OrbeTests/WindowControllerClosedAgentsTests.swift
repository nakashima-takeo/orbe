import AppKit
import OrbeSessionLog
import XCTest

@testable import Orbe

/// ⇧⌘T の配線を実 `WindowController` で端から端まで通す——対象はアクティブ workspace の閉じた同一性だけ、
/// ↵ で末尾に戻り先頭が選択されて起きる、戻ったものは一覧から消える。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerClosedAgentsTests: OrbeTestCase {
  override func setUp() {
    super.setUp()
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  private func restore() throws -> WindowController {
    let plain = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp/main", activeTab: 0, tabs: [plain, plain]),
        WorkspaceState(name: "other", rootPath: "/tmp/other", activeTab: 0, tabs: [plain]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  /// 同一性を持つタブを workspace に作って閉じる（ログに opened → closed(origin) が残る）。
  private func closeAgentTab(
    _ wc: WindowController, in workspace: Int, id: String, origin: TabCloseOrigin
  ) throws {
    let opened = try XCTUnwrap(wc.openTab(workspaceIndex: workspace, cwd: "/tmp"))
    let tab = try XCTUnwrap(wc.controlResolveTab(opened.tabId))
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: id))
    wc.closeTab(tab, origin: origin)
  }

  func testPaletteListsOnlyTheActiveWorkspacesClosedAgents() throws {
    let wc = try restore()
    try closeAgentTab(wc, in: 0, id: "m-1", origin: .gesture)
    try closeAgentTab(wc, in: 1, id: "o-1", origin: .gesture)

    XCTAssertTrue(wc.handleWindowKeyCommand(.showClosedAgentsPalette))
    XCTAssertEqual(wc.presentedOverlay, .closedAgentsPalette)
    let palette = try XCTUnwrap(wc.model.closedAgentsPalette)
    XCTAssertEqual(palette.groups.flatMap { $0.items.map(\.sessionId) }, ["m-1"])
    XCTAssertEqual(palette.groups.first?.origin, .gesture)

    wc.dismissPalette()
    wc.switchWorkspace(to: 1)
    wc.showClosedAgentsPalette()
    XCTAssertEqual(
      wc.model.closedAgentsPalette?.groups.flatMap { $0.items.map(\.sessionId) }, ["o-1"],
      "別 workspace では別の一覧")
  }

  func testEnterRestoresAtTheEndSelectsTheFirstAndRemovesThemFromTheList() throws {
    let wc = try restore()
    try closeAgentTab(wc, in: 0, id: "m-1", origin: .controlAPI)
    try closeAgentTab(wc, in: 0, id: "m-2", origin: .controlAPI)
    XCTAssertEqual(wc.current.tabs.count, 2, "前提: 素のシェル 2 枚が残る")
    wc.select(0)

    wc.showClosedAgentsPalette()
    let palette = try XCTUnwrap(wc.model.closedAgentsPalette)
    XCTAssertEqual(palette.groups.count, 1, "5 秒以内・同 origin は 1 群")
    palette.activate()

    XCTAssertEqual(wc.presentedOverlay, .none, "復元でパレットは閉じる")
    XCTAssertEqual(
      wc.current.tabs.suffix(2).map { $0.agentSlot.session?.sessionId }, ["m-2", "m-1"],
      "群の順（新しい順）で末尾に足す")
    XCTAssertEqual(wc.current.active, 2, "復元した先頭のタブを選択して起こす")
    XCTAssertEqual(wc.sessionLog.lastEvent(sessionId: "m-2")?.kind, .opened, "起床で opened が付く")
    XCTAssertTrue(wc.current.tabs[2].activated)

    wc.showClosedAgentsPalette()
    XCTAssertTrue(
      wc.model.closedAgentsPalette?.groups.isEmpty == true, "戻ったものは一覧から消える")
  }

  func testMembersRestoreOnlyTheChosenOne() throws {
    let wc = try restore()
    try closeAgentTab(wc, in: 0, id: "m-1", origin: .controlAPI)
    try closeAgentTab(wc, in: 0, id: "m-2", origin: .controlAPI)

    wc.showClosedAgentsPalette()
    let palette = try XCTUnwrap(wc.model.closedAgentsPalette)
    XCTAssertTrue(palette.drillIn())
    palette.render.selected = 1  // m-1（群内は新しい順）
    palette.activate()

    XCTAssertEqual(wc.current.tabs.last?.agentSlot.session?.sessionId, "m-1")
    XCTAssertEqual(wc.current.tabs.count, 3)
    wc.showClosedAgentsPalette()
    XCTAssertEqual(
      wc.model.closedAgentsPalette?.groups.flatMap { $0.items.map(\.sessionId) }, ["m-2"])
  }
}
