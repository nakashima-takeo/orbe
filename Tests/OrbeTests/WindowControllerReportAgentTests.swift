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

  /// 1 workspace 2 タブ（アクティブはタブ0＝見ているタブ）で起動し、
  /// タブ順に並べた各タブの先頭ペイン（`panes[i]` がタブ i）を返す。
  private func makeControllerAndTwoTabs() throws -> (WindowController, [SurfaceView]) {
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
  private func makeControllerAndDormantPane() throws -> (WindowController, SurfaceView) {
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
    XCTAssertFalse(wc.window.isKeyWindow, "前提: 背面（非 key）なので見ているタブの抑制は効かない")

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

  /// 見ているタブ（前面ウィンドウのアクティブ表示タブ）のペインでは②を立てない。
  /// 抑制されるのはピルだけで、一覧（rows）と done のフォーカス消費は従来どおり効く。
  func testTransientSuppressedOnVisibleTab() throws {
    let (wc, pane) = try makeControllerAndPane()
    makeKey(wc)

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    XCTAssertNil(wc.attentionStore.transient, "見ているタブの waiting ではピルを立てない")
    wc.flushChrome()
    XCTAssertEqual(wc.attentionStore.rows.map(\.paneId), [pane.id], "抑制するのはピルだけ（一覧は従来どおり）")

    wc.controlReportAgent(pane: pane, agent: "claude", state: "clear", sessionId: nil, message: nil)
    wc.controlReportAgent(pane: pane, agent: "claude", state: "done", sessionId: nil, message: "d")
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
      pane: sibling, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    XCTAssertNil(wc.attentionStore.transient, "見ているタブなら非フォーカスの隣ペインでもピルを立てない")
  }

  /// 前面のままでも、見ていない別タブのペインなら②は立つ。
  func testTransientFiresForBackgroundTabWhileKey() throws {
    let (wc, panes) = try makeControllerAndTwoTabs()
    makeKey(wc)

    wc.controlReportAgent(
      pane: panes[1], agent: "claude", state: "waiting", sessionId: nil, message: "q")
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)
  }

  /// 抑制は「立てない」だけ。別の場所で起きた変化の既存ピルには触らない。
  func testSuppressionKeepsExistingTransient() throws {
    let (wc, panes) = try makeControllerAndTwoTabs()
    makeKey(wc)

    wc.controlReportAgent(
      pane: panes[1], agent: "claude", state: "waiting", sessionId: nil, message: "bg")
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)

    wc.controlReportAgent(
      pane: panes[0], agent: "claude", state: "waiting", sessionId: nil, message: "fg")
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id, "抑制は既存のピルを消さない")
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

  // MARK: - ②ピルの取り下げ（一覧の投影であることの配達経路）

  /// coalesce された行の再計算を同期で回す。**`refreshChrome` は呼ばない**——それは再投影を要求
  /// する側（本番の通知ハンドラ）の仕事で、テストが肩代わりすると「要求が届いたか」を測れなく
  /// なる。`flushChrome` は dirty が立っていなければ何もしないので、直前の操作が本番経路で
  /// `refreshChrome` を鳴らしていなければ取り下げは起きず、テストが落ちる。
  private func flushDelivered(_ wc: WindowController) {
    wc.flushChrome()
  }

  /// 同じペインが `working` へ戻ったらピルを取り下げる（`working` は一覧に載らない）。
  func testTransientWithdrawnWhenPaneReturnsToWorking() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    flushDelivered(wc)
    XCTAssertNotNil(wc.attentionStore.transient, "waiting のままなら取り下げない")

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    flushDelivered(wc)
    XCTAssertNil(wc.attentionStore.transient)
  }

  /// done のフォーカス消費（done→idle）で行が消えたらピルを取り下げる。
  /// 消費そのものは通知を持たない（本番でも `wire` の onAgentStateChange が続けて
  /// `refreshChrome` を鳴らす）ので、その 1 手だけテスト側が同じ順で再現する。
  func testTransientWithdrawnWhenDoneConsumedToIdle() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(pane: pane, agent: "claude", state: "done", sessionId: nil, message: "d")
    flushDelivered(wc)
    XCTAssertNotNil(wc.attentionStore.transient)

    wc.current.tabs[0].consumeDoneState()
    wc.refreshChrome()
    flushDelivered(wc)
    XCTAssertNil(wc.attentionStore.transient)
  }

  /// ピルが指すペインのタブを閉じたら取り下げる。
  func testTransientWithdrawnWhenTabClosed() throws {
    let (wc, panes) = try makeControllerAndTwoTabs()
    wc.controlReportAgent(
      pane: panes[1], agent: "claude", state: "waiting", sessionId: nil, message: "q")
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)

    wc.closeTab(wc.current.tabs[1])
    flushDelivered(wc)
    XCTAssertNil(wc.attentionStore.transient)
  }

  /// split の 1 枚だけを閉じても取り下げる。`close(_:)` → `onLayoutChange` → `refreshChrome`
  /// という配線が通っていなければ dirty が立たず `flushChrome` が空振りして落ちる。
  func testTransientWithdrawnWhenSplitPaneClosed() throws {
    let (wc, pane) = try makeControllerAndPane()
    let tab = wc.current.tabs[0]
    let sibling = try XCTUnwrap(tab.split(.horizontal, from: pane))

    wc.controlReportAgent(
      pane: sibling, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, sibling.id)

    tab.close(sibling)
    flushDelivered(wc)
    XCTAssertNil(wc.attentionStore.transient)
  }

  /// 関係ない別ペインの状態変化では取り下げない（②を立て直さない変化だけで見る）。
  func testTransientSurvivesUnrelatedPaneChange() throws {
    let (wc, panes) = try makeControllerAndTwoTabs()
    wc.controlReportAgent(
      pane: panes[1], agent: "claude", state: "waiting", sessionId: nil, message: "q")
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)

    wc.controlReportAgent(
      pane: panes[0], agent: "claude", state: "working", sessionId: nil, message: nil)
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)

    wc.controlReportAgent(
      pane: panes[0], agent: "claude", state: "clear", sessionId: nil, message: nil)
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)
  }

  /// 同一ペインの waiting→done の差し替えは従来どおり働く（差し替え直後の flush で消えない）。
  func testTransientReplacementFromWaitingToDoneSurvivesFlush() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.state, "waiting")

    wc.controlReportAgent(pane: pane, agent: "claude", state: "done", sessionId: nil, message: "d")
    XCTAssertEqual(wc.attentionStore.transient?.row.state, "done")
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.state, "done")
  }

  /// 休眠（未 activate）workspace のペインでは②を立てない——立てる側（`attentionRow(for:)`）は
  /// 一覧（`AttentionSnapshot.rows`）と同じ activate 済み workspace のみを見る。立ててしまうと、
  /// その行は一覧に出ないので次の flush で即取り下げられる幽霊ピルになる。
  ///
  /// 到達性は低いが 0 ではない: 制御 API のペイン解決は休眠 workspace も走査するので、
  /// `report_agent` を直接撃てばここへ届く（hook 経由は休眠側に pty が無いので届かない）。
  func testTransientNotFiredForDormantWorkspacePane() throws {
    let (wc, dormantPane) = try makeControllerAndDormantPane()
    XCTAssertFalse(wc.window.isKeyWindow, "前提: 背面（非 key）なので見ているタブの抑制は効かない")

    wc.controlReportAgent(
      pane: dormantPane, agent: "claude", state: "waiting", sessionId: nil, message: "q")
    XCTAssertNil(wc.attentionStore.transient, "休眠 workspace のペインでは②を立てない")

    flushDelivered(wc)
    XCTAssertTrue(wc.attentionStore.rows.isEmpty, "一覧にも出ない（立てる側と同じ集合）")
  }

  // MARK: - ペイン集合が増える側（split）の再投影

  /// split でも chrome 再投影を鳴らす。新ペインは状態を持たず単体では chrome 差分を作らないので、
  /// split の**後**に状態だけを直接立てて（通知は鳴らさない）一覧が追随するかで測る。
  /// `split()` の `onLayoutChange?()` が無ければ dirty が立たず `flushChrome` が空振りして落ちる。
  func testSplitReprojectsChrome() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.flushChrome()  // 起動時に積まれた再投影を消化し、dirty が立っていない地点から測る
    XCTAssertTrue(wc.attentionStore.rows.isEmpty)

    let sibling = try XCTUnwrap(wc.current.tabs[0].split(.horizontal, from: pane))
    sibling.agentState = "waiting"  // report 経路は通さない＝再投影を要求するのは split だけ
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.rows.map(\.paneId), [sibling.id])
  }
}
