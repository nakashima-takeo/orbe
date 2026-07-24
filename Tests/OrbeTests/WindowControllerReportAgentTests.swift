import AppKit
import XCTest

@testable import Orbe

/// `report_agent` の Attention 保持（message / stateChangedAt / 一過性イベント）の契約を固定する。
/// stateChangedAt は **state の値が実際に変わったときだけ** 動き、message は clear 以外の報告で
/// 常に上書きされる（省略＝nil に落とす）。waiting/done への実変化だけが transient を立てる。
///
/// 重要: WindowControllerControlTests と同様、実 NSWindow に SurfaceView を接続するため
/// libghostty ランタイムを起動する（ヘッドレスな純ロジック検証ではない）。
final class WindowControllerReportAgentTests: XCTestCase {

  private var tempStore: URL!
  override func setUp() {
    super.setUp()
    tempStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-test-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tempStore
    SettingsPersistence.fileURLOverride = tempStore.appendingPathExtension("settings")
    AppStatePersistence.fileURLOverride = tempStore.appendingPathExtension("appstate")
  }
  override func tearDown() {
    WorkspacePersistence.fileURLOverride = nil
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempStore)
    super.tearDown()
  }

  /// 1 workspace 1 タブで起動し、その先頭ペインを返す。
  private func makeControllerAndPane() throws -> (WindowController, SurfaceView) {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: tempStore)
    let wc = WindowController()
    let pane = try XCTUnwrap(wc.current.tabs.first?.controlAllPanes().first)
    return (wc, pane)
  }

  func testStateChangedAtMovesOnlyOnActualChange() throws {
    let (wc, pane) = try makeControllerAndPane()

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    let first = try XCTUnwrap(pane.agentStateChangedAt)

    // 同値の連続報告（working→working）では動かない。message は上書きされる。
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: "m")
    XCTAssertEqual(pane.agentStateChangedAt, first, "同値報告で stateChangedAt は動かない")
    XCTAssertEqual(pane.agentMessage, "m")

    // 実変化（working→waiting）で動く。
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    let second = try XCTUnwrap(pane.agentStateChangedAt)
    XCTAssertNotEqual(second, first, "実変化で stateChangedAt が更新される")
    XCTAssertEqual(pane.agentMessage, "q")

    // message 省略の報告は nil に落とす（stale な質問文を残さない）。
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertNil(pane.agentMessage)
    XCTAssertEqual(pane.agentStateChangedAt, second, "同値報告で stateChangedAt は動かない")
  }

  func testClearResetsAllAttentionFields() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "done", sessionId: "s1", message: "done!")
    wc.controlReportAgent(pane: pane, agent: "claude", state: "clear", sessionId: nil, message: nil)
    XCTAssertNil(pane.agentState)
    XCTAssertNil(pane.agentSessionId)
    XCTAssertNil(pane.agentCommand)
    XCTAssertNil(pane.agentMessage)
    XCTAssertNil(pane.agentStateChangedAt)
  }

  /// waiting / done への実変化だけが一過性イベント（メニューバー②）を立てる。
  func testTransientFiresOnlyOnWaitingOrDoneChange() throws {
    let (wc, pane) = try makeControllerAndPane()

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    XCTAssertNil(wc.attentionStore.transient, "working への変化では立てない")

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    let transient = try XCTUnwrap(wc.attentionStore.transient)
    XCTAssertEqual(transient.row.paneId, pane.id)
    XCTAssertEqual(transient.row.state, "waiting")
    XCTAssertEqual(transient.row.message, "q")

    wc.attentionStore.transient = nil
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    XCTAssertNil(wc.attentionStore.transient, "同値報告（変化なし）では立てない")

    wc.controlReportAgent(pane: pane, agent: "claude", state: "done", sessionId: nil, message: "d")
    XCTAssertEqual(wc.attentionStore.transient?.row.state, "done")
  }

  /// done のフォーカス消費（done→idle）は stateChangedAt / message を触らない。
  func testConsumeDoneKeepsAttentionTimestamps() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(pane: pane, agent: "claude", state: "done", sessionId: nil, message: "d")
    let at = pane.agentStateChangedAt
    wc.current.tabs[0].consumeDoneState()
    XCTAssertEqual(pane.agentState, "idle")
    XCTAssertEqual(pane.agentStateChangedAt, at)
    XCTAssertEqual(pane.agentMessage, "d")
  }

  /// flushChrome が AttentionStore の snapshot を更新し、idle 化で一覧から消える。
  func testFlushChromeProjectsAttentionRows() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    wc.flushChrome()
    XCTAssertEqual(wc.attentionStore.rows.map(\.paneId), [pane.id])

    wc.controlReportAgent(pane: pane, agent: "claude", state: "clear", sessionId: nil, message: nil)
    wc.refreshChrome()
    wc.flushChrome()
    XCTAssertTrue(wc.attentionStore.rows.isEmpty)
  }
}
