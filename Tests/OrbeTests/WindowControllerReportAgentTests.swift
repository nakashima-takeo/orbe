import AppKit
import XCTest

@testable import Orbe

/// `report_agent` の Attention 保持（stateChangedAt / 一過性イベント）の契約を固定する。
/// stateChangedAt は **state の値が実際に変わったときだけ** 動き、waiting/done への実変化だけが
/// transient を立てる。ここで測るのは打刻・clear での消去・done のフォーカス消費での保持・
/// ②を立てるかどうかの判断・一覧への投影。文言がどの報告で確定するかは分割した拡張ファイル
/// +Message が、再投影が配達されるか（②の取り下げ・split での追随）と②の滞留の尺は
/// +Reprojection が測る。
///
/// 重要: WindowControllerControlTests と同様、実 NSWindow に SurfaceView を接続するため
/// libghostty ランタイムを起動する（ヘッドレスな純ロジック検証ではない）。
final class WindowControllerReportAgentTests: OrbeTestCase {

  /// `makeKey` で前面化した窓。次のテスト（背面前提）へ key を持ち越さないため tearDown で下ろす。
  private var openedWindows: [NSWindow] = []
  override func tearDown() {
    openedWindows.forEach { $0.orderOut(nil) }
    openedWindows.removeAll()
    super.tearDown()
  }

  /// 1 workspace 1 タブで起動し、そのタブを返す。
  /// 分割した拡張ファイルからも使うため internal。
  func makeControllerAndTab() throws -> (WindowController, TerminalTab) {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.current.tabs.first)
    return (wc, tab)
  }

  /// 1 workspace 2 タブ（アクティブはタブ0＝見ているタブ）で起動し、
  /// タブ順に並べた各タブ（`tabs[i]` がタブ i）を返す。
  /// 分割した拡張ファイルからも使うため internal。
  func makeControllerAndTwoTabs() throws -> (WindowController, [TerminalTab]) {
    let tab = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [tab, tab])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    XCTAssertEqual(wc.current.tabs.count, 2)
    // 通知の可視性境界を測る fixture なので、hidden mount の queue 進行速度に依存せず
    // 両タブを lifecycle 上の live 側へ進める。workspace の setter は使わない。
    wc.current.tabs.forEach { $0.recordMaterializationStarted() }
    let tabs = try wc.current.tabs.map { try XCTUnwrap($0) }
    return (wc, tabs)
  }

  /// **両方とも activate 済み**の workspace 2 つで起動し、アクティブを 2 つ目へ移してから、
  /// workspace 順に並べた各先頭タブ（`tabs[i]` が workspace i）を返す。「発信元 workspace の
  /// 設定で鳴る」のように、発信元とアクティブが別であって初めて測れる契約のための足場。
  /// 分割した拡張ファイルからも使うため internal。
  func makeControllerAndTwoActivatedWorkspaces() throws -> (WindowController, [TerminalTab]) {
    let tab = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "origin", rootPath: "/tmp", activeTab: 0, tabs: [tab]),
        WorkspaceState(name: "active", rootPath: "/tmp", activeTab: 0, tabs: [tab]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    _ = wc.controlActivateWorkspace(workspaceId: try XCTUnwrap(wc.workspaces.last).id)
    XCTAssertTrue(wc.workspaces.allSatisfy(\.activated), "前提: どちらも activate 済み")
    let tabs = try wc.workspaces.map {
      try XCTUnwrap($0.tabs.first)
    }
    return (wc, tabs)
  }

  /// アクティブ workspace ＋ 休眠（このセッションで一度も activate していない）workspace で
  /// 起動し、休眠側の先頭タブを返す。
  /// 分割した拡張ファイルからも使うため internal。
  func makeControllerAndDormantTab() throws -> (WindowController, TerminalTab) {
    let tab = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [tab]),
        WorkspaceState(name: "dormant", rootPath: "/tmp", activeTab: 0, tabs: [tab]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    let dormant = try XCTUnwrap(wc.workspaces.last)
    XCTAssertFalse(dormant.activated, "前提: 復元直後の未切替 workspace は休眠")
    return (wc, try XCTUnwrap(dormant.tabs.first))
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
  /// 分割した拡張ファイル（+Sound）からも使うため internal。
  func makeKey(_ wc: WindowController) {
    NSApplication.shared.setActivationPolicy(.accessory)
    wc.window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    openedWindows.append(wc.window)
    pumpApp(upTo: 2, until: { wc.window.isKeyWindow })
    XCTAssertTrue(wc.window.isKeyWindow, "前提: ウィンドウが key にならない環境ではこの契約を測れない")
  }

  func testStateChangedAtMovesOnlyOnActualChange() throws {
    let (wc, tab) = try makeControllerAndTab()

    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "working"))
    let first = try XCTUnwrap(tab.agentReport?.stateChangedAt)

    // 同値の連続報告（working→working）では動かない。
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "working", sessionId: nil,
        message: AgentMessage(text: "m")))
    XCTAssertEqual(tab.agentReport?.stateChangedAt, first, "同値報告で stateChangedAt は動かない")

    // 実変化（working→waiting）で動く。
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "q")))
    let second = try XCTUnwrap(tab.agentReport?.stateChangedAt)
    XCTAssertNotEqual(second, first, "実変化で stateChangedAt が更新される")

    // 実変化を挟んだ後の同値報告（waiting→waiting）でも動かない＝打刻が drift しない。
    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "waiting"))
    XCTAssertEqual(tab.agentReport?.stateChangedAt, second, "実変化後の同値報告でも stateChangedAt は動かない")
  }

  func testClearResetsAllAttentionFields() throws {
    let (wc, tab) = try makeControllerAndTab()
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "done", sessionId: "s1",
        message: AgentMessage(text: "done!", source: "tool")))
    XCTAssertEqual(tab.agentReport?.message?.source, "tool", "前提: 消す対象が立っている")
    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "clear"))
    XCTAssertEqual(tab.agentSlot, .none, "clear で同一性ごと無へ戻る")
  }

  /// waiting / done への実変化だけが一過性イベント（メニューバー②）を立てる。
  func testTransientFiresOnlyOnWaitingOrDoneChange() throws {
    let (wc, tab) = try makeControllerAndTab()
    XCTAssertFalse(wc.window.isKeyWindow, "前提: 背面（非 key）なので見ているタブの抑制は効かない")

    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "working"))
    XCTAssertNil(wc.attentionStore.transient, "working への変化では立てない")

    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "q")))
    let transient = try XCTUnwrap(wc.attentionStore.transient)
    XCTAssertEqual(transient.row.tabId, tab.id)
    XCTAssertEqual(transient.row.state, "waiting")
    XCTAssertEqual(transient.row.message, "q")

    wc.attentionStore.transient = nil
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "q")))
    XCTAssertNil(wc.attentionStore.transient, "同値報告（変化なし）では立てない")

    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d")))
    XCTAssertEqual(wc.attentionStore.transient?.row.state, "done")
  }

  /// 見ているタブ（前面ウィンドウのアクティブ表示タブ）のタブでは②を立てない。
  /// 抑制されるのはピルだけで、一覧（rows）と done のフォーカス消費は従来どおり効く。
  func testTransientSuppressedOnVisibleTab() throws {
    let (wc, tab) = try makeControllerAndTab()
    makeKey(wc)

    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "q")))
    XCTAssertNil(wc.attentionStore.transient, "見ているタブの waiting ではピルを立てない")
    wc.flushChrome()
    XCTAssertEqual(wc.attentionStore.rows.map(\.tabId), [tab.id], "抑制するのはピルだけ（一覧は従来どおり）")
    XCTAssertEqual(wc.statusModel.rollup.map(\.state), ["waiting"])

    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "clear"))
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d")))
    XCTAssertNil(wc.attentionStore.transient, "見ているタブの done でもピルを立てない")
    XCTAssertEqual(tab.agentState, "idle", "done のフォーカス消費は従来どおり効く")
    wc.flushChrome()
    XCTAssertTrue(wc.attentionStore.rows.isEmpty)
    XCTAssertEqual(wc.statusModel.rollup.map(\.state), ["idle"])
  }

  /// 前面のままでも、見ていない別タブなら②は立つ。
  func testTransientFiresForBackgroundTabWhileKey() throws {
    let (wc, tabs) = try makeControllerAndTwoTabs()
    makeKey(wc)

    wc.controlReportAgent(
      tab: tabs[1],
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "q")))
    XCTAssertEqual(wc.attentionStore.transient?.row.tabId, tabs[1].id)
  }

  /// 抑制は「立てない」だけ。別の場所で起きた変化の既存ピルには触らない。
  func testSuppressionKeepsExistingTransient() throws {
    let (wc, tabs) = try makeControllerAndTwoTabs()
    makeKey(wc)

    wc.controlReportAgent(
      tab: tabs[1],
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "bg")))
    XCTAssertEqual(wc.attentionStore.transient?.row.tabId, tabs[1].id)

    wc.controlReportAgent(
      tab: tabs[0],
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "fg")))
    XCTAssertEqual(wc.attentionStore.transient?.row.tabId, tabs[1].id, "抑制は既存のピルを消さない")
  }

  /// done のフォーカス消費（done→idle）は stateChangedAt / message を触らない。
  func testConsumeDoneKeepsAttentionTimestamps() throws {
    let (wc, tab) = try makeControllerAndTab()
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d")))
    // 非 nil で拾う——Optional のまま比べると、report が打刻しなくなった退行が nil == nil で
    // 素通りして、このテストが名乗る契約が黙って検証されなくなる。
    let at = try XCTUnwrap(tab.agentReport?.stateChangedAt)
    wc.current.tabs[0].consumeDoneState()
    XCTAssertEqual(tab.agentState, "idle")
    XCTAssertEqual(tab.agentReport?.stateChangedAt, at)
    XCTAssertEqual(tab.agentReport?.message?.text, "d")
  }

  /// flushChrome が AttentionStore の snapshot を更新し、idle 化で一覧から消える。
  func testFlushChromeProjectsAttentionRows() throws {
    let (wc, tab) = try makeControllerAndTab()
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "q")))
    wc.flushChrome()
    XCTAssertEqual(wc.attentionStore.rows.map(\.tabId), [tab.id])

    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "clear"))
    wc.refreshChrome()
    wc.flushChrome()
    XCTAssertTrue(wc.attentionStore.rows.isEmpty)
  }
}
