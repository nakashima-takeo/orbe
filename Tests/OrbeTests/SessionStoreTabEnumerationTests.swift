import XCTest

@testable import Orbe

/// `SessionStore.allTabs()` と、その上に立つ `presentSessionIds` の契約。「そのパスをタブが開いている
/// worktree は消せない」「この同一性は今 Orbe に居る」の判定材料で、**アクティブ workspace のアクティブ
/// タブだけ**では取りこぼす（休眠 workspace のタブも含める）。
final class SessionStoreTabEnumerationTests: OrbeTestCase {

  private func makeStore() -> SessionStore {
    let active = Workspace(name: "active", rootPath: "/tmp/active")
    active.tabs = [
      TerminalTab(cwd: "/tmp/wt/a"),
      TerminalTab(cwd: "/tmp/wt/b"),
    ]
    active.active = 0
    let dormant = Workspace(name: "dormant", rootPath: "/tmp/dormant")
    dormant.tabs = [TerminalTab(cwd: "/tmp/wt/c")]
    dormant.active = 0
    return SessionStore(workspaces: [active, dormant], activeWorkspace: 0)
  }

  /// 全 workspace × 全タブを列挙する（非アクティブタブ・休眠 workspace も落とさない）。
  func testEnumeratesEveryWorkspaceAndTab() {
    let tabs = makeStore().allTabs()
    XCTAssertEqual(tabs.map { $0.tab.cwd }, ["/tmp/wt/a", "/tmp/wt/b", "/tmp/wt/c"])
    XCTAssertEqual(tabs.map(\.workspaceIndex), [0, 0, 1])
    XCTAssertEqual(tabs.map(\.tabIndex), [0, 1, 0])
  }

  /// 休眠タブは `currentPwd` を持たないが `initialCwd`（復元値）は持つので cwd の話に含まれる。
  func testDormantTabsStillCarryRestoredCwd() {
    let tabs = makeStore().allTabs()
    let dormant = tabs.last
    XCTAssertNil(dormant?.tab.surface.currentPwd)
    XCTAssertEqual(dormant?.tab.cwd, "/tmp/wt/c")
  }

  func testEmptyWhenNoTabs() {
    let ws = Workspace(name: "ws", rootPath: "/tmp/ws")
    XCTAssertTrue(SessionStore(workspaces: [ws], activeWorkspace: 0).allTabs().isEmpty)
  }

  /// 居る同一性は live / 休眠を問わず全 workspace から集め、sessionId の無い報告は数えない。
  /// 落とすと `restore_sessions` と ⇧⌘T が生きているセッションを二重に戻す。
  func testPresentSessionIdsSpanLiveAndDormantTabsOfEveryWorkspace() {
    let live = Workspace(name: "live", rootPath: "/tmp")
    let liveTab = TerminalTab(cwd: "/tmp")
    liveTab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "l-1"))
    let unnamed = TerminalTab(cwd: "/tmp")
    unnamed.applyReport(AgentHookReport(agent: "claude", state: "idle"))
    live.tabs = [liveTab, unnamed, TerminalTab(cwd: "/tmp")]
    let dormant = Workspace(name: "dormant", rootPath: "/tmp")
    dormant.tabs = [
      TerminalTab(
        restoring: TabState(
          cwd: "/tmp", agent: AgentSession(command: "codex", sessionId: "d-1"), explicitTitle: nil),
        resumeSpawn: { _ in nil })
    ]

    let store = SessionStore(workspaces: [live, dormant], activeWorkspace: 0)
    XCTAssertEqual(store.presentSessionIds, ["l-1", "d-1"])
  }
}
