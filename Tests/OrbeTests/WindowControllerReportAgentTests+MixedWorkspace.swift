import OrbeSound
import XCTest

@testable import Orbe

private struct MixedBackgroundFixture {
  let wc: WindowController
  let workspace: Workspace
  let live: TerminalTab
  let dormant: TerminalTab
}

/// 背景 workspace が live / dormant タブ混在になったとき、注意喚起と常時集計が
/// workspace 全体ではなく発信元タブの現在状態に従うことを固定する。
extension WindowControllerReportAgentTests {
  private func makeControllerAndMixedBackground() throws -> MixedBackgroundFixture {
    let dormantAgent = TabState(
      cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: "sleeping"),
      explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "mixed", rootPath: "/tmp", activeTab: 0,
          tabs: [dormantAgent]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    let workspace = try XCTUnwrap(wc.workspaces.first { $0.name == "mixed" })
    let dormant = try XCTUnwrap(workspace.tabs.first)
    workspace.lastUsedAt = Date(timeIntervalSinceReferenceDate: 9_000)
    let tabId = try XCTUnwrap(
      wc.controlSpawn(workspaceId: workspace.id, cwd: nil, command: nil))
    let live = try XCTUnwrap(wc.controlResolveTab(tabId))

    XCTAssertFalse(wc.current === workspace)
    XCTAssertTrue(workspace.activated)
    XCTAssertEqual(workspace.tabs.filter(\.activated).count, 1)
    XCTAssertEqual(workspace.tabs.filter { !$0.activated }.count, 1)
    XCTAssertEqual(workspace.dormantAgentCount(), 1)
    return MixedBackgroundFixture(wc: wc, workspace: workspace, live: live, dormant: dormant)
  }

  func testBackgroundMixedWaitingReachesAttentionTransientSoundAndTopBar() throws {
    let fixture = try makeControllerAndMixedBackground()
    let activeBefore = fixture.wc.current
    let stampBefore = fixture.workspace.lastUsedAt
    let sound = try XCTUnwrap(fixture.wc.soundPlayer as? SoundPlayerFake)

    fixture.wc.controlReportAgent(
      tab: fixture.live, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "question"))
    fixture.wc.flushChrome()

    XCTAssertEqual(fixture.wc.attentionStore.rows.map(\.tabId), [fixture.live.id])
    XCTAssertEqual(fixture.wc.attentionStore.transient?.row.tabId, fixture.live.id)
    XCTAssertEqual(sound.played.last?.event, .waiting)
    XCTAssertEqual(fixture.wc.statusModel.rollup.map(\.state), ["waiting"])
    XCTAssertEqual(fixture.wc.statusModel.rollup.map(\.count), [1])
    XCTAssertTrue(
      fixture.wc.statusModel.glyphs.allSatisfy { $0 == nil },
      "背景 workspace の live は横断 rollup には入るが、現在 workspace のタブ列には漏らさない")
    XCTAssertTrue(fixture.wc.current === activeBefore, "背景報告で前面 workspace を奪わない")
    XCTAssertEqual(fixture.workspace.lastUsedAt, stampBefore, "背景 materialize/report で MRU を動かさない")
  }

  func testBackgroundMixedDoneReachesAttentionTransientSoundAndTopBar() throws {
    let fixture = try makeControllerAndMixedBackground()
    let sound = try XCTUnwrap(fixture.wc.soundPlayer as? SoundPlayerFake)

    fixture.wc.controlReportAgent(
      tab: fixture.live, agent: "claude", state: "done", sessionId: nil,
      message: AgentMessage(text: "finished"))
    fixture.wc.flushChrome()

    XCTAssertEqual(fixture.wc.attentionStore.rows.map(\.state), ["done"])
    XCTAssertEqual(fixture.wc.attentionStore.transient?.row.state, "done")
    XCTAssertEqual(sound.played.last?.event, .done)
    XCTAssertEqual(fixture.wc.statusModel.rollup.map(\.state), ["done"])
    XCTAssertEqual(fixture.workspace.dormantAgentCount(), 1)
  }

  func testDormantSiblingReportIsExcludedFromEveryLiveProjection() throws {
    let fixture = try makeControllerAndMixedBackground()
    let sound = try XCTUnwrap(fixture.wc.soundPlayer as? SoundPlayerFake)

    fixture.wc.controlReportAgent(
      tab: fixture.dormant, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "synthetic"))
    fixture.wc.flushChrome()

    XCTAssertTrue(fixture.workspace.activated, "live sibling があるので workspace 自体は true")
    XCTAssertFalse(fixture.workspace.tabs[0].activated, "発信元の復元タブは未起動")
    XCTAssertTrue(fixture.wc.attentionStore.rows.isEmpty)
    XCTAssertNil(fixture.wc.attentionStore.transient)
    XCTAssertTrue(sound.played.isEmpty)
    XCTAssertTrue(fixture.wc.statusModel.rollup.isEmpty)
  }

  func testClosingLastLiveBackgroundTabRetractsAttentionAndReturnsWorkspaceToDormant() throws {
    let fixture = try makeControllerAndMixedBackground()
    let stampBefore = fixture.workspace.lastUsedAt
    fixture.wc.controlReportAgent(
      tab: fixture.live, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "question"))
    fixture.wc.flushChrome()
    let liveTab = try XCTUnwrap(fixture.workspace.tabs.first { $0.activated })

    fixture.wc.closeTab(liveTab, origin: .controlAPI)
    fixture.wc.flushChrome()

    XCTAssertFalse(fixture.workspace.activated)
    XCTAssertEqual(fixture.workspace.tabs.count, 1)
    XCTAssertEqual(fixture.workspace.dormantAgentCount(), 1)
    XCTAssertTrue(fixture.wc.attentionStore.rows.isEmpty)
    XCTAssertTrue(fixture.wc.statusModel.rollup.isEmpty)
    XCTAssertEqual(fixture.wc.attentionStore.transient?.retracted, true)
    XCTAssertEqual(fixture.workspace.lastUsedAt, stampBefore)
    let row = try XCTUnwrap(
      fixture.wc.controlListWorkspaces().first { $0["id"] as? Int == fixture.workspace.id })
    XCTAssertEqual(row["activated"] as? Bool, false)
    XCTAssertEqual(row["dormantAgentCount"] as? Int, 1)
    fixture.wc.showWorkspacePalette()
    let workspaceIndex = try XCTUnwrap(
      fixture.wc.workspaces.firstIndex { $0 === fixture.workspace })
    let item = try XCTUnwrap(
      fixture.wc.model.workspacePalette?.items.first { $0.index == workspaceIndex })
    XCTAssertTrue(item.dormant)
    XCTAssertEqual(item.agentRollup.map(\.state), ["dormant"])
    XCTAssertEqual(item.agentRollup.map(\.count), [1])
  }
}
