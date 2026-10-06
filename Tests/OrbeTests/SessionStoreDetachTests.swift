import XCTest

@testable import Orbe

/// 消せなかった workspace（最後の 1 つ）の配下のタブには、閉鎖を告げないこと。外す前に告げること自体は
/// 寿命ログに workspace が載るかで `WindowControllerSessionLogTests` が見る。
///
/// 壊れると何が起きるか: 生きているタブのセッションが寿命ログで閉じたことになる。
final class SessionStoreDetachTests: OrbeTestCase {
  private func agentTab(_ id: String) -> TerminalTab {
    let tab = TerminalTab(cwd: "/tmp")
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: id))
    return tab
  }

  func testInvalidCloseWorkspaceTellsNobody() {
    let only = Workspace(name: "only", rootPath: "/tmp")
    only.tabs = [agentTab("a")]
    let store = SessionStore(workspaces: [only], activeWorkspace: 0)
    var told = false
    only.tabs[0].onIdentityTransition = { _ in told = true }

    XCTAssertEqual(store.closeWorkspace(0, origin: .gesture), .invalid)
    XCTAssertFalse(told, "最後の 1 つは消えないので告げない")
  }
}
