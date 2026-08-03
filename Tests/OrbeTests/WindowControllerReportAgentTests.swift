import AppKit
import XCTest

@testable import Orbe

/// `report_agent` の Attention 保持（stateChangedAt / 一過性イベント）の契約を固定する。
/// stateChangedAt は **state の値が実際に変わったときだけ** 動き、waiting/done への実変化だけが
/// transient を立てる。ここで測るのは打刻・clear での消去・done のフォーカス消費での保持・
/// ②を立てるかどうかの判断・一覧への投影。文言がどの報告で確定するかは分割した拡張ファイル
/// +Message が、再投影が配達されるか（②の取り下げ・split での追随）は +Reprojection が測る。
///
/// 重要: WindowControllerControlTests と同様、実 NSWindow に SurfaceView を接続するため
/// libghostty ランタイムを起動する（ヘッドレスな純ロジック検証ではない）。
final class WindowControllerReportAgentTests: OrbeTestCase {

  private var tempStore: URL!
  /// `makeKey` で前面化した窓。次のテスト（背面前提）へ key を持ち越さないため tearDown で下ろす。
  private var openedWindows: [NSWindow] = []
  override func setUp() {
    super.setUp()
    tempStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-test-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tempStore
    SettingsPersistence.fileURLOverride = tempStore.appendingPathExtension("settings")
    AppStatePersistence.fileURLOverride = tempStore.appendingPathExtension("appstate")
  }
  override func tearDown() {
    openedWindows.forEach { $0.orderOut(nil) }
    openedWindows.removeAll()
    WorkspacePersistence.fileURLOverride = nil
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempStore)
    super.tearDown()
  }

  /// 1 workspace 1 タブで起動し、その先頭ペインを返す。
  /// 分割した拡張ファイルからも使うため internal。
  func makeControllerAndPane() throws -> (WindowController, SurfaceView) {
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

  /// 1 workspace 2 タブ（アクティブはタブ0＝見ているタブ）で起動し、
  /// タブ順に並べた各タブの先頭ペイン（`panes[i]` がタブ i）を返す。
  /// 分割した拡張ファイルからも使うため internal。
  func makeControllerAndTwoTabs() throws -> (WindowController, [SurfaceView]) {
    let tab = TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [tab, tab])
      ])
    try JSONEncoder().encode(file).write(to: tempStore)
    let wc = WindowController()
    XCTAssertEqual(wc.current.tabs.count, 2)
    let panes = try wc.current.tabs.map { try XCTUnwrap($0.controlAllPanes().first) }
    return (wc, panes)
  }

  /// アクティブ workspace ＋ 休眠（このセッションで一度も activate していない）workspace で
  /// 起動し、休眠側の先頭ペインを返す。
  /// 分割した拡張ファイルからも使うため internal。
  func makeControllerAndDormantPane() throws -> (WindowController, SurfaceView) {
    let tab = TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [tab]),
        WorkspaceState(name: "dormant", rootPath: "/tmp", activeTab: 0, tabs: [tab]),
      ])
    try JSONEncoder().encode(file).write(to: tempStore)
    let wc = WindowController()
    let dormant = try XCTUnwrap(wc.workspaces.last)
    XCTAssertFalse(dormant.activated, "前提: 復元直後の未切替 workspace は休眠")
    return (wc, try XCTUnwrap(dormant.tabs.first?.controlAllPanes().first))
  }

  /// AppKit のイベントを実際に取り出して配送し、`done` が真になるまで回す。活性化（`activate` → key 化）は
  /// WindowServer から届くイベントを NSApp が捌いて初めて成立するため、素の `RunLoop.run` では key にならない。
  /// `seconds` は上限。速い機械では待たず、詰まった共有ランナーでも取りこぼさない。
  private func pumpApp(upTo seconds: TimeInterval, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !done() {
      guard
        let event = NSApp.nextEvent(
          matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true)
      else { continue }
      NSApp.sendEvent(event)
    }
  }

  /// ウィンドウを実際に key（前面）にする。`isKeyWindow` を要求する契約を実経路で測るため。
  private func makeKey(_ wc: WindowController) {
    NSApplication.shared.setActivationPolicy(.accessory)
    wc.window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    openedWindows.append(wc.window)
    pumpApp(upTo: 2, until: { wc.window.isKeyWindow })
    XCTAssertTrue(wc.window.isKeyWindow, "前提: ウィンドウが key にならない環境ではこの契約を測れない")
  }

  func testStateChangedAtMovesOnlyOnActualChange() throws {
    let (wc, pane) = try makeControllerAndPane()

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    let first = try XCTUnwrap(pane.agentStateChangedAt)

    // 同値の連続報告（working→working）では動かない。
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil,
      message: AgentMessage(text: "m"))
    XCTAssertEqual(pane.agentStateChangedAt, first, "同値報告で stateChangedAt は動かない")

    // 実変化（working→waiting）で動く。
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    let second = try XCTUnwrap(pane.agentStateChangedAt)
    XCTAssertNotEqual(second, first, "実変化で stateChangedAt が更新される")

    // 実変化を挟んだ後の同値報告（waiting→waiting）でも動かない＝打刻が drift しない。
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertEqual(pane.agentStateChangedAt, second, "実変化後の同値報告でも stateChangedAt は動かない")
  }

  func testClearResetsAllAttentionFields() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "done", sessionId: "s1",
      message: AgentMessage(text: "done!", source: "tool"))
    XCTAssertEqual(pane.agentMessage?.source, "tool", "前提: 消す対象が立っている")
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
    XCTAssertFalse(wc.window.isKeyWindow, "前提: 背面（非 key）なので見ているタブの抑制は効かない")

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    XCTAssertNil(wc.attentionStore.transient, "working への変化では立てない")

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    let transient = try XCTUnwrap(wc.attentionStore.transient)
    XCTAssertEqual(transient.row.paneId, pane.id)
    XCTAssertEqual(transient.row.state, "waiting")
    XCTAssertEqual(transient.row.message, "q")

    wc.attentionStore.transient = nil
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    XCTAssertNil(wc.attentionStore.transient, "同値報告（変化なし）では立てない")

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d"))
    XCTAssertEqual(wc.attentionStore.transient?.row.state, "done")
  }

  /// 見ているタブ（前面ウィンドウのアクティブ表示タブ）のペインでは②を立てない。
  /// 抑制されるのはピルだけで、一覧（rows）と done のフォーカス消費は従来どおり効く。
  func testTransientSuppressedOnVisibleTab() throws {
    let (wc, pane) = try makeControllerAndPane()
    makeKey(wc)

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    XCTAssertNil(wc.attentionStore.transient, "見ているタブの waiting ではピルを立てない")
    wc.flushChrome()
    XCTAssertEqual(wc.attentionStore.rows.map(\.paneId), [pane.id], "抑制するのはピルだけ（一覧は従来どおり）")

    wc.controlReportAgent(pane: pane, agent: "claude", state: "clear", sessionId: nil, message: nil)
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d"))
    XCTAssertNil(wc.attentionStore.transient, "見ているタブの done でもピルを立てない")
    XCTAssertEqual(pane.agentState, "idle", "done のフォーカス消費は従来どおり効く")
  }

  /// 抑制の粒度はタブ。見ているタブの中なら、フォーカスしていない split の隣ペインでも②は立てない。
  func testTransientSuppressedOnSplitSiblingInVisibleTab() throws {
    let (wc, pane) = try makeControllerAndPane()
    makeKey(wc)
    let tab = wc.current.tabs[0]
    let sibling = try XCTUnwrap(tab.split(.horizontal, from: pane))
    XCTAssertFalse(sibling === tab.focusedPane, "前提: 隣ペインは非フォーカス（でなければタブ粒度を測れない）")

    wc.controlReportAgent(
      pane: sibling, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    XCTAssertNil(wc.attentionStore.transient, "見ているタブなら非フォーカスの隣ペインでもピルを立てない")
  }

  /// 前面のままでも、見ていない別タブのペインなら②は立つ。
  func testTransientFiresForBackgroundTabWhileKey() throws {
    let (wc, panes) = try makeControllerAndTwoTabs()
    makeKey(wc)

    wc.controlReportAgent(
      pane: panes[1], agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)
  }

  /// 抑制は「立てない」だけ。別の場所で起きた変化の既存ピルには触らない。
  func testSuppressionKeepsExistingTransient() throws {
    let (wc, panes) = try makeControllerAndTwoTabs()
    makeKey(wc)

    wc.controlReportAgent(
      pane: panes[1], agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "bg"))
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)

    wc.controlReportAgent(
      pane: panes[0], agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "fg"))
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id, "抑制は既存のピルを消さない")
  }

  /// done のフォーカス消費（done→idle）は stateChangedAt / message を触らない。
  func testConsumeDoneKeepsAttentionTimestamps() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d"))
    // 非 nil で拾う——Optional のまま比べると、report が打刻しなくなった退行が nil == nil で
    // 素通りして、このテストが名乗る契約が黙って検証されなくなる。
    let at = try XCTUnwrap(pane.agentStateChangedAt)
    wc.current.tabs[0].consumeDoneState()
    XCTAssertEqual(pane.agentState, "idle")
    XCTAssertEqual(pane.agentStateChangedAt, at)
    XCTAssertEqual(pane.agentMessage?.text, "d")
  }

  /// flushChrome が AttentionStore の snapshot を更新し、idle 化で一覧から消える。
  func testFlushChromeProjectsAttentionRows() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    wc.flushChrome()
    XCTAssertEqual(wc.attentionStore.rows.map(\.paneId), [pane.id])

    wc.controlReportAgent(pane: pane, agent: "claude", state: "clear", sessionId: nil, message: nil)
    wc.refreshChrome()
    wc.flushChrome()
    XCTAssertTrue(wc.attentionStore.rows.isEmpty)
  }
}
