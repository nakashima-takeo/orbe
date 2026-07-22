import AppKit
import XCTest

@testable import Orbe

/// u1（制御 API 拡張）で加わった `ControlTarget` 適合の観測可能な契約を固定する。
/// 対象は `activate_workspace` の実体 `controlActivateWorkspace` と、`list_workspaces` への
/// `dormantAgentCount` 露出。
///
/// 重要: WindowControllerWorkspaceTests と同様、実 NSWindow に SurfaceView を接続するため
/// **libghostty ランタイムを起動する**（GhosttyKit 必須）。ヘッドレスな純ロジック検証ではない。
///
/// workspace の id はプロセス全域の IdGen で採番され予測不能なため、決して直書きせず
/// `controlListWorkspaces()` の戻りから読む（配列インデックスでなく id で指す契約でもある）。
final class WindowControllerControlTests: XCTestCase {

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

  /// resume 未対応 agent を載せた leaf（復元時は素シェル化するが restoredAgentCount には数える）。
  private func agentLeaf(_ id: String) -> PaneNode {
    .leaf(cwd: nil, agent: AgentSession(command: "unknown", sessionId: id))
  }

  /// 単一 leaf タブを持つ workspace 状態。
  private func tabbed(_ name: String, tree: PaneNode = .leaf(cwd: nil, agent: nil))
    -> WorkspaceState
  {
    WorkspaceState(
      name: name, rootPath: "/tmp", activeTab: 0,
      tabs: [TabState(tree: tree, explicitTitle: nil)])
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

  // MARK: - controlActivateWorkspace

  /// 背景（active==false）workspace を activate すると、その workspace がアクティブになり、
  /// 戻り値は自身の id と当該 workspace のペイン ID 群（非空）。
  func testActivateBackgroundWorkspaceMakesItActiveAndReturnsPaneIds() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("background")])
    XCTAssertEqual(wc.window.title, "main")

    let bg = try XCTUnwrap(row(wc, name: "background"))
    let bgId = try XCTUnwrap(bg["id"] as? Int)
    XCTAssertEqual(bg["active"] as? Bool, false, "activate 前は背景（非アクティブ）")

    let result = try XCTUnwrap(
      wc.controlActivateWorkspace(workspaceId: bgId), "既知 id の activate は非 nil")
    XCTAssertEqual(result.activeWorkspaceId, bgId, "戻りの activeWorkspaceId は指定した背景 WS 自身")
    XCTAssertFalse(result.paneIds.isEmpty, "全タブ mount 後のペイン ID 群を返す")
    XCTAssertEqual(wc.window.title, "background", "背景 WS が前面化しアクティブになる")
    XCTAssertEqual(row(wc, name: "background")?["active"] as? Bool, true, "list 上も active になる")
  }

  /// 既にアクティブな workspace への activate は no-op で成功する（冪等）——切替も採番も起きず、
  /// 自身の id を返し title は変わらない。
  func testActivateAlreadyActiveWorkspaceIsIdempotent() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("background")])
    let main = try XCTUnwrap(row(wc, name: "main"))
    let mainId = try XCTUnwrap(main["id"] as? Int)
    let before = try XCTUnwrap(wc.controlActivateWorkspace(workspaceId: mainId))

    let again = try XCTUnwrap(
      wc.controlActivateWorkspace(workspaceId: mainId), "既アクティブへの activate も success")
    XCTAssertEqual(again.activeWorkspaceId, mainId, "アクティブは移らず自身を返す")
    XCTAssertEqual(again.paneIds, before.paneIds, "冪等: ペイン集合は増えも変わりもしない")
    XCTAssertEqual(wc.window.title, "main", "title 不変")
  }

  /// 未知の workspaceId は nil（spawn と違いアクティブへフォールバックしない）——ここが
  /// dispatch 側で `-32004 workspace not found` に畳まれる継ぎ目。アクティブは変わらない。
  func testActivateUnknownWorkspaceIdReturnsNilWithoutFallback() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("background")])
    XCTAssertNil(
      wc.controlActivateWorkspace(workspaceId: 999_999), "未知 id はフォールバックせず nil")
    XCTAssertEqual(wc.window.title, "main", "未知 id の activate はアクティブを変えない")
  }

  /// 返す paneIds は `list_panes`（controlListPanes）の当該 workspace 導出と一致する
  /// （activate 応答と後続 list_panes がズレない契約）。
  func testActivateReturnedPaneIdsMatchListPanesDerivation() throws {
    let split = PaneNode.split(
      vertical: true, ratio: 0.5,
      first: .leaf(cwd: nil, agent: nil), second: .leaf(cwd: nil, agent: nil))
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("background", tree: split)])
    let bgId = try XCTUnwrap(row(wc, name: "background")?["id"] as? Int)

    let result = try XCTUnwrap(wc.controlActivateWorkspace(workspaceId: bgId))
    let fromListPanes = wc.controlListPanes()
      .filter { $0["workspaceId"] as? Int == bgId }
      .compactMap { $0["paneId"] as? Int }
    XCTAssertEqual(result.paneIds.count, 2, "分割ツリーの 2 leaf 分のペインを返す")
    XCTAssertEqual(result.paneIds, fromListPanes, "activate の paneIds は list_panes と同一導出")
  }

  /// 0タブの休眠 workspace を activate すると、前面化はするがシェルは自動起動せず、
  /// paneIds は空配列で返る（0タブ空状態の表示・自動起こしなしの契約）。
  func testActivateEmptyDormantWorkspaceShowsEmptyAndReturnsNoPanes() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed("main"),
        WorkspaceState(name: "empty", rootPath: "/tmp", activeTab: 0, tabs: []),  // 0タブ休眠
      ])
    let emptyId = try XCTUnwrap(row(wc, name: "empty")?["id"] as? Int)

    let result = try XCTUnwrap(wc.controlActivateWorkspace(workspaceId: emptyId))
    XCTAssertEqual(result.activeWorkspaceId, emptyId)
    XCTAssertTrue(result.paneIds.isEmpty, "0タブ WS はシェルを起こさず paneIds は空配列")
    XCTAssertEqual(wc.window.title, "empty", "0タブ WS も activate で前面化する")
  }

  // MARK: - controlListWorkspaces の dormantAgentCount 露出

  /// list_workspaces の全行に dormantAgentCount フィールドが Int で出る（休眠可視化の源）。
  func testListWorkspacesExposesDormantAgentCountOnEveryRow() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("background")])
    let rows = wc.controlListWorkspaces()
    XCTAssertFalse(rows.isEmpty)
    for r in rows {
      XCTAssertNotNil(r["dormantAgentCount"] as? Int, "各行に dormantAgentCount(Int) が露出する")
    }
  }

  /// 休眠 workspace の dormantAgentCount は永続復元した agent!=nil leaf 数を反映する
  /// （agentState には出ない休眠 agent を、この永続カウントで露出する）。
  func testListWorkspacesDormantAgentCountReflectsPersistedAgents() throws {
    let sleepers = PaneNode.split(
      vertical: true, ratio: 0.5, first: agentLeaf("a"), second: agentLeaf("b"))
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed("main"),
        tabbed("sleepers", tree: sleepers),  // 休眠 agent 2
        tabbed("quiet"),  // 休眠 agent 0
      ])
    XCTAssertEqual(
      row(wc, name: "sleepers")?["dormantAgentCount"] as? Int, 2, "永続 agent leaf 2 を反映")
    XCTAssertEqual(
      row(wc, name: "quiet")?["dormantAgentCount"] as? Int, 0, "agent 無しの休眠 WS は 0")
  }

  // MARK: - controlListPanes の agentSessionId 露出

  /// list_panes の各ペインに agentSessionId フィールドが出る。report_agent 未適用のペインは
  /// null（NSNull）で、agentState と同じ null 許容の写し方に揃う（resume の鍵）。
  func testListPanesExposesAgentSessionIdAsNullWhenUnset() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let panes = wc.controlListPanes()
    XCTAssertFalse(panes.isEmpty)
    for p in panes {
      XCTAssertNotNil(p["agentSessionId"], "各ペイン行に agentSessionId キーが存在する")
      XCTAssertTrue(p["agentSessionId"] is NSNull, "report_agent 未適用なら null")
    }
  }

  // MARK: - controlListAgents（list_agents）

  /// 検出未完了（起動直後は AgentCatalog.refresh が非同期で未反映）の WindowController では
  /// controlListAgents は空配列を返す（エラーにも nil にもしない＝空許容の契約）。
  func testListAgentsEmptyBeforeDetectionReturnsEmptyArrayNotError() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    XCTAssertEqual(wc.controlListAgents().count, 0, "検出未完了なら空配列（エラー化しない）")
  }

  /// AgentCLI → JSON 行の写像契約: command と解決済み絶対 path を string で保つ（検出源に依らず固定）。
  func testAgentRowsMapCommandAndPath() {
    let rows = WindowController.agentRows([
      AgentCLI(command: "claude", path: "/opt/homebrew/bin/claude"),
      AgentCLI(command: "codex", path: "/usr/local/bin/codex"),
    ])
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0]["command"] as? String, "claude")
    XCTAssertEqual(rows[0]["path"] as? String, "/opt/homebrew/bin/claude")
    XCTAssertEqual(rows[1]["command"] as? String, "codex")
    XCTAssertEqual(rows[1]["path"] as? String, "/usr/local/bin/codex")
  }

  /// 空入力は空配列（空時の挙動を写像レベルでも固定）。
  func testAgentRowsEmptyInputIsEmpty() {
    XCTAssertTrue(WindowController.agentRows([]).isEmpty)
  }

  // MARK: - controlConfigSet / controlRemoveWorkspace のエラー契約（ライブ反映前の guard）

  /// 完了条件7-③: config_set は default-agent の workspace スコープを受理する（全設定 WS 可）。
  /// アクティブ WS の上書き層へ書かれる。
  func testConfigSetAcceptsDefaultAgentWithWorkspaceScope() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let result = wc.controlConfigSet(
      key: SettingsRegistry.confKey(.defaultAgent), value: "claude", scope: "workspace",
      workspaceId: nil)
    guard case .success = result else {
      return XCTFail("default-agent + workspace は受理される")
    }
    XCTAssertEqual(
      wc.current.settingsOverride?[SettingKeys.defaultAgent], "claude", "WS 上書き層へ書かれる")
  }

  /// 完了条件7-③: config_set は dev-features を受理する（旧 read-only 拒否は撤廃）。
  func testConfigSetAcceptsDevFeatures() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let result = wc.controlConfigSet(
      key: SettingsRegistry.confKey(.devFeaturesEnabled), value: true, scope: "workspace",
      workspaceId: nil)
    guard case .success = result else { return XCTFail("dev-features は受理される") }
    XCTAssertEqual(wc.current.settingsOverride?[SettingKeys.devFeaturesEnabled], true)
  }

  /// config_set は未知 scope を -32602 で弾く（global/workspace 以外は受け付けない）。
  func testConfigSetRejectsInvalidScope() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let result = wc.controlConfigSet(
      key: "font-size", value: 14, scope: "session", workspaceId: nil)
    guard case .failure(let err) = result else { return XCTFail("未知 scope は failure") }
    XCTAssertEqual(err.code, -32602, "invalid scope の invalid params")
  }

  /// remove_workspace は最後の 1 つを -32000 で弾く（closeWorkspace の no-op を CLI へ明示エラー化）。
  func testRemoveLastWorkspaceIsRejected() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("solo")])
    let id = try XCTUnwrap(row(wc, name: "solo")?["id"] as? Int)
    guard case .failure(let err) = wc.controlRemoveWorkspace(workspaceId: id) else {
      return XCTFail("最後の 1 つの削除は failure")
    }
    XCTAssertEqual(err.code, -32000, "cannot remove last workspace")
  }

  /// remove_workspace は未知 id を -32004 で弾く（workspace not found）。
  func testRemoveUnknownWorkspaceIsRejected() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("other")])
    guard case .failure(let err) = wc.controlRemoveWorkspace(workspaceId: 999_999) else {
      return XCTFail("未知 id の削除は failure")
    }
    XCTAssertEqual(err.code, -32004, "workspace not found")
  }

  // MARK: - controlSetWorkspaceRoot（set_workspace_root）

  /// set_workspace_root は rootPath を更新し `~` をホーム展開する（GUI のディレクトリ変更と同一意味論）。
  func testSetWorkspaceRootUpdatesRootPath() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let id = try XCTUnwrap(row(wc, name: "main")?["id"] as? Int)
    let result = wc.controlSetWorkspaceRoot(workspaceId: id, rootPath: "~/some-dir")
    guard case .success(let value) = result else {
      return XCTFail("有効 id への rootPath 設定は success")
    }
    XCTAssertEqual((value as? [String: Any])?["ok"] as? Bool, true)
    XCTAssertEqual(
      row(wc, name: "main")?["rootPath"] as? String,
      ("~/some-dir" as NSString).expandingTildeInPath, "`~` はホーム展開して格納される")
  }

  /// set_workspace_root は未知 id を -32004 で弾く（workspace not found）。
  func testSetWorkspaceRootUnknownWorkspaceIsRejected() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let result = wc.controlSetWorkspaceRoot(workspaceId: 999_999, rootPath: "/tmp")
    guard case .failure(let err) = result else {
      return XCTFail("未知 id への rootPath 設定は failure")
    }
    XCTAssertEqual(err.code, -32004, "workspace not found")
  }

  /// set_workspace_root は trim 後空の rootPath を -32602 で弾き、rootPath を変えない。
  func testSetWorkspaceRootEmptyPathIsRejected() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let id = try XCTUnwrap(row(wc, name: "main")?["id"] as? Int)
    guard case .failure(let err) = wc.controlSetWorkspaceRoot(workspaceId: id, rootPath: "   ")
    else { return XCTFail("空 rootPath は failure") }
    XCTAssertEqual(err.code, -32602, "workspace rootPath is empty")
    XCTAssertEqual(row(wc, name: "main")?["rootPath"] as? String, "/tmp", "rootPath は据え置き")
  }

  // MARK: - controlSpawn の cwd フォールバック（spawn）

  /// cwd 省略の spawn は対象 workspace の rootPath で開く（0タブ＝ペイン不在のフォールバック）。
  /// GUI（Cmd+T）の newSurfaceCwd と同一意味論で、従来の「常にホーム」ギャップの是正。
  func testSpawnWithoutCwdFallsBackToWorkspaceRootPath() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [WorkspaceState(name: "empty", rootPath: "/tmp/empty-root", activeTab: 0, tabs: [])])
    let id = try XCTUnwrap(row(wc, name: "empty")?["id"] as? Int)
    let paneId = try XCTUnwrap(
      wc.controlSpawn(workspaceId: id, cwd: nil, command: nil), "0タブ WS への spawn は成功する")
    let pane = wc.controlListPanes().first { $0["paneId"] as? Int == paneId }
    XCTAssertEqual(
      pane?["cwd"] as? String, "/tmp/empty-root", "cwd 省略はホームでなく対象 WS の rootPath")
  }

  /// cwd 省略で非アクティブ workspace へ spawn しても、アクティブ側でなく**対象 workspace の**
  /// rootPath へフォールバックする（フォールバック解決は対象 workspace 基準の契約）。
  func testSpawnWithoutCwdIntoInactiveWorkspaceUsesItsRootPath() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed("main"),  // rootPath "/tmp" のアクティブ WS
        WorkspaceState(name: "bg", rootPath: "/tmp/bg-root", activeTab: 0, tabs: []),
      ])
    let bgId = try XCTUnwrap(row(wc, name: "bg")?["id"] as? Int)
    let paneId = try XCTUnwrap(
      wc.controlSpawn(workspaceId: bgId, cwd: nil, command: nil), "背景 WS への spawn は成功する")
    let pane = wc.controlListPanes().first { $0["paneId"] as? Int == paneId }
    XCTAssertEqual(
      pane?["cwd"] as? String, "/tmp/bg-root", "対象（背景）WS の rootPath で開く")
    XCTAssertEqual(wc.window.title, "main", "アクティブ WS は変わらない")
  }

  /// 活性（activated==true）workspace は復元 agent leaf を持っていても dormantAgentCount が 0。
  /// dormantAgentCount は未起動行の zzz 専用の永続 leaf カウントで、活性 WS では stale。パレット
  /// （活性行は live な agentCounts を使う）と契約を揃え、live と dormant の二重計上を防ぐ。
  func testListWorkspacesActiveWorkspaceReportsZeroDormantAgentCount() throws {
    let sleepers = PaneNode.split(
      vertical: true, ratio: 0.5, first: agentLeaf("a"), second: agentLeaf("b"))
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed("active", tree: sleepers),  // 活性かつ復元 agent 2（永続 leaf は在る）
        tabbed("dormant", tree: sleepers),  // 非活性で復元 agent 2
      ])
    XCTAssertEqual(row(wc, name: "active")?["active"] as? Bool, true, "前提: active 行は活性")
    XCTAssertEqual(
      row(wc, name: "active")?["dormantAgentCount"] as? Int, 0,
      "活性 WS は復元 agent leaf があっても dormantAgentCount は 0")
    XCTAssertEqual(
      row(wc, name: "dormant")?["dormantAgentCount"] as? Int, 2,
      "非活性 WS は永続 agent leaf 2 を保持")
  }
}
