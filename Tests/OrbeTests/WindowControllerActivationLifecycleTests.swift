import XCTest

@testable import Orbe

/// 前面化の段階的 materialize が壊れると、起動時に全 PTY が一斉起動したり、
/// workspace 切替後も古い mount ジョブが背景で走り続ける。
final class WindowControllerActivationLifecycleTests: OrbeTestCase {
  private func restoredAgentTab(_ id: String) -> TabState {
    TabState(
      cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: id), explicitTitle: nil)
  }

  private func save(activeWorkspace: Int, workspaces: [WorkspaceState]) {
    WorkspacePersistence.save(
      WorkspacesFile(
        version: WorkspacePersistence.version, activeWorkspace: activeWorkspace,
        workspaces: workspaces))
  }

  private func observeAfterAlreadyQueuedJobs(_ body: @escaping () -> Void) {
    let exp = expectation(description: "main queue sentinel")
    DispatchQueue.main.async {
      body()
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
  }

  func testForegroundActivationMaterializesSelectedTabSynchronouslyThenOneHiddenTabPerTurn() throws
  {
    save(
      activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [restoredAgentTab("a"), restoredAgentTab("b"), restoredAgentTab("c")])
      ])

    let wc = WindowController()
    XCTAssertEqual(wc.current.tabs.map(\.activated), [true, false, false])
    XCTAssertEqual(wc.current.dormantAgentCount(), 2)
    let control = try XCTUnwrap(wc.controlListWorkspaces().first)
    XCTAssertEqual(control["active"] as? Bool, true)
    XCTAssertEqual(control["activated"] as? Bool, true)
    XCTAssertEqual(control["dormantAgentCount"] as? Int, 2)
    wc.showWorkspacePalette()
    let initialItem = try XCTUnwrap(wc.model.workspacePalette?.items.first)
    XCTAssertEqual(initialItem.live.dormant, false)
    XCTAssertEqual(initialItem.live.rollup.map(\.state), ["dormant"])
    XCTAssertEqual(initialItem.live.rollup.map(\.count), [2])

    var firstSentinel: [Bool] = []
    var dormantAtFirstSentinel = -1
    observeAfterAlreadyQueuedJobs {
      firstSentinel = wc.current.tabs.map(\.activated)
      dormantAtFirstSentinel = wc.current.dormantAgentCount()
    }
    XCTAssertEqual(firstSentinel, [true, true, false], "hidden タブを 1 turn に一括起床しない")
    XCTAssertEqual(dormantAtFirstSentinel, 1)

    observeAfterAlreadyQueuedJobs {}
    XCTAssertEqual(wc.current.tabs.map(\.activated), [true, true, true])
    XCTAssertEqual(wc.current.dormantAgentCount(), 0)
  }

  func testSwitchingWorkspaceCancelsOldHiddenMountsAndReturningResumesDormantTabs() {
    save(
      activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "old", rootPath: "/tmp", activeTab: 0,
          tabs: [restoredAgentTab("a"), restoredAgentTab("b"), restoredAgentTab("c")]),
        WorkspaceState(
          name: "new", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
      ])
    let wc = WindowController()
    let old = wc.workspaces[0]
    XCTAssertEqual(old.tabs.map(\.activated), [true, false, false])

    wc.switchWorkspace(to: 1)
    observeAfterAlreadyQueuedJobs {}
    XCTAssertEqual(old.tabs.map(\.activated), [true, false, false], "世代が古い hidden mount は中断する")
    XCTAssertEqual(old.dormantAgentCount(), 2)

    wc.switchWorkspace(to: 0)
    observeAfterAlreadyQueuedJobs {}
    observeAfterAlreadyQueuedJobs {}
    XCTAssertTrue(old.tabs.allSatisfy(\.activated), "再前面化で残る dormant だけを起こす")
    XCTAssertEqual(old.dormantAgentCount(), 0)
  }

  func testForegroundNewTabAdvancesMRUAndStartsActivated() throws {
    let wc = WindowController()
    let old = Date(timeIntervalSinceReferenceDate: 1)
    wc.current.lastUsedAt = old
    let count = wc.current.tabs.count

    wc.newTab()

    XCTAssertEqual(wc.current.tabs.count, count + 1)
    XCTAssertTrue(try XCTUnwrap(wc.current.tabs.last).activated)
    XCTAssertTrue(wc.current.activated)
    XCTAssertGreaterThan(try XCTUnwrap(wc.current.lastUsedAt), old)
  }

  func testActivationBitsAreNotPersisted() throws {
    let wc = WindowController()
    XCTAssertTrue(wc.current.activated)
    wc.flushSave()

    let data = try Data(contentsOf: workspacesFile())
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]])
    XCTAssertFalse(workspaces.isEmpty)
    for workspace in workspaces {
      XCTAssertNil(workspace["activated"])
      let tabs = try XCTUnwrap(workspace["tabs"] as? [[String: Any]])
      for tab in tabs { XCTAssertNil(tab["activated"]) }
    }
  }

  /// 休眠チケットの消費（隠れタブの段階的 materialize）は、パレットを開いたままでも行チップへ届く。
  /// 届かないと「もう起きているのに休眠件数が残ったまま」の行を見て workspace を選ぶことになる。
  func testHiddenMountTicketConsumptionReachesOpenWorkspacePaletteRow() throws {
    save(
      activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [restoredAgentTab("a"), restoredAgentTab("b"), restoredAgentTab("c")])
      ])
    let wc = WindowController()
    wc.showWorkspacePalette()
    func rollup() throws -> [(state: String, count: Int)] {
      try XCTUnwrap(wc.model.workspacePalette?.items.first).live.rollup
    }
    XCTAssertEqual(try rollup().map(\.state), ["dormant"])
    XCTAssertEqual(try rollup().map(\.count), [2], "前提: 未消費の復元チケット 2 枚")

    observeAfterAlreadyQueuedJobs {}
    wc.flushChrome()
    XCTAssertEqual(try rollup().map(\.count), [1], "1 枚起きた分だけ休眠件数が減る")

    observeAfterAlreadyQueuedJobs {}
    wc.flushChrome()
    XCTAssertTrue(try rollup().isEmpty, "全て消費された休眠チップは消える")
    XCTAssertEqual(wc.model.overlay, .workspacePalette, "追随のためにパレットを閉じない")
  }
}
