import AppKit
import OrbeSessionLog
import XCTest

@testable import Orbe

/// ⇧⌘T の配線を実 `WindowController` で端から端まで通す——対象はアクティブ workspace の閉じた同一性だけ、
/// ↵ で選んだ 1 件が戻り（同 worktree の連の右端、無ければ末尾）選択されて起きる、戻ったものは一覧から消える。
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
    XCTAssertEqual(palette.items.map(\.sessionId), ["m-1"])
    XCTAssertEqual(palette.items.first?.origin, .gesture)

    wc.dismissPalette()
    wc.switchWorkspace(to: 1)
    wc.showClosedAgentsPalette()
    XCTAssertEqual(
      wc.model.closedAgentsPalette?.items.map(\.sessionId), ["o-1"], "別 workspace では別の一覧")
  }

  func testEnterRestoresTheChosenOneAtTheEndSelectsItAndRemovesItFromTheList() throws {
    let wc = try restore()
    try closeAgentTab(wc, in: 0, id: "m-1", origin: .controlAPI)
    try closeAgentTab(wc, in: 0, id: "m-2", origin: .controlAPI)
    XCTAssertEqual(wc.current.tabs.count, 2, "前提: 素のシェル 2 枚が残る")
    wc.select(0)

    wc.showClosedAgentsPalette()
    let palette = try XCTUnwrap(wc.model.closedAgentsPalette)
    XCTAssertEqual(palette.items.map(\.sessionId), ["m-2", "m-1"], "同じ事故の 2 件も平らに新しい順")
    palette.render.selected = 1  // m-1
    palette.activate()

    XCTAssertEqual(wc.presentedOverlay, .none, "復元でパレットは閉じる")
    XCTAssertEqual(wc.current.tabs.count, 3, "戻るのは選んだ 1 件だけ")
    XCTAssertEqual(
      wc.current.tabs.last?.agentSlot.session?.sessionId, "m-1", "同じ cwd の連の右端＝末尾に足す")
    XCTAssertEqual(wc.current.active, 2, "復元したタブを選択して起こす")
    XCTAssertEqual(wc.sessionLog.lastEvent(sessionId: "m-1")?.kind, .opened, "起床で opened が付く")
    XCTAssertTrue(wc.current.tabs[2].activated)

    wc.showClosedAgentsPalette()
    XCTAssertEqual(
      wc.model.closedAgentsPalette?.items.map(\.sessionId), ["m-2"], "戻ったものは一覧から消える")
  }

  /// 最後の 1 枚を閉じて 0 タブになった workspace でも ⇧⌘T → ↵ で戻る（`availableWithoutTabs`）。
  /// 壊れると「うっかり最後のタブを閉じた」という主用途で何も戻らない。
  func testEnterRestoresIntoAnEmptiedWorkspace() throws {
    let wc = try restore()
    try closeAgentTab(wc, in: 0, id: "m-1", origin: .gesture)
    for tab in wc.current.tabs { wc.closeTab(tab, origin: .gesture) }
    XCTAssertTrue(wc.current.tabs.isEmpty, "前提: 0 タブ（休眠）workspace")

    XCTAssertTrue(wc.handleWindowKeyCommand(.showClosedAgentsPalette), "0 タブでも開く")
    let palette = try XCTUnwrap(wc.model.closedAgentsPalette)
    XCTAssertEqual(palette.items.map(\.sessionId), ["m-1"])
    palette.activate()

    XCTAssertEqual(
      wc.current.tabs.map { $0.agentSlot.session?.sessionId }, ["m-1"], "0 タブからも戻る")
    XCTAssertEqual(wc.current.active, 0, "唯一のタブを指す")
    XCTAssertTrue(wc.current.tabs[0].activated, "選択して起こす")
  }

  func testOpenPaletteFollowsATabThatCloses() throws {
    let wc = try restore()
    let opened = try XCTUnwrap(wc.openTab(workspaceIndex: 0, cwd: "/tmp"))
    let tab = try XCTUnwrap(wc.controlResolveTab(opened.tabId))
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "m-1"))
    wc.showClosedAgentsPalette()
    let palette = try XCTUnwrap(wc.model.closedAgentsPalette)
    XCTAssertTrue(palette.items.isEmpty, "前提: 生きている同一性は出ない")

    wc.closeTab(tab, origin: .process)
    wc.flushChrome()

    XCTAssertEqual(wc.presentedOverlay, .closedAgentsPalette, "開いたまま")
    XCTAssertEqual(palette.items.map(\.sessionId), ["m-1"], "閉じた分が一覧に増える")
    XCTAssertEqual(palette.items.first?.origin, .process)
  }
}
