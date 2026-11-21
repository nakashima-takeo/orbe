import AppKit
import OrbeSound
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

  /// 1 workspace 1 タブで `window` の上に起動し、そのタブを返す。
  /// 分割した拡張ファイルからも使うため internal。
  func makeControllerAndTab(window: OrbeWindow = OrbeWindow()) throws -> (
    WindowController, TerminalTab
  ) {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController(window: window)
    let tab = try XCTUnwrap(wc.current.tabs.first)
    return (wc, tab)
  }

  /// `window` の上に `makeControllerAndTab` で起動し、初回起動の言語選択（真のモーダル）を閉じた `WindowController`。
  /// オーバーレイが出ていない窓を前提にするテストの足場。分割した拡張ファイルからも使うため internal。
  func launchWithoutFirstRun(window: OrbeWindow = OrbeWindow()) throws -> WindowController {
    let (wc, _) = try makeControllerAndTab(window: window)
    wc.dismissPalette()
    return wc
  }

  /// 1 workspace 2 タブ（アクティブはタブ0＝見ているタブ）で `window` の上に起動し、
  /// タブ順に並べた各タブ（`tabs[i]` がタブ i）を返す。
  /// 分割した拡張ファイルからも使うため internal。
  func makeControllerAndTwoTabs(window: OrbeWindow = OrbeWindow()) throws -> (
    WindowController, [TerminalTab]
  ) {
    let tab = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [tab, tab])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController(window: window)
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
    _ = wc.controlActivateWorkspace(workspaceId: try XCTUnwrap(wc.regularWorkspaces.last).id)
    XCTAssertTrue(wc.regularWorkspaces.allSatisfy(\.activated), "前提: どちらも activate 済み")
    let tabs = try wc.regularWorkspaces.map {
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
    let dormant = try XCTUnwrap(wc.regularWorkspaces.last)
    XCTAssertFalse(dormant.activated, "前提: 復元直後の未切替 workspace は休眠")
    return (wc, try XCTUnwrap(dormant.tabs.first))
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

  /// waiting / done への実変化だけが一過性イベント（メニューバー②）を立て、通知音を鳴らす。
  func testTransientFiresOnlyOnWaitingOrDoneChange() throws {
    let (wc, tab) = try makeControllerAndTab()
    XCTAssertFalse(wc.window.isKeyWindow, "前提: 背面（非 key）なので見ているタブの抑制は効かない")
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)

    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "working"))
    XCTAssertNil(wc.attentionStore.transient, "working への変化では立てない")

    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "q")))
    let transient = try XCTUnwrap(wc.attentionStore.transient)
    XCTAssertEqual(transient.row?.tabId, tab.id)
    XCTAssertEqual(transient.row?.state, "waiting")
    XCTAssertEqual(transient.row?.message, "q")

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
    XCTAssertEqual(wc.attentionStore.transient?.row?.state, "done")

    wc.attentionStore.transient = nil
    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "clear"))
    XCTAssertNil(wc.attentionStore.transient, "clear では立てない")
    XCTAssertEqual(sound.played.map(\.event), [.waiting, .done], "音もピルと同じ変化でだけ鳴る")
  }

  /// 見ているタブ（前面ウィンドウのアクティブ表示タブ）のタブでは②を立てない。
  /// 抑制されるのはピルだけで、一覧（rows）と done のフォーカス消費は従来どおり効く。
  func testTransientSuppressedOnVisibleTab() throws {
    let window = OrbeWindowFake()
    let (wc, tab) = try makeControllerAndTab(window: window)
    window.isKey = true
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)

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
    XCTAssertTrue(sound.played.isEmpty, "見ているタブでは音も鳴らさない")
  }

  /// 前面のままでも、見ていない別タブなら②は立つ。
  func testTransientFiresForBackgroundTabWhileKey() throws {
    let window = OrbeWindowFake()
    let (wc, tabs) = try makeControllerAndTwoTabs(window: window)
    window.isKey = true

    wc.controlReportAgent(
      tab: tabs[1],
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "q")))
    XCTAssertEqual(wc.attentionStore.transient?.row?.tabId, tabs[1].id)
  }

  /// 抑制は「立てない」だけ。別の場所で起きた変化の既存ピルには触らない。
  func testSuppressionKeepsExistingTransient() throws {
    let window = OrbeWindowFake()
    let (wc, tabs) = try makeControllerAndTwoTabs(window: window)
    window.isKey = true

    wc.controlReportAgent(
      tab: tabs[1],
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "bg")))
    XCTAssertEqual(wc.attentionStore.transient?.row?.tabId, tabs[1].id)

    wc.controlReportAgent(
      tab: tabs[0],
      report: AgentHookReport(
        agent: "claude", state: "waiting", sessionId: nil,
        message: AgentMessage(text: "fg")))
    XCTAssertEqual(wc.attentionStore.transient?.row?.tabId, tabs[1].id, "抑制は既存のピルを消さない")
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
}
