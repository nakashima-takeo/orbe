import Foundation
import XCTest

@testable import Orbe

/// タブが store から外れる 2 経路（`removeTab` / `closeWorkspace(_:origin:)`）が、配列から外す**前**に
/// タブへ発火源を告げることを固定する。壊れると、記録側が所属 workspace を引けず、閉じたセッションの
/// 名前・rootPath が落ちる（＝復元先が分からない）。
final class SessionStoreDetachTests: OrbeTestCase {
  private func agentTab(_ id: String) -> TerminalTab {
    let tab = TerminalTab(cwd: "/tmp")
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: id))
    return tab
  }

  func testRemoveTabTellsTheTabWhileItIsStillInTheWorkspace() {
    let ws = Workspace(name: "w", rootPath: "/tmp")
    let tab = agentTab("a")
    ws.tabs = [tab]
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)
    var seen: (origin: TerminalTab.IdentityTransition, stillIn: Bool)?
    tab.onIdentityTransition = { seen = ($0, ws.tabs.contains { $0 === tab }) }

    guard case .emptiedActive = store.removeTab(tab, origin: .process) else {
      return XCTFail("最後のタブを外すと emptiedActive")
    }

    XCTAssertEqual(
      seen?.origin,
      .closed(.init(command: "claude", sessionId: "a"), origin: .process, reason: nil))
    XCTAssertEqual(seen?.stillIn, true, "外す前に告げる")
  }

  func testCloseWorkspaceTellsEveryTabWithTheCallersOrigin() {
    let doomed = Workspace(name: "doomed", rootPath: "/tmp")
    doomed.tabs = [agentTab("a"), agentTab("b")]
    let keep = Workspace(name: "keep", rootPath: "/tmp")
    let store = SessionStore(workspaces: [keep, doomed], activeWorkspace: 0)
    var origins: [TerminalTab.IdentityTransition] = []
    for tab in doomed.tabs { tab.onIdentityTransition = { origins.append($0) } }

    XCTAssertEqual(store.closeWorkspace(1, origin: .controlAPI), .backgroundChanged)

    XCTAssertEqual(
      origins,
      ["a", "b"].map {
        .closed(.init(command: "claude", sessionId: $0), origin: .controlAPI, reason: nil)
      })
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

  func testInsertRestoredTabKeepsSelectionAndAppendWorkspaceKeepsActiveWorkspace() {
    let ws = Workspace(name: "w", rootPath: "/tmp")
    ws.tabs = [TerminalTab(cwd: "/tmp"), TerminalTab(cwd: "/tmp")]
    ws.active = 0
    let store = SessionStore(
      workspaces: [ws, Workspace(name: "bg", rootPath: "/tmp")], activeWorkspace: 0)

    XCTAssertEqual(store.insertRestoredTab(TerminalTab(cwd: "/tmp"), intoWorkspaceAt: 1), 0)
    XCTAssertEqual(store.workspaces[1].active, 0, "0 タブの背景 WS は新タブが active になる")
    XCTAssertEqual(store.insertRestoredTab(TerminalTab(cwd: "/tmp"), intoWorkspaceAt: 0), 2)
    XCTAssertEqual(ws.active, 0, "アクティブ WS でも選択は動かさない")
    XCTAssertEqual(ws.tabs.count, 3, "同キーの連の右端＝末尾に足す")

    let index = store.appendWorkspace(name: "new", rootPath: "~/x")
    XCTAssertEqual(index, 2)
    XCTAssertEqual(store.activeWorkspace, 0, "アクティブ化しない")
    XCTAssertEqual(
      store.workspaces[2].rootPath, ("~/x" as NSString).expandingTildeInPath, "~ はホーム展開")
  }
}
