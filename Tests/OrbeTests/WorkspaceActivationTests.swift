import XCTest

@testable import Orbe

/// workspace / tab の起床状態が履歴フラグに戻ると、背景 spawn 後の休眠タブが勝手に
/// live 集計され、最後の live タブを閉じても workspace が起床済みと誤報する。
@MainActor
final class WorkspaceActivationTests: OrbeTestCase {
  private let noResume: TerminalTab.ResumeSpawn = { _ in nil }

  /// resume 未対応 agent の復元タブ（消費時に素シェル化するが休眠チケットには数える）。
  private func restoredTab(agentId: String) -> TerminalTab {
    TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: agentId),
        explicitTitle: nil),
      resumeSpawn: noResume)
  }

  func testRestoredAgentProvenanceSurvivesResumeResolutionUntilMaterialization() throws {
    let session = AgentSession(command: "claude", sessionId: "resume-1")
    let tab = TerminalTab(
      restoring: TabState(cwd: "/tmp", agent: session, explicitTitle: nil),
      resumeSpawn: { _ in (command: "claude --resume resume-1", env: ["PROBE": "1"]) })

    XCTAssertFalse(tab.activated)
    XCTAssertTrue(tab.isDormant)
    XCTAssertEqual(
      tab.agentSlot, .dormant(AgentSession(command: "claude", sessionId: "resume-1")),
      "復元チケットは同一性ごと凍結され、消費まで resume を解決しない")

    tab.recordMaterializationStarted()
    XCTAssertTrue(tab.activated)
    XCTAssertFalse(tab.isDormant)
    XCTAssertEqual(
      tab.agentSlot,
      .live(session: AgentSession(command: "claude", sessionId: "resume-1"), report: nil),
      "消費で同一性を引き継いで live 化する（報告はまだ無い）")
  }

  func testRestoredPlainAndNewTabsDoNotCreateDormantAgentProvenance() {
    let restoredPlain = TerminalTab(
      restoring: TabState(cwd: "/tmp", agent: nil, explicitTitle: nil), resumeSpawn: noResume)
    let new = TerminalTab(cwd: "/tmp")
    XCTAssertFalse(restoredPlain.isDormant)
    XCTAssertFalse(new.isDormant)
  }

  func testWorkspaceActivationAlwaysEqualsAnyActivatedTab() {
    for tabCount in 0...3 {
      for bitMask in 0..<(1 << tabCount) {
        let ws = Workspace(name: "w", rootPath: "/tmp")
        ws.tabs = (0..<tabCount).map { index in
          let tab = TerminalTab(cwd: "/tmp")
          if bitMask & (1 << index) != 0 { tab.recordMaterializationStarted() }
          return tab
        }
        XCTAssertEqual(
          ws.activated, bitMask != 0,
          "tabCount=\(tabCount), bitMask=\(bitMask)")
      }
    }
  }

  func testRecordMaterializationValidatesOwnershipAndIsIdempotent() {
    let owned = Workspace(name: "owned", rootPath: "/tmp")
    let target = restoredTab(agentId: "a")
    let sibling = restoredTab(agentId: "c")
    owned.tabs = [target, sibling]
    owned.active = 1
    owned.lastUsedAt = Date(timeIntervalSinceReferenceDate: 123)
    let other = Workspace(name: "other", rootPath: "/tmp")
    let foreignTab = restoredTab(agentId: "d")
    other.tabs = [foreignTab]
    let store = SessionStore(workspaces: [owned, other], activeWorkspace: 0)

    XCTAssertTrue(store.recordMaterialization(of: target, in: owned))
    XCTAssertTrue(target.activated)
    XCTAssertTrue(owned.activated)
    XCTAssertFalse(target.isDormant)
    XCTAssertFalse(sibling.activated)
    XCTAssertTrue(sibling.isDormant)
    XCTAssertEqual(owned.active, 1)
    XCTAssertEqual(owned.lastUsedAt, Date(timeIntervalSinceReferenceDate: 123))

    XCTAssertTrue(store.recordMaterialization(of: target, in: owned), "同じ遷移は冪等")
    XCTAssertFalse(store.recordMaterialization(of: foreignTab, in: owned), "所有 workspace が違う")

    let outside = Workspace(name: "outside", rootPath: "/tmp")
    let outsideTab = restoredTab(agentId: "e")
    outside.tabs = [outsideTab]
    XCTAssertFalse(store.recordMaterialization(of: outsideTab, in: outside), "store 外は変更しない")
    XCTAssertFalse(foreignTab.activated)
    XCTAssertFalse(outsideTab.activated)
    XCTAssertTrue(foreignTab.isDormant)
    XCTAssertTrue(outsideTab.isDormant)
  }

  func testSelectionAndWorkspaceUseDoNotMaterializeTabs() throws {
    let ws = Workspace(name: "w", rootPath: "/tmp")
    ws.tabs = [TerminalTab(cwd: "/tmp"), TerminalTab(cwd: "/tmp")]
    ws.lastUsedAt = Date(timeIntervalSinceReferenceDate: 1)
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    XCTAssertTrue(store.recordSelection(1))
    XCTAssertEqual(ws.active, 1)
    XCTAssertGreaterThan(try XCTUnwrap(ws.lastUsedAt), Date(timeIntervalSinceReferenceDate: 1))
    XCTAssertFalse(ws.activated)
    XCTAssertTrue(ws.tabs.allSatisfy { !$0.activated })

    let outside = Workspace(name: "outside", rootPath: "/tmp")
    XCTAssertFalse(store.recordWorkspaceUse(outside))
    XCTAssertNil(outside.lastUsedAt)
  }

  func testMaterializationMovesRestoredAgentsFromDormantToLiveWithoutDoubleCounting() {
    let ws = Workspace(name: "mixed", rootPath: "/tmp")
    let liveA = restoredTab(agentId: "a")
    let liveB = restoredTab(agentId: "b")
    let dormant = restoredTab(agentId: "c")
    ws.tabs = [liveA, liveB, dormant]

    XCTAssertEqual(ws.agentCounts(), [:])
    XCTAssertEqual(ws.dormantAgentCount(), 3)

    liveA.recordMaterializationStarted()
    liveB.recordMaterializationStarted()
    XCTAssertFalse(liveA.isDormant)
    XCTAssertEqual(ws.dormantAgentCount(), 1)
    XCTAssertEqual(ws.agentCounts(), [:], "hook 報告前は live 状態も 0")

    setReportedState(liveA, "working")
    setReportedState(liveB, "waiting")
    XCTAssertEqual(ws.agentCounts(), ["working": 1, "waiting": 1])
    XCTAssertEqual(ws.dormantAgentCount(), 1, "live と休眠は別軸で二重計上しない")

    liveA.recordMaterializationStarted()
    XCTAssertEqual(ws.agentCounts(), ["working": 1, "waiting": 1])
    XCTAssertEqual(ws.dormantAgentCount(), 1)
  }

  func testLiveRollupCountsKnownStatesAndUsesCanonicalOrder() {
    let ws = Workspace(name: "live", rootPath: "/tmp")
    for state in ["idle", "done", "waiting", "working", "error"] {
      let tab = TerminalTab(cwd: "/tmp")
      tab.recordMaterializationStarted()
      setReportedState(tab, state)
      ws.tabs.append(tab)
    }

    XCTAssertEqual(
      ws.agentCounts(), ["working": 1, "waiting": 1, "done": 1, "idle": 1],
      "unknown は live タブでも集計対象外")
    let ordered = AgentRollup.ordered(AgentRollup.grandTotal(of: [ws]))
    XCTAssertEqual(ordered.map(\.state), ["working", "waiting", "done", "idle"])
    XCTAssertEqual(ordered.map(\.count), [1, 1, 1, 1])
  }

  /// 同じ state のタブは 1 枚ずつ数える（多重度）。`agentState` 未報告のタブは数えない。
  func testAgentCountsTalliesActivatedTabsPerState() {
    let ws = Workspace(name: "w", rootPath: "/tmp")
    for state in ["working", "waiting", "working", "idle"] {
      let tab = TerminalTab(cwd: "/tmp")
      tab.recordMaterializationStarted()
      setReportedState(tab, state)
      ws.tabs.append(tab)
    }
    let none = TerminalTab(cwd: "/tmp")
    none.recordMaterializationStarted()
    ws.tabs.append(none)

    let counts = ws.agentCounts()
    XCTAssertEqual(counts["working"], 2)
    XCTAssertEqual(counts["waiting"], 1)
    XCTAssertEqual(counts["idle"], 1, "idle は横断集計に数える")
    XCTAssertEqual(counts.count, 3, "nil は数えない")
  }

  func testRemovingTabsImmediatelyRecomputesActivationAndDormantCount() {
    let active = Workspace(name: "front", rootPath: "/tmp")
    active.tabs = [TerminalTab(cwd: "/tmp")]
    active.tabs[0].recordMaterializationStarted()

    let background = Workspace(name: "back", rootPath: "/tmp")
    let liveA = TerminalTab(cwd: "/tmp")
    let liveB = TerminalTab(cwd: "/tmp")
    liveA.recordMaterializationStarted()
    liveB.recordMaterializationStarted()
    let dormant = restoredTab(agentId: "sleeping")
    background.tabs = [liveA, liveB, dormant]
    background.lastUsedAt = Date(timeIntervalSinceReferenceDate: 456)
    let store = SessionStore(workspaces: [active, background], activeWorkspace: 0)

    guard case .backgroundChanged = store.removeTab(liveA, origin: .controlAPI) else {
      return XCTFail("background close")
    }
    XCTAssertTrue(background.activated, "live が 1 枚残る")
    XCTAssertEqual(background.dormantAgentCount(), 1)

    guard case .backgroundChanged = store.removeTab(liveB, origin: .controlAPI) else {
      return XCTFail("background close")
    }
    XCTAssertFalse(background.activated, "最後の live が消えれば dormant だけに戻る")
    XCTAssertEqual(background.dormantAgentCount(), 1)
    XCTAssertEqual(background.lastUsedAt, Date(timeIntervalSinceReferenceDate: 456))

    guard case .backgroundChanged = store.removeTab(dormant, origin: .controlAPI) else {
      return XCTFail("background close")
    }
    XCTAssertFalse(background.activated)
    XCTAssertEqual(background.dormantAgentCount(), 0)
    XCTAssertTrue(background.tabs.isEmpty)
  }

  func testRemovingUnknownTabChangesNothing() {
    let ws = Workspace(name: "w", rootPath: "/tmp")
    let owned = restoredTab(agentId: "a")
    ws.tabs = [owned]
    ws.lastUsedAt = Date(timeIntervalSinceReferenceDate: 789)
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    guard case .notFound = store.removeTab(TerminalTab(cwd: "/tmp"), origin: .controlAPI) else {
      return XCTFail("unknown tab")
    }
    XCTAssertEqual(ws.tabs.count, 1)
    XCTAssertTrue(ws.tabs[0] === owned)
    XCTAssertFalse(ws.activated)
    XCTAssertEqual(ws.dormantAgentCount(), 1)
    XCTAssertEqual(ws.lastUsedAt, Date(timeIntervalSinceReferenceDate: 789))
  }

  func testRemovingActiveTabsReportsIntermediateStateWithoutChangingMRU() {
    do {
      let ws = Workspace(name: "mixed", rootPath: "/tmp")
      let live = TerminalTab(cwd: "/tmp")
      live.recordMaterializationStarted()
      let dormant = restoredTab(agentId: "a")
      ws.tabs = [live, dormant]
      ws.lastUsedAt = Date(timeIntervalSinceReferenceDate: 100)
      let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

      guard case .reselectActive(let index) = store.removeTab(live, origin: .controlAPI) else {
        return XCTFail("active workspace に残存タブがあれば reselect")
      }
      XCTAssertEqual(index, 0)
      XCTAssertFalse(ws.activated, "host が reselect を処理する前の純粋導出値")
      XCTAssertEqual(ws.dormantAgentCount(), 1)
      XCTAssertEqual(ws.lastUsedAt, Date(timeIntervalSinceReferenceDate: 100))
    }

    do {
      let ws = Workspace(name: "empty", rootPath: "/tmp")
      let live = TerminalTab(cwd: "/tmp")
      live.recordMaterializationStarted()
      ws.tabs = [live]
      ws.lastUsedAt = Date(timeIntervalSinceReferenceDate: 200)
      let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

      guard case .emptiedActive = store.removeTab(live, origin: .controlAPI) else {
        return XCTFail("最後の active tab を閉じると empty のまま前面維持")
      }
      XCTAssertTrue(ws.tabs.isEmpty)
      XCTAssertFalse(ws.activated)
      XCTAssertEqual(ws.dormantAgentCount(), 0)
      XCTAssertEqual(ws.lastUsedAt, Date(timeIntervalSinceReferenceDate: 200))
    }
  }
}
