import XCTest

@testable import Orbe

/// 前面化の段階的 materialize が壊れると、起動時に全 PTY が一旉起動したり、
/// workspace 切替後も古い mount ジョブが背景で走り続ける。
final class WindowControllerActivationLifecycleTests: OrbeTestCase {
  private func restoredAgentTab(_ id: String) -> TabState {
    TabState(
      tree: .leaf(
        cwd: nil, agent: AgentSession(command: "unknown", sessionId: id)),
      explicitTitle: nil)
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
    XCTAssertEqual(initialItem.dormant, false)
    XCTAssertEqual(initialItem.agentRollup.map(\.state), ["dormant"])
    XCTAssertEqual(initialItem.agentRollup.map(\.count), [2])

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
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)]),
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
}
