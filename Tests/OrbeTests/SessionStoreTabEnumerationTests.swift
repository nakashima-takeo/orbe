import XCTest

@testable import Orbe

/// `SessionStore.presentSessionIds`——「この同一性は今 Orbe に居る」の判定材料。**アクティブ workspace の
/// アクティブタブだけ**では取りこぼす（休眠 workspace のタブも含める）。
final class SessionStoreTabEnumerationTests: OrbeTestCase {

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
        resumeSpawn: { _, _ in nil })
    ]

    let store = SessionStore(workspaces: [live, dormant], activeWorkspace: 0)
    XCTAssertEqual(store.presentSessionIds, ["l-1", "d-1"])
  }
}
