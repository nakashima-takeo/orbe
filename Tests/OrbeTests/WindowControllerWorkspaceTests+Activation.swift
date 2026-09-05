import AppKit
import XCTest

@testable import Orbe

extension WindowControllerWorkspaceTests {
  /// パレットは休眠復元 agent を live idle と混ぜず dormant チップで表す。
  func testPaletteShowsDormantRestoredAgentsAsDistinctKind() throws {
    func agentTab(_ id: String) -> TabState {
      TabState(
        cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: id),  // resume 未対応
        explicitTitle: nil)
    }
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        // 起動済み（アクティブ復元）。ordered で 0 件除外（agentState 空）→ rollup 空。
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [agentTab("m")]),
        // 休眠・agent 2つ → [("dormant", 2)]
        WorkspaceState(
          name: "sleepers", rootPath: "/tmp", activeTab: 0,
          tabs: [agentTab("a"), agentTab("b")]),
        // 休眠・agent 0 → rollup 無し
        WorkspaceState(
          name: "quiet", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())

    let wc = WindowController()
    wc.showWorkspacePalette()
    let items = try XCTUnwrap(wc.model.workspacePalette?.items)
    func rollup(of name: String) -> [(state: String, count: Int)]? {
      items.first { $0.name == name }.map(\.agentRollup).flatMap { $0.isEmpty ? nil : $0 }
    }

    let sleepers = try XCTUnwrap(rollup(of: "sleepers"), "休眠かつ agent>0 は rollup を持つ")
    XCTAssertEqual(sleepers.map { $0.state }, ["dormant"], "live idle と休眠復元由来を分ける")
    XCTAssertEqual(sleepers.map { $0.count }, [2], "永続 agent leaf の総数")

    XCTAssertNil(rollup(of: "quiet"), "休眠でも agent 0 件なら rollup を出さない")
    XCTAssertNil(rollup(of: "main"), "起動済みで agentState 0 件は 0 件除外で空")
    XCTAssertEqual(items.first { $0.name == "sleepers" }?.dormant, true)
    XCTAssertEqual(items.first { $0.name == "quiet" }?.dormant, true)
    XCTAssertEqual(items.first { $0.name == "main" }?.dormant, false)
  }

  /// 0 タブ workspace は前面にあっても休眠扱いで減光し、数えるものが無いので dormant チップは出さない。
  func testPaletteTreatsForegroundEmptyWorkspaceAsDormantWithoutChip() throws {
    WorkspacePersistence.save(
      WorkspacesFile(
        version: WorkspacePersistence.version, activeWorkspace: 0,
        workspaces: [
          WorkspaceState(name: "empty", rootPath: "/tmp", activeTab: 0, tabs: [])
        ]))
    let wc = WindowController()
    wc.showWorkspacePalette()
    let item = try XCTUnwrap(wc.model.workspacePalette?.items.first)
    XCTAssertTrue(item.isActive, "現在前面である")
    XCTAssertTrue(item.dormant, "起床済みタブは 0")
    XCTAssertTrue(item.agentRollup.isEmpty, "復元 agent も 0 なので chip は出さない")
  }

  /// mixed workspace では live 正準順の後ろに dormant を併記し、行全体は減光しない。
  func testPaletteShowsLiveAndDormantChipsTogetherInCanonicalOrder() throws {
    let dormantTabs = ["a", "b"].map {
      TabState(
        cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: $0), explicitTitle: nil)
    }
    let backgroundStamp = Date(timeIntervalSinceReferenceDate: 5_000)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "mixed", rootPath: "/tmp", activeTab: 0,
          tabs: dormantTabs, lastUsedAt: backgroundStamp),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    let mixed = try XCTUnwrap(wc.workspaces.first { $0.name == "mixed" })

    for state in ["working", "waiting", "done", "idle"] {
      let tabId = try XCTUnwrap(
        wc.controlSpawn(workspaceId: mixed.id, cwd: nil, command: nil))
      let tab = try XCTUnwrap(wc.controlResolveTab(tabId))
      setReportedState(tab, state)
    }

    wc.showWorkspacePalette()
    let item = try XCTUnwrap(wc.model.workspacePalette?.items.first { $0.name == "mixed" })
    XCTAssertFalse(item.dormant, "live タブが 1 枚でもあれば行は減光しない")
    XCTAssertEqual(
      item.agentRollup.map(\.state), ["working", "waiting", "done", "idle", "dormant"])
    XCTAssertEqual(item.agentRollup.map(\.count), [1, 1, 1, 1, 2])
    XCTAssertEqual(mixed.lastUsedAt, backgroundStamp, "背景 materialize は MRU を動かさない")
    XCTAssertEqual(mixed.tabs.filter(\.activated).count, 4)
    XCTAssertEqual(mixed.tabs.filter { !$0.activated }.count, 2)
  }
}
