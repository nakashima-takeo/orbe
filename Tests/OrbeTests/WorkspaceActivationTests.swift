import XCTest

@testable import Orbe

/// workspace / tab の起床状態が履歴フラグに戻ると、背景 spawn 後の休眠タブが勝手に
/// live 集計され、最後の live タブを閉じても workspace が起床済みと誤報する。
@MainActor
final class WorkspaceActivationTests: OrbeTestCase {
  private let noResume: TerminalController.ResumeSpawn = { _ in nil }

  private func restoredTab(agentIds: [String], plainLeaves: Int = 0) -> TerminalController {
    let agentLeaves = agentIds.map {
      PaneNode.leaf(cwd: nil, agent: AgentSession(command: "unknown", sessionId: $0))
    }
    let plain = (0..<plainLeaves).map { _ in PaneNode.leaf(cwd: nil, agent: nil) }
    let leaves = agentLeaves + plain
    precondition(!leaves.isEmpty)
    let tree = leaves.dropFirst().reduce(leaves[0]) {
      .split(vertical: true, ratio: 0.5, first: $0, second: $1)
    }
    return TerminalController(restoring: tree, resumeSpawn: noResume)
  }

  func testRestoredAgentProvenanceSurvivesResumeResolutionUntilMaterialization() throws {
    let session = AgentSession(command: "claude", sessionId: "resume-1")
    let tab = TerminalController(
      restoring: .leaf(cwd: "/tmp", agent: session),
      resumeSpawn: { _ in (command: "claude --resume resume-1", env: ["PROBE": "1"]) })
    let pane = try XCTUnwrap(tab.controlAllPanes().first)

    XCTAssertFalse(tab.activated)
    XCTAssertEqual(tab.restoredAgentCount, 1)
    XCTAssertTrue(pane.holdsDormantRestoredAgent)
    XCTAssertEqual(pane.agentCommand, "claude")
    XCTAssertEqual(pane.agentSessionId, "resume-1")

    tab.recordMaterializationStarted()
    XCTAssertTrue(tab.activated)
    XCTAssertEqual(tab.restoredAgentCount, 0)
  }

  func testRestoredPlainAndNewTabsDoNotCreateDormantAgentProvenance() {
    let restoredPlain = TerminalController(
      restoring: .leaf(cwd: "/tmp", agent: nil), resumeSpawn: noResume)
    let new = TerminalController(initialCwd: "/tmp")
    XCTAssertEqual(restoredPlain.restoredAgentCount, 0)
    XCTAssertEqual(new.restoredAgentCount, 0)
  }

  func testWorkspaceActivationAlwaysEqualsAnyActivatedTab() {
    for tabCount in 0...3 {
      for bitMask in 0..<(1 << tabCount) {
        let ws = Workspace(name: "w", rootPath: "/tmp")
        ws.tabs = (0..<tabCount).map { index in
          let tab = TerminalController()
          if bitMask & (1 << index) != 0 { tab.recordMaterializationStarted() }
          return tab
        }
        XCTAssertEqual(
          ws.activated, ws.tabs.contains(where: \.activated),
          "tabCount=\(tabCount), bitMask=\(bitMask)")
      }
    }
  }

  func testRecordMaterializationValidatesOwnershipAndIsIdempotent() {
    let owned = Workspace(name: "owned", rootPath: "/tmp")
    let target = restoredTab(agentIds: ["a", "b"])
    let sibling = restoredTab(agentIds: ["c"])
    owned.tabs = [target, sibling]
    owned.active = 1
    owned.lastUsedAt = Date(timeIntervalSinceReferenceDate: 123)
    let other = Workspace(name: "other", rootPath: "/tmp")
    let foreignTab = restoredTab(agentIds: ["d"])
    other.tabs = [foreignTab]
    let store = SessionStore(workspaces: [owned, other], activeWorkspace: 0)

    XCTAssertTrue(store.recordMaterialization(of: target, in: owned))
    XCTAssertTrue(target.activated)
    XCTAssertTrue(owned.activated)
    XCTAssertEqual(target.restoredAgentCount, 0)
    XCTAssertFalse(sibling.activated)
    XCTAssertEqual(sibling.restoredAgentCount, 1)
    XCTAssertEqual(owned.active, 1)
    XCTAssertEqual(owned.lastUsedAt, Date(timeIntervalSinceReferenceDate: 123))

    XCTAssertTrue(store.recordMaterialization(of: target, in: owned), "同じ遷移は冪等")
    XCTAssertFalse(store.recordMaterialization(of: foreignTab, in: owned), "所有 workspace が違う")

    let outside = Workspace(name: "outside", rootPath: "/tmp")
    let outsideTab = restoredTab(agentIds: ["e"])
    outside.tabs = [outsideTab]
    XCTAssertFalse(store.recordMaterialization(of: outsideTab, in: outside), "store 外は変更しない")
    XCTAssertFalse(foreignTab.activated)
    XCTAssertFalse(outsideTab.activated)
    XCTAssertEqual(foreignTab.restoredAgentCount, 1)
    XCTAssertEqual(outsideTab.restoredAgentCount, 1)
  }

  func testSelectionAndWorkspaceUseDoNotMaterializeTabs() throws {
    let ws = Workspace(name: "w", rootPath: "/tmp")
    ws.tabs = [TerminalController(), TerminalController()]
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
    let live = restoredTab(agentIds: ["a", "b"], plainLeaves: 1)
    let dormant = restoredTab(agentIds: ["c"])
    ws.tabs = [live, dormant]

    XCTAssertEqual(ws.agentCounts(), [:])
    XCTAssertEqual(ws.dormantAgentCount(), 3)

    live.recordMaterializationStarted()
    XCTAssertEqual(live.restoredAgentCount, 0)
    XCTAssertEqual(ws.dormantAgentCount(), 1)
    XCTAssertEqual(ws.agentCounts(), [:], "hook 報告前は live 状態も 0")

    live.controlAllPanes()[0].agentState = "working"
    live.controlAllPanes()[1].agentState = "waiting"
    XCTAssertEqual(ws.agentCounts(), ["working": 1, "waiting": 1])
    XCTAssertEqual(ws.dormantAgentCount(), 1, "live と休眠は別軸で二重計上しない")

    live.recordMaterializationStarted()
    XCTAssertEqual(ws.agentCounts(), ["working": 1, "waiting": 1])
    XCTAssertEqual(ws.dormantAgentCount(), 1)
  }

  func testActivatedTabIsExcludedFromDormantCountEvenIfProvenanceIsCorrupted() {
    let ws = Workspace(name: "w", rootPath: "/tmp")
    let tab = restoredTab(agentIds: ["a"])
    ws.tabs = [tab]
    tab.recordMaterializationStarted()
    tab.controlAllPanes()[0].holdsDormantRestoredAgent = true

    XCTAssertTrue(tab.activated)
    XCTAssertEqual(tab.restoredAgentCount, 1, "pane 由来の破損 fixture を明示")
    XCTAssertEqual(ws.dormantAgentCount(), 0, "consumer は activated タブを休眠集計しない")
  }

  func testLiveRollupCountsKnownStatesAndUsesCanonicalOrder() {
    let ws = Workspace(name: "live", rootPath: "/tmp")
    for state in ["idle", "done", "waiting", "working", "error"] {
      let tab = TerminalController()
      tab.recordMaterializationStarted()
      tab.controlAllPanes()[0].agentState = state
      ws.tabs.append(tab)
    }

    XCTAssertEqual(
      ws.agentCounts(), ["working": 1, "waiting": 1, "done": 1, "idle": 1],
      "unknown は live タブでも集計対象外")
    let ordered = AgentRollup.ordered(AgentRollup.grandTotal(of: [ws]))
    XCTAssertEqual(ordered.map(\.state), ["working", "waiting", "done", "idle"])
    XCTAssertEqual(ordered.map(\.count), [1, 1, 1, 1])
  }

  func testRemovingTabsImmediatelyRecomputesActivationAndDormantCount() {
    let active = Workspace(name: "front", rootPath: "/tmp")
    active.tabs = [TerminalController()]
    active.tabs[0].recordMaterializationStarted()

    let background = Workspace(name: "back", rootPath: "/tmp")
    let liveA = TerminalController()
    let liveB = TerminalController()
    liveA.recordMaterializationStarted()
    liveB.recordMaterializationStarted()
    let dormant = restoredTab(agentIds: ["sleeping"])
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
    let owned = restoredTab(agentIds: ["a"])
    ws.tabs = [owned]
    ws.lastUsedAt = Date(timeIntervalSinceReferenceDate: 789)
    let store = SessionStore(workspaces: [ws], activeWorkspace: 0)

    guard case .notFound = store.removeTab(TerminalController(), origin: .controlAPI) else {
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
      let live = TerminalController()
      live.recordMaterializationStarted()
      let dormant = restoredTab(agentIds: ["a"])
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
      let live = TerminalController()
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
