import OrbeSound
import XCTest

@testable import Orbe

private struct MixedBackgroundFixture {
  let wc: WindowController
  let workspace: Workspace
  let live: TerminalTab
  let dormant: TerminalTab
}

/// 背景 workspace が live / dormant タブ混在になったときの投影。注意喚起と常時集計が workspace 全体
/// ではなく発信元タブの現在状態に従うこと、および表示中の workspace パレット行が chrome ストリップと
/// 同じ契機で実状態へ追随することを固定する。
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
    XCTAssertTrue(item.live.dormant)
    XCTAssertEqual(item.live.rollup.map(\.state), ["dormant"])
    XCTAssertEqual(item.live.rollup.map(\.count), [1])
  }

  /// 表示中の workspace パレットの行チップは、chrome ストリップと同じ契機で実状態へ追随する
  /// （開き直さなくても報告・リセットが届く）。
  func testOpenWorkspacePaletteFollowsAgentStateChanges() throws {
    let fixture = try makeControllerAndMixedBackground()
    let wc = fixture.wc
    wc.showWorkspacePalette()
    let index = try XCTUnwrap(wc.workspaces.firstIndex { $0 === fixture.workspace })
    func live() throws -> WorkspacePaletteModel.LiveState {
      try XCTUnwrap(wc.model.workspacePalette?.items.first { $0.index == index }).live
    }
    XCTAssertEqual(try live().rollup.map(\.state), ["dormant"], "前提: 開いた時点は休眠チケットのみ")

    wc.controlReportAgent(
      tab: fixture.live, agent: "claude", state: "working", sessionId: nil, message: nil)
    wc.flushChrome()
    XCTAssertEqual(try live().rollup.map(\.state), ["working", "dormant"])
    XCTAssertEqual(try live().rollup.map(\.count), [1, 1])

    fixture.live.resetAgentState()
    wc.flushChrome()
    XCTAssertEqual(
      try live().rollup.map(\.state), ["idle", "dormant"], "リセットは working を idle へ落とす")
    XCTAssertEqual(wc.model.overlay, .workspacePalette, "追随のためにパレットを閉じない")
  }

  /// 素シェルの背景 materialize は `agentSlot` を動かさないため、materialize 自身が chrome 更新を
  /// 要求しないと表示中パレットの減光が解けない（契機の穴）。
  func testBackgroundPlainShellSpawnLiftsRowDimmingWhilePaletteIsOpen() throws {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "sleeping", rootPath: "/tmp", activeTab: 0,
          tabs: [
            TabState(
              cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: "s"),
              explicitTitle: nil)
          ]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    let sleeping = try XCTUnwrap(wc.workspaces.first { $0.name == "sleeping" })
    wc.showWorkspacePalette()
    let index = try XCTUnwrap(wc.workspaces.firstIndex { $0 === sleeping })
    func live() throws -> WorkspacePaletteModel.LiveState {
      try XCTUnwrap(wc.model.workspacePalette?.items.first { $0.index == index }).live
    }
    XCTAssertTrue(try live().dormant, "前提: 配下のタブを一度も起こしていない")
    wc.flushChrome()  // 以降の追随が spawn 自身の chrome 要求だけで起きることを見るため dirty を落とす

    XCTAssertNotNil(wc.controlSpawn(workspaceId: sleeping.id, cwd: nil, command: nil))
    wc.flushChrome()

    XCTAssertFalse(try live().dormant, "素シェル 1 枚の起床で行の減光が解ける")
    XCTAssertEqual(try live().rollup.map(\.state), ["dormant"], "未消費チケットは残る")
  }

  /// 表示中の追随は現在値だけの差し替えで、構造の再読込ではない。詳細メニューへ潜っている間に
  /// 報告が届いても一覧へ引き戻さず（＝選んだ対象と打ちかけの操作を奪わず）、戻ると最新のチップが出る。
  func testOpenWorkspacePaletteSubmenuSurvivesAgentStateChange() throws {
    let fixture = try makeControllerAndMixedBackground()
    let wc = fixture.wc
    wc.showWorkspacePalette()
    let palette = try XCTUnwrap(wc.model.workspacePalette)
    let index = try XCTUnwrap(wc.workspaces.firstIndex { $0 === fixture.workspace })
    palette.render.onDown()  // 起源 "main" の次＝背景の "mixed" 行
    XCTAssertTrue(palette.render.onRight(), "詳細メニューへ潜る")
    XCTAssertEqual(palette.render.breadcrumb, "‹ mixed")

    wc.controlReportAgent(
      tab: fixture.live, agent: "claude", state: "working", sessionId: nil, message: nil)
    wc.flushChrome()

    XCTAssertEqual(palette.render.breadcrumb, "‹ mixed", "追随は詳細メニューから引き戻さない")

    palette.goBack()  // ← で一覧へ
    let item = try XCTUnwrap(palette.items.first { $0.index == index })
    XCTAssertEqual(
      item.live.rollup.map(\.state), ["working", "dormant"], "戻った一覧に最新のチップが出る")
  }
}
