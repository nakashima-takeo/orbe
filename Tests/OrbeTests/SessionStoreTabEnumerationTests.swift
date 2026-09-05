import XCTest

@testable import Orbe

/// `SessionStore.allPanes()` の契約。「そのパスをペインが開いている worktree は消せない」の判定材料で、
/// **アクティブ workspace のアクティブタブだけ**では取りこぼす（休眠 workspace のペインも含める）。
final class SessionStorePaneEnumerationTests: OrbeTestCase {

  private func makeStore() -> SessionStore {
    let active = Workspace(name: "active", rootPath: "/tmp/active")
    active.tabs = [
      TerminalController(initialCwd: "/tmp/wt/a"),
      TerminalController(initialCwd: "/tmp/wt/b"),
    ]
    active.active = 0
    let dormant = Workspace(name: "dormant", rootPath: "/tmp/dormant")
    dormant.tabs = [TerminalController(initialCwd: "/tmp/wt/c")]
    dormant.active = 0
    return SessionStore(workspaces: [active, dormant], activeWorkspace: 0)
  }

  /// 全 workspace × 全タブを列挙する（非アクティブタブ・休眠 workspace も落とさない）。
  func testEnumeratesEveryWorkspaceAndTab() {
    let panes = makeStore().allPanes()
    XCTAssertEqual(
      panes.map { $0.pane.initialCwd }, ["/tmp/wt/a", "/tmp/wt/b", "/tmp/wt/c"])
    XCTAssertEqual(panes.map(\.workspaceIndex), [0, 0, 1])
    XCTAssertEqual(panes.map(\.tabIndex), [0, 1, 0])
  }

  /// 休眠ペインは `currentPwd` を持たないが `initialCwd`（復元値）は持つので cwd の話に含まれる。
  func testDormantPanesStillCarryRestoredCwd() {
    let panes = makeStore().allPanes()
    let dormant = panes.last
    XCTAssertNil(dormant?.pane.currentPwd)
    XCTAssertEqual(dormant?.pane.initialCwd, "/tmp/wt/c")
  }

  func testEmptyWhenNoTabs() {
    let ws = Workspace(name: "ws", rootPath: "/tmp/ws")
    XCTAssertTrue(SessionStore(workspaces: [ws], activeWorkspace: 0).allPanes().isEmpty)
  }
}
