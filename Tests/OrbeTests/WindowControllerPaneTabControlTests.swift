import AppKit
import XCTest

@testable import Orbe

/// 第二段（pane/tab コマンド＋config の workspace 明示ターゲット）で加わった `ControlTarget` 適合の
/// 観測可能な契約を固定する。対象は split_pane / close_pane / focus_pane / close_tab と、
/// config_list / config_set の workspaceId 対象化。
///
/// 重要: WindowControllerControlTests と同様、実 NSWindow に SurfaceView を接続するため
/// **libghostty ランタイムを起動する**（GhosttyKit 必須）。workspace の id は IdGen 採番で予測不能なため
/// 直書きせず `controlListWorkspaces()` / `controlListPanes()` の戻りから読む。
final class WindowControllerPaneTabControlTests: OrbeTestCase {

  // MARK: - fixtures / helpers

  /// 単一 leaf タブを持つ workspace 状態。
  private func tabbed(_ name: String, tree: PaneNode = .leaf(cwd: nil, agent: nil))
    -> WorkspaceState
  {
    WorkspaceState(
      name: name, rootPath: "/tmp", activeTab: 0,
      tabs: [TabState(tree: tree, explicitTitle: nil)])
  }

  /// 2 タブの WS 状態。close_tab で 1 枚閉じても WS が空化しない（もう 1 枚残る）様子を見るため 2 タブ。
  private func twoTabbed(_ name: String) -> WorkspaceState {
    WorkspaceState(
      name: name, rootPath: "/tmp", activeTab: 0,
      tabs: [
        TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil),
        TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil),
      ])
  }

  private func agentLeaf(_ id: String) -> PaneNode {
    .leaf(cwd: nil, agent: AgentSession(command: "unknown", sessionId: id))
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

  /// main キューに積まれた非同期ブロック（`TerminalController.close` の `onEmpty` ホップ）を捌く。
  /// FIFO なので、close の後に積んだこのブロックが走った時点で `onEmpty` は処理済み。
  private func drainMainQueue() {
    let exp = expectation(description: "main queue drained")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)
  }

  // MARK: - createWorkspace の初回シェル cwd

  /// 新規作成した workspace の初回シェルは rootPath（`~` 展開済み）で開く（ホームに落ちない）。
  /// 回帰: createWorkspace が initialCwd 無しの newTab を呼び、初回シェルがホームに開いていた。
  func testCreatedWorkspaceFirstTabOpensAtRootPath() throws {
    let expected = ("~/orbe-create-test" as NSString).expandingTildeInPath
    let wc = try restore(activeWorkspace: 0, [tabbed("default")])
    wc.createWorkspace(name: "infra", rootPath: "~/orbe-create-test")
    XCTAssertEqual(wc.current.name, "infra", "作成した WS がアクティブ")
    XCTAssertEqual(wc.current.rootPath, expected, "rootPath は ~ 展開して保存")
    XCTAssertEqual(wc.current.tabs.count, 1, "0タブから初回シェル 1 枚")
    XCTAssertEqual(
      wc.current.tabs.first?.focusedPane?.initialCwd, expected,
      "初回タブの initialCwd は rootPath（ホームでない）")
  }

  // MARK: - controlSplitPane / controlClosePane / controlFocusPane / controlCloseTab

  /// split_pane は所有タブへ 1 枚足し、新ペイン id（元と異なる）を返す。list_panes にも現れる。
  func testSplitPaneGrowsTabAndReturnsNewId() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let pid = try XCTUnwrap(wc.controlListPanes().first?["paneId"] as? Int)
    guard
      case .success(let payload) = wc.controlSplitPane(
        paneId: pid, direction: "right", command: nil)
    else { return XCTFail("split_pane は success") }
    let newId = try XCTUnwrap((payload as? [String: Any])?["paneId"] as? Int)
    XCTAssertNotEqual(newId, pid, "新ペイン id は元ペインと異なる")
    let after = wc.controlListPanes()
    XCTAssertEqual(after.count, 2, "ペインが 1 枚増える")
    XCTAssertTrue(after.contains { $0["paneId"] as? Int == newId }, "新ペインが list_panes に現れる")
  }

  /// split_pane は未知ペインを -32004 で弾く。
  func testSplitPaneUnknownIsNotFound() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    guard
      case .failure(let err) = wc.controlSplitPane(
        paneId: 999_999, direction: "right", command: nil)
    else { return XCTFail("未知ペインは failure") }
    XCTAssertEqual(err.code, -32004)
  }

  /// close_pane は分割ツリーの 1 leaf を閉じ、そのペインが list_panes から消える。
  func testClosePaneRemovesLeaf() throws {
    let split = PaneNode.split(
      vertical: true, ratio: 0.5, first: .leaf(cwd: nil, agent: nil),
      second: .leaf(cwd: nil, agent: nil))
    let wc = try restore(activeWorkspace: 0, [tabbed("main", tree: split)])
    XCTAssertEqual(wc.controlListPanes().count, 2, "前提: 2 leaf")
    let victim = try XCTUnwrap(wc.controlListPanes().last?["paneId"] as? Int)
    guard case .success = wc.controlClosePane(paneId: victim) else {
      return XCTFail("close_pane は success")
    }
    XCTAssertFalse(
      wc.controlListPanes().contains { $0["paneId"] as? Int == victim }, "閉じたペインは消える")
  }

  /// close_pane が最後の 1 枚を閉じてタブごと落ちる（カスケード）ときも、開き直しスタックへ積まない。
  /// close_tab と違いここは `onEmpty` の main ホップを跨ぐ経路で、発火源が `.gesture` に化けると
  /// 「制御 API で畳んだタブが ⇧⌘T で復活する」が静かに起きる。
  func testClosePaneCascadingToTabDoesNotStackForReopen() throws {
    let wc = try restore(activeWorkspace: 0, [twoTabbed("main")])
    let victim = try XCTUnwrap(wc.current.tabs.first)
    // close_tab 側と同じくエージェントを載せてから閉じる＝エージェント判定では通る状態にして、
    // 発火源の判定だけが効いていることを固定する。
    let pane = try XCTUnwrap(victim.focusedPane)
    pane.agentSlot = .live(
      session: AgentSession(command: "claude", sessionId: "live-1"), report: nil)
    guard case .success = wc.controlClosePane(paneId: pane.id) else {
      return XCTFail("close_pane は success")
    }
    drainMainQueue()  // close → onEmpty → closeTab

    XCTAssertEqual(wc.current.tabs.count, 1, "前提: 最後の 1 枚を閉じてタブごと落ちている")
    XCTAssertTrue(
      wc.current.closedAgentTabs.isEmpty,
      "制御 API の閉鎖は開き直しスタックへ積まない（⇧⌘T の対象は人のジェスチャだけ）")
  }

  /// close_pane は未知ペインを -32004 で弾く。
  func testClosePaneUnknownIsNotFound() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    guard case .failure(let err) = wc.controlClosePane(paneId: 999_999) else {
      return XCTFail("未知ペインは failure")
    }
    XCTAssertEqual(err.code, -32004)
  }

  /// 休眠 split の数は復元時の固定値ではなく、現在残る agent 由来 pane から導出する。
  func testClosingDormantSplitPaneUpdatesOnlyItsRestoredAgentCount() throws {
    let split = PaneNode.split(
      vertical: true, ratio: 0.5, first: agentLeaf("a"),
      second: .leaf(cwd: nil, agent: nil))
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("sleepers", tree: split)])
    let sleepers = try XCTUnwrap(wc.workspaces.first { $0.name == "sleepers" })
    let stamp = Date(timeIntervalSinceReferenceDate: 7_000)
    sleepers.lastUsedAt = stamp
    let agentPane = try XCTUnwrap(
      sleepers.tabs[0].controlAllPanes().first { $0.agentSlot.isDormant })

    guard case .success = wc.controlClosePane(paneId: agentPane.id) else {
      return XCTFail("dormant agent pane close")
    }

    XCTAssertFalse(sleepers.activated)
    XCTAssertEqual(sleepers.dormantAgentCount(), 0)
    XCTAssertEqual(sleepers.tabs[0].controlAllPanes().count, 1, "plain sibling は残る")
    XCTAssertEqual(sleepers.lastUsedAt, stamp, "背景 close は MRU を動かさない")
    XCTAssertEqual(row(wc, name: "sleepers")?["dormantAgentCount"] as? Int, 0)
  }

  /// 休眠件数は agent 由来 pane だけを数える。非 agent pane の close で減るなら pane 総数を数えている退行。
  func testClosingPlainDormantSplitPaneKeepsRestoredAgentCount() throws {
    let split = PaneNode.split(
      vertical: true, ratio: 0.5, first: agentLeaf("a"),
      second: .leaf(cwd: nil, agent: nil))
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("sleepers", tree: split)])
    let sleepers = try XCTUnwrap(wc.workspaces.first { $0.name == "sleepers" })
    let plain = try XCTUnwrap(
      sleepers.tabs[0].controlAllPanes().first { !$0.agentSlot.isDormant })

    guard case .success = wc.controlClosePane(paneId: plain.id) else {
      return XCTFail("plain dormant pane close")
    }

    XCTAssertEqual(sleepers.dormantAgentCount(), 1)
    XCTAssertEqual(sleepers.tabs[0].controlAllPanes().count, 1)
  }

  /// domain の成功が先行し、tab ごと消えるのは main queue の onEmpty——この二段階を両相で固定する。
  func testClosingLastDormantPaneRemovesCountOnlyAfterQueuedTabTeardown() throws {
    let wc = try restore(
      activeWorkspace: 0, [tabbed("main"), tabbed("sleepers", tree: agentLeaf("a"))])
    let sleepers = try XCTUnwrap(wc.workspaces.first { $0.name == "sleepers" })
    let pane = try XCTUnwrap(sleepers.tabs[0].controlAllPanes().first)

    guard case .success = wc.controlClosePane(paneId: pane.id) else {
      return XCTFail("last dormant pane close")
    }
    XCTAssertEqual(sleepers.tabs.count, 1, "domain success 直後は onEmpty が main queue 待ち")
    XCTAssertEqual(sleepers.dormantAgentCount(), 1)

    drainMainQueue()
    XCTAssertTrue(sleepers.tabs.isEmpty)
    XCTAssertEqual(sleepers.dormantAgentCount(), 0)
    XCTAssertFalse(sleepers.activated)
  }

  /// 前面の close は残存 tab を reselect して起こすため、背景 close と違い activated は true のまま。
  func testClosingLiveTabInForegroundMixedWorkspaceMaterializesRemainingTab() throws {
    let state = WorkspaceState(
      name: "mixed", rootPath: "/tmp", activeTab: 0,
      tabs: [
        TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil),
        TabState(tree: agentLeaf("sleeping"), explicitTitle: nil),
      ])
    let wc = try restore(activeWorkspace: 0, [state])
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

  /// 別 WS の pane を focus すると、その WS が activate されアクティブになる（switchWorkspace 込み）。
  func testFocusPaneAcrossWorkspacesActivatesTarget() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("background")])
    XCTAssertEqual(wc.window.title, "main", "前提: main がアクティブ")
    let bgId = try XCTUnwrap(row(wc, name: "background")?["id"] as? Int)
    let bgPane = try XCTUnwrap(
      wc.controlListPanes().first { $0["workspaceId"] as? Int == bgId }?["paneId"] as? Int)
    guard case .success = wc.controlFocusPane(paneId: bgPane) else {
      return XCTFail("focus_pane は success")
    }
    XCTAssertEqual(wc.window.title, "background", "別 WS の pane focus は当該 WS を activate する")
  }

  /// focus_pane は未知ペインを -32004 で弾く。
  func testFocusPaneUnknownIsNotFound() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    guard case .failure(let err) = wc.controlFocusPane(paneId: 999_999) else {
      return XCTFail("未知ペインは failure")
    }
    XCTAssertEqual(err.code, -32004)
  }

  /// close_tab は id 解決の上でタブを閉じ、そのタブのペインが list_panes から消える（複数タブ WS で畳まず）。
  func testCloseTabByIdRemovesTab() throws {
    let wc = try restore(activeWorkspace: 0, [twoTabbed("main")])
    let tabIds = Set(wc.controlListPanes().compactMap { $0["tabId"] as? Int })
    XCTAssertEqual(tabIds.count, 2, "前提: 2 タブ")
    let victim = try XCTUnwrap(tabIds.first)
    // エージェント hook のセッション報告（report_agent）と同じくエージェントを載せてから閉じる＝
    // エージェント判定では通る状態にして、発火源の判定だけが効いていることを固定する。
    let victimPane = try XCTUnwrap(wc.current.tabs.first { $0.id == victim }?.focusedPane)
    victimPane.agentSlot = .live(
      session: AgentSession(command: "claude", sessionId: "live-1"), report: nil)
    guard case .success = wc.controlCloseTab(tabId: victim) else {
      return XCTFail("close_tab は success")
    }
    XCTAssertFalse(
      wc.controlListPanes().contains { $0["tabId"] as? Int == victim }, "閉じたタブのペインは消える")
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
