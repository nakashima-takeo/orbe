import XCTest

@testable import Orbe

/// `SessionStore.allTabs()` の契約。「そのパスをタブが開いている worktree は消せない」の判定材料で、
/// **アクティブ workspace のアクティブタブだけ**では取りこぼす（休眠 workspace のタブも含める）。
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
}
