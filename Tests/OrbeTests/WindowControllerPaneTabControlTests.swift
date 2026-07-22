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
final class WindowControllerPaneTabControlTests: XCTestCase {

  // 永続を実 Application Support から隔離する（テストごとに未作成の一時ファイルを指す）。
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

  /// ディスクへ workspaces を書いてから復元済み WindowController を返す。
  private func restore(activeWorkspace: Int, _ workspaces: [WorkspaceState]) throws
    -> WindowController
  {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: activeWorkspace,
      workspaces: workspaces)
    try JSONEncoder().encode(file).write(to: tempStore)
    return WindowController()
  }

  /// controlListWorkspaces から (name==) の行を引く。
  private func row(_ wc: WindowController, name: String) -> [String: Any]? {
    wc.controlListWorkspaces().first { $0["name"] as? String == name }
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

  /// close_pane は未知ペインを -32004 で弾く。
  func testClosePaneUnknownIsNotFound() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    guard case .failure(let err) = wc.controlClosePane(paneId: 999_999) else {
      return XCTFail("未知ペインは failure")
    }
    XCTAssertEqual(err.code, -32004)
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
    guard case .success = wc.controlCloseTab(tabId: victim) else {
      return XCTFail("close_tab は success")
    }
    XCTAssertFalse(
      wc.controlListPanes().contains { $0["tabId"] as? Int == victim }, "閉じたタブのペインは消える")
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
