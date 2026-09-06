import AppKit
import OrbeSessionLog
import XCTest

@testable import Orbe

/// 実 `WindowController` 越しに `agent-sessions.jsonl` へ何が書かれるかを固定する。
///
/// 壊れると何が起きるか: 行に workspace 名・rootPath・cwd が載らなければ `restore_sessions` と
/// ⇧⌘T が復元先を失う。closed にタブのタイトルが載らなければ人が ⇧⌘T の行を見分けられない。
/// 起動時の剪定が動かなければログが際限なく育つ。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerSessionLogTests: OrbeTestCase {
  private func restore(_ workspaces: [WorkspaceState], activeWorkspace: Int = 0) throws
    -> WindowController
  {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: activeWorkspace,
      workspaces: workspaces)
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  private func plain(_ name: String, rootPath: String = "/tmp", tabs: Int = 1) -> WorkspaceState {
    WorkspaceState(
      name: name, rootPath: rootPath, activeTab: 0,
      tabs: (0..<tabs).map { _ in TabState(cwd: "/tmp", agent: nil, explicitTitle: nil) })
  }

  private func fileEvents() throws -> [SessionEvent] {
    try SessionLogReader.read(XCTUnwrap(AgentSessionLog.fileURL)).events
  }

  func testReportAndGestureCloseWriteOpenedThenClosedWithWorkspaceAndCwd() throws {
    let wc = try restore([plain("main", rootPath: "/tmp/root")])
    let tab = try XCTUnwrap(wc.current.tabs.first)
    tab.surface.currentPwd = "/tmp/root/src"

    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    wc.closeTab(tab, origin: .gesture)

    let events = try fileEvents()
    XCTAssertEqual(
      events.map(\.kind),
      [
        .opened,
        .closed(
          origin: .gesture, reason: nil,
          title: TabTitle.derive(pwd: "/tmp/root/src", root: "/tmp/root")),
      ], "closed には閉じた時点の表示タイトル（ここでは cwd の派生）が載り、opened には載らない")
    XCTAssertEqual(
      events.map(\.workspace),
      Array(repeating: .init(name: "main", rootPath: "/tmp/root"), count: 2))
    XCTAssertEqual(events.map(\.cwd), ["/tmp/root/src", "/tmp/root/src"])
    XCTAssertEqual(
      events.map(\.agent), Array(repeating: .init(command: "claude", sessionId: "s-1"), count: 2))
    XCTAssertEqual(wc.sessionLog.events, events, "メモリとファイルは同じものを見る")
  }

  func testClosedCarriesTheExplicitTitleWhenTheTabHasOne() throws {
    let wc = try restore([plain("main", rootPath: "/tmp/root")])
    let tab = try XCTUnwrap(wc.current.tabs.first)
    tab.explicitTitle = "release notes"
    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))

    wc.closeTab(tab, origin: .gesture)

    XCTAssertEqual(try fileEvents().last?.closeTitle, "release notes", "タブバーに出ていた語がそのまま載る")
  }

  func testRemoveWorkspaceViaControlClosesAsControlAPI() throws {
    let wc = try restore([plain("main"), plain("doomed")])
    let tab = try XCTUnwrap(wc.workspaces[1].tabs.first)
    tab.applyReport(AgentHookReport(agent: "codex", state: "idle", sessionId: "c-1"))
    let doomedId = wc.workspaces[1].id

    guard case .success = wc.controlRemoveWorkspace(workspaceId: doomedId) else {
      return XCTFail("remove_workspace は success")
    }

    XCTAssertEqual(wc.sessionLog.lastEvent(sessionId: "c-1")?.closeOrigin, .controlAPI)
    XCTAssertEqual(wc.sessionLog.lastEvent(sessionId: "c-1")?.workspace.name, "doomed")
  }

  func testClosingATabWhoseIdentityAlreadyEndedWritesNothing() throws {
    let wc = try restore([plain("main", tabs: 2)])
    let tab = try XCTUnwrap(wc.current.tabs.first)
    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "clear", sessionId: nil, message: nil, reason: "clear"))
    XCTAssertEqual(try fileEvents().count, 2)

    wc.closeTab(tab, origin: .gesture)
    XCTAssertEqual(try fileEvents().count, 2, "終わった同一性のタブを閉じても行は増えない")
    XCTAssertEqual(try fileEvents().last?.closeReason, "clear", "hook の reason が載る")
  }

  func testRestoringDormantTicketsWritesNothingUntilTheyWake() throws {
    let ticket = TabState(
      cwd: "/tmp", agent: AgentSession(command: "claude", sessionId: "d-1"), explicitTitle: nil)
    let unknown = TabState(
      cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: "u-1"), explicitTitle: nil)
    let wc = try restore(
      [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [ticket, unknown]),
        plain("bg"),
      ], activeWorkspace: 1)
    XCTAssertEqual(try fileEvents(), [], "復元では書かない（休眠チケットを足すだけ）")

    wc.switchWorkspace(to: 0)  // 起床: 先頭は同期 mount・2 枚目は次 tick の分割 mount
    XCTAssertEqual(wc.sessionLog.lastEvent(sessionId: "d-1")?.kind, .opened, "resume が解けたら opened")
    let drained = expectation(description: "hidden mount")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1)
    XCTAssertEqual(
      wc.sessionLog.lastEvent(sessionId: "u-1")?.closeOrigin, .unresolved,
      "resume を解決できなければ unresolved で終わる")
  }

  func testDeletingAWorkspaceFromThePaletteClosesAsGesture() throws {
    let wc = try restore([plain("main"), plain("doomed")])
    let tab = try XCTUnwrap(wc.workspaces[1].tabs.first)
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "g-1"))

    wc.showWorkspacePalette()
    try XCTUnwrap(wc.model.workspacePalette).onClose?(1)

    XCTAssertEqual(wc.workspaces.map(\.name), ["main"])
    XCTAssertEqual(
      wc.sessionLog.lastEvent(sessionId: "g-1")?.closeOrigin, .gesture,
      "パレットからの削除は人の操作＝gesture")
  }

  func testUnwritableLogDoesNotStopTabOperations() throws {
    let dead = try XCTUnwrap(TestIsolation.caseDir)
      .appendingPathComponent("missing", isDirectory: true)
      .appendingPathComponent("agent-sessions.jsonl")
    AgentSessionLog.fileURLOverride = dead
    let wc = try restore([plain("main", tabs: 2)])
    let tab = try XCTUnwrap(wc.current.tabs.first)

    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    wc.closeTab(tab, origin: .gesture)

    XCTAssertEqual(wc.current.tabs.count, 1, "書けなくてもタブは閉じる")
    XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
    XCTAssertEqual(
      wc.sessionLog.events.map(\.closeOrigin), [nil, .gesture], "メモリの記録は続く")
    wc.showClosedAgentsPalette()
    XCTAssertEqual(
      wc.model.closedAgentsPalette?.items.map(\.sessionId), ["s-1"], "⇧⌘T はメモリから出せる")
  }

  func testInitPrunesOldRowsAndRewritesAtomically() throws {
    let url = try XCTUnwrap(AgentSessionLog.fileURL)
    let old = SessionEvent(
      ts: Date().addingTimeInterval(-40 * 86400), kind: .opened,
      workspace: .init(name: "w", rootPath: "/tmp"), cwd: "/tmp",
      agent: .init(command: "claude", sessionId: "old"))
    let recent = SessionEvent(
      ts: Date().addingTimeInterval(-60), kind: .opened,
      workspace: .init(name: "w", rootPath: "/tmp"), cwd: "/tmp",
      agent: .init(command: "claude", sessionId: "recent"))
    try SessionLogWriter.append(old, to: url)
    try SessionLogWriter.append(recent, to: url)

    let log = AgentSessionLog()

    XCTAssertEqual(log.events, [recent])
    XCTAssertEqual(try SessionLogReader.read(url).events, [recent], "30 日より古い行はファイルからも落ちる")
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path)
    XCTAssertFalse(
      siblings.contains { $0.hasPrefix(url.lastPathComponent + ".tmp") }, "一時ファイルを残さない")
  }

  func testInitWithoutChangesDoesNotRewrite() throws {
    let url = try XCTUnwrap(AgentSessionLog.fileURL)
    let recent = SessionEvent(
      ts: Date().addingTimeInterval(-60), kind: .opened,
      workspace: .init(name: "w", rootPath: "/tmp"), cwd: "/tmp",
      agent: .init(command: "claude", sessionId: "recent"))
    try SessionLogWriter.append(recent, to: url)
    let before =
      try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    Thread.sleep(forTimeInterval: 0.02)

    _ = AgentSessionLog()

    let after =
      try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    XCTAssertEqual(before, after, "落ちるものが無ければ書き直さない")
  }
}
