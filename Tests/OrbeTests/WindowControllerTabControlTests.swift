import AppKit
import XCTest

@testable import Orbe

/// タブ操作（focus_tab / close_tab）と config の workspace 明示ターゲットの `ControlTarget` 適合の
/// 観測可能な契約を固定する。
///
/// 重要: WindowControllerControlTests と同様、実 NSWindow に SurfaceView を接続するため
/// **libghostty ランタイムを起動する**（GhosttyKit 必須）。workspace の id は IdGen 採番で予測不能なため
/// 直書きせず `controlListWorkspaces()` / `controlListTabs()` の戻りから読む。
final class WindowControllerTabControlTests: OrbeTestCase {

  // MARK: - fixtures / helpers

  private static let plainTab = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)

  /// 素のシェルタブ 1 枚（既定）または指定タブ群を持つ workspace 状態。
  private func tabbed(_ name: String, tabs: [TabState] = [plainTab]) -> WorkspaceState {
    WorkspaceState(name: name, rootPath: "/tmp", activeTab: 0, tabs: tabs)
  }

  /// 2 タブの WS 状態。close_tab で 1 枚閉じても WS が空化しない（もう 1 枚残る）様子を見るため 2 タブ。
  private func twoTabbed(_ name: String) -> WorkspaceState {
    tabbed(name, tabs: [Self.plainTab, Self.plainTab])
  }

  /// resume 未対応 agent を載せたタブ（消費時に素シェル化するが休眠チケットには数える）。
  private func agentTab(_ id: String) -> TabState {
    TabState(
      cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: id), explicitTitle: nil)
  }

  /// ディスクへ workspaces を書いてから復元済み WindowController を返す。
  private func restore(activeWorkspace: Int, _ workspaces: [WorkspaceState]) throws
    -> WindowController
  {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: activeWorkspace,
      workspaces: workspaces)
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  /// controlListWorkspaces から (name==) の行を引く。
  private func row(_ wc: WindowController, name: String) -> [String: Any]? {
    wc.controlListWorkspaces().first { $0["name"] as? String == name }
  }

  // MARK: - createWorkspace の初回シェル cwd

  /// 新規作成した workspace の初回シェルは rootPath（`~` 展開済み）で開く（ホームに落ちない）。
  /// 回帰: createWorkspace が cwd 無しの newTab を呼び、初回シェルがホームに開いていた。
  func testCreatedWorkspaceFirstTabOpensAtRootPath() throws {
    let expected = ("~/orbe-create-test" as NSString).expandingTildeInPath
    let wc = try restore(activeWorkspace: 0, [tabbed("default")])
    wc.createWorkspace(name: "infra", rootPath: "~/orbe-create-test")
    XCTAssertEqual(wc.current.name, "infra", "作成した WS がアクティブ")
    XCTAssertEqual(wc.current.rootPath, expected, "rootPath は ~ 展開して保存")
    XCTAssertEqual(wc.current.tabs.count, 1, "0タブから初回シェル 1 枚")
    XCTAssertEqual(wc.current.tabs.first?.cwd, expected, "初回タブの cwd は rootPath（ホームでない）")
  }

  // MARK: - controlCloseTab

  /// 背景 workspace の休眠タブを close_tab で閉じると、休眠件数は現在残る agent 由来タブから導出される
  /// （復元時の固定値ではない）。背景 close は MRU も activated も動かさない。
  func testClosingDormantAgentTabInBackgroundUpdatesRestoredAgentCount() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main"), tabbed("sleepers", tabs: [agentTab("a"), Self.plainTab])])
    let sleepers = try XCTUnwrap(wc.workspaces.first { $0.name == "sleepers" })
    let stamp = Date(timeIntervalSinceReferenceDate: 7_000)
    sleepers.lastUsedAt = stamp
    let agent = try XCTUnwrap(sleepers.tabs.first { $0.isDormant })

    guard case .success = wc.controlCloseTab(tabId: agent.id) else {
      return XCTFail("dormant agent tab close")
    }

    XCTAssertFalse(sleepers.activated)
    XCTAssertEqual(sleepers.dormantAgentCount(), 0)
    XCTAssertEqual(sleepers.tabs.count, 1, "plain sibling は残る")
    XCTAssertEqual(sleepers.lastUsedAt, stamp, "背景 close は MRU を動かさない")
    XCTAssertEqual(row(wc, name: "sleepers")?["dormantAgentCount"] as? Int, 0)
  }

  /// 休眠件数は agent 由来タブだけを数える。素のタブの close で減るならタブ総数を数えている退行。
  func testClosingPlainDormantTabKeepsRestoredAgentCount() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main"), tabbed("sleepers", tabs: [agentTab("a"), Self.plainTab])])
    let sleepers = try XCTUnwrap(wc.workspaces.first { $0.name == "sleepers" })
    let plain = try XCTUnwrap(sleepers.tabs.first { !$0.isDormant })

    guard case .success = wc.controlCloseTab(tabId: plain.id) else {
      return XCTFail("plain dormant tab close")
    }

    XCTAssertEqual(sleepers.dormantAgentCount(), 1)
    XCTAssertEqual(sleepers.tabs.count, 1)
  }

  /// 前面の close は残存 tab を reselect して起こすため、背景 close と違い activated は true のまま。
  func testClosingLiveTabInForegroundMixedWorkspaceMaterializesRemainingTab() throws {
    let wc = try restore(
      activeWorkspace: 0, [tabbed("mixed", tabs: [Self.plainTab, agentTab("sleeping")])])
    XCTAssertTrue(wc.current.tabs[0].activated, "選択タブは同期で起床")
    XCTAssertFalse(wc.current.tabs[1].activated, "main queue に戻る前の hidden タブは休眠")
    XCTAssertEqual(wc.current.dormantAgentCount(), 1)
    let stamp = Date(timeIntervalSinceReferenceDate: 1)
    wc.current.lastUsedAt = stamp

    wc.closeTab(wc.current.tabs[0], origin: .controlAPI)

    XCTAssertEqual(wc.current.tabs.count, 1)
    XCTAssertTrue(wc.current.tabs[0].activated, "reselect された残存タブは同期 materialize")
    XCTAssertTrue(wc.current.activated)
    XCTAssertEqual(wc.current.dormantAgentCount(), 0)
    XCTAssertGreaterThan(try XCTUnwrap(wc.current.lastUsedAt), stamp, "残存タブの前面利用で MRU を進める")
  }

  /// 次 tab の前面表示を伴わない close は foreground use ではないので MRU を進めない。
  func testClosingLastForegroundTabKeepsMRUAndReturnsActivationToFalse() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let stamp = Date(timeIntervalSinceReferenceDate: 2_000)
    wc.current.lastUsedAt = stamp
    XCTAssertTrue(wc.current.activated)

    wc.closeTab(wc.current.tabs[0], origin: .controlAPI)

    XCTAssertTrue(wc.current.tabs.isEmpty)
    XCTAssertFalse(wc.current.activated)
    XCTAssertEqual(wc.current.lastUsedAt, stamp, "次タブの前面利用が無い close で MRU は進めない")
  }

  /// close_tab は id 解決の上でタブを閉じ、そのタブが list_tabs から消える（複数タブ WS で畳まず）。
  func testCloseTabByIdRemovesTab() throws {
    let wc = try restore(activeWorkspace: 0, [twoTabbed("main")])
    let tabIds = Set(wc.controlListTabs().compactMap { $0["tabId"] as? Int })
    XCTAssertEqual(tabIds.count, 2, "前提: 2 タブ")
    let victim = try XCTUnwrap(tabIds.first)
    // エージェント hook のセッション報告（report_agent）と同じくエージェントを載せてから閉じる＝
    // エージェント判定では通る状態にして、発火源の判定だけが効いていることを固定する。
    let victimTab = try XCTUnwrap(wc.current.tabs.first { $0.id == victim })
    victimTab.agentSlot = .live(
      session: AgentSession(command: "claude", sessionId: "live-1"), report: nil)
    guard case .success = wc.controlCloseTab(tabId: victim) else {
      return XCTFail("close_tab は success")
    }
    XCTAssertFalse(
      wc.controlListTabs().contains { $0["tabId"] as? Int == victim }, "閉じたタブは消える")
    XCTAssertTrue(
      wc.current.closedAgentTabs.isEmpty,
      "制御 API の閉鎖は開き直しスタックへ積まない（⇧⌘T の対象は人のジェスチャだけ）")
  }

  /// close_tab は未知 tabId を -32004 で弾く。
  func testCloseTabUnknownIsNotFound() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    guard case .failure(let err) = wc.controlCloseTab(tabId: 999_999) else {
      return XCTFail("未知タブは failure")
    }
    XCTAssertEqual(err.code, -32004)
  }

  // MARK: - controlFocusTab

  /// 別 WS のタブを focus すると、その WS が activate されアクティブになる（switchWorkspace 込み）。
  func testFocusTabAcrossWorkspacesActivatesTarget() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("background")])
    XCTAssertEqual(wc.window.title, "main", "前提: main がアクティブ")
    let bgId = try XCTUnwrap(row(wc, name: "background")?["id"] as? Int)
    let bgTab = try XCTUnwrap(
      wc.controlListTabs().first { $0["workspaceId"] as? Int == bgId }?["tabId"] as? Int)
    guard case .success = wc.controlFocusTab(tabId: bgTab) else {
      return XCTFail("focus_tab は success")
    }
    XCTAssertEqual(wc.window.title, "background", "別 WS のタブ focus は当該 WS を activate する")
    XCTAssertTrue(
      wc.window.firstResponder === wc.current.tabs[wc.current.active].surface,
      "first responder はそのタブの surface へ移る")
  }

  /// 同じ WS の非選択タブを focus すると選択が移る。
  func testFocusTabSelectsWithinWorkspace() throws {
    let wc = try restore(activeWorkspace: 0, [twoTabbed("main")])
    XCTAssertEqual(wc.current.active, 0)
    guard case .success = wc.controlFocusTab(tabId: wc.current.tabs[1].id) else {
      return XCTFail("focus_tab は success")
    }
    XCTAssertEqual(wc.current.active, 1, "指したタブが選択される")
  }

  /// focus_tab は未知タブを -32004 で弾く。
  func testFocusTabUnknownIsNotFound() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    guard case .failure(let err) = wc.controlFocusTab(tabId: 999_999) else {
      return XCTFail("未知タブは failure")
    }
    XCTAssertEqual(err.code, -32004)
  }

  // MARK: - controlListTabs の active

  /// `active` は「その workspace で選択中のタブ」——前面かに依らず workspace ごとに 1 枚だけ true。
  /// 前面のタブだけを true にすると、背景 workspace へ `spawn` したクライアントが「今そこで
  /// 選ばれているタブ」を知る手段が無くなる（前面かは `list_workspaces.active` が答える）。
  func testListTabsMarksTheSelectedTabOfEveryWorkspaceActive() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [
        twoTabbed("main"),
        WorkspaceState(
          name: "background", rootPath: "/tmp", activeTab: 1,
          tabs: [Self.plainTab, Self.plainTab]),
      ])
    let background = try XCTUnwrap(wc.workspaces.first { $0.name == "background" })
    XCTAssertEqual(background.active, 1, "前提: 背景 WS は 2 枚目を選択中")
    guard case .success = wc.controlFocusTab(tabId: wc.current.tabs[1].id) else {
      return XCTFail("focus_tab は success")
    }

    let active = wc.controlListTabs().filter { $0["active"] as? Bool == true }

    XCTAssertEqual(
      Set(active.compactMap { $0["tabId"] as? Int }),
      [wc.current.tabs[1].id, background.tabs[1].id],
      "前面・背景それぞれの選択中タブが 1 枚ずつ true")
  }

  // MARK: - tab_closed（タブの消滅で流れる）

  /// `tab_closed` の待機を張り、登録完了を barrier で確定させる。
  private func armTabClosedWait(_ wire: ControlWire, id: Int, tabId: Int) {
    wire.send([
      "jsonrpc": "2.0", "id": id, "method": "wait_for_event",
      "params": ["kinds": ["tab_closed"], "tabId": tabId],
    ])
    wire.barrier()
  }

  private func closedTabId(_ response: [String: Any]?) -> Int? {
    ((response?["result"] as? [String: Any])?["event"] as? [String: Any])?["tabId"] as? Int
  }

  /// close_tab で閉じた前面タブは `tab_closed` を流す——mount 済みの view と生成済み surface を
  /// 持つタブが、閉じた後にどこからも保持されずに消滅する。壊れると（強参照が残ると）イベントが
  /// 流れず `orb wait` / `prompt_agent` が閉じたタブをタイムアウトまで待ち、surface もリークする。
  func testCloseTabEmitsTabClosedForTheClosedForegroundTab() throws {
    let wc = try restore(activeWorkspace: 0, [twoTabbed("main")])
    let victim = wc.current.tabs[0].id
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    armTabClosedWait(wire, id: 1, tabId: victim)

    guard case .success = wc.controlCloseTab(tabId: victim) else {
      return XCTFail("close_tab は success")
    }

    XCTAssertEqual(closedTabId(wire.nextResponse()), victim, "閉じたタブの id で tab_closed が流れる")
  }

  /// workspace ごと閉じると、持っていた全タブの `tab_closed` が流れる（背景 workspace の未 mount
  /// タブも漏らさない）。
  func testCloseWorkspaceEmitsTabClosedForEveryTabItHeld() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), twoTabbed("doomed")])
    let doomed = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "doomed" })
    let held = wc.workspaces[doomed].tabs.map(\.id)
    let wire = ControlWire(target: nil)
    defer { wire.teardown() }
    for (i, tabId) in held.enumerated() { armTabClosedWait(wire, id: i + 1, tabId: tabId) }

    wc.closeWorkspace(doomed)

    XCTAssertEqual(
      Set([closedTabId(wire.nextResponse()), closedTabId(wire.nextResponse())].compactMap { $0 }),
      Set(held), "閉じた workspace の全タブが tab_closed を流す")
  }

  // MARK: - config の workspace ターゲット化

  /// config_set は workspaceId 指定で非アクティブ WS の上書きへ in-place で書き、アクティブ WS の
  /// 実効値は変えない（参照型 in-place・ライブ反映 gate の契約）。
  func testConfigSetTargetsInactiveWorkspaceWithoutTouchingActive() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("probe")])
    let probeId = try XCTUnwrap(row(wc, name: "probe")?["id"] as? Int)
    guard
      case .success = wc.controlConfigSet(
        key: "font-size", value: 20, scope: "workspace", workspaceId: probeId)
    else { return XCTFail("非アクティブ WS への config_set は success") }

    // probe の実効値は override（20・scope=workspace）。
    guard case .success(let listed) = wc.controlConfigList(workspaceId: probeId) else {
      return XCTFail("config_list(probe) は success")
    }
    let probeRows = try XCTUnwrap((listed as? [String: Any])?["settings"] as? [[String: Any]])
    let probeFont = try XCTUnwrap(probeRows.first { $0["key"] as? String == "font-size" })
    XCTAssertEqual(probeFont["value"] as? Int, 20, "probe は上書き値 20")
    XCTAssertEqual(probeFont["scope"] as? String, "workspace", "probe の由来は workspace")

    // アクティブ WS（main）の font-size は上書きされない。
    guard case .success(let active) = wc.controlConfigList(workspaceId: nil) else {
      return XCTFail("config_list(active) は success")
    }
    let activeRows = try XCTUnwrap((active as? [String: Any])?["settings"] as? [[String: Any]])
    let activeFont = try XCTUnwrap(activeRows.first { $0["key"] as? String == "font-size" })
    XCTAssertNotEqual(
      activeFont["scope"] as? String, "workspace", "アクティブ WS は上書きされない")
  }

  /// config_list / config_set は未知 workspaceId を -32004 で弾く。
  func testConfigWorkspaceTargetUnknownIsNotFound() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    guard case .failure(let listErr) = wc.controlConfigList(workspaceId: 999_999) else {
      return XCTFail("config_list 未知 id は failure")
    }
    XCTAssertEqual(listErr.code, -32004)
    guard
      case .failure(let setErr) = wc.controlConfigSet(
        key: "font-size", value: 20, scope: "workspace", workspaceId: 999_999)
    else { return XCTFail("config_set 未知 id は failure") }
    XCTAssertEqual(setErr.code, -32004)
  }
}
