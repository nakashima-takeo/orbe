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
///
/// 休眠 workspace が list_workspaces / list_tabs にどう写るかは分割した拡張ファイル
/// `+DormantProjection` が測る。ハーネス（`restore` / `tabbed` / `agentLeaf` / `row`）は本体が持つ。
final class WindowControllerControlTests: OrbeTestCase {

  // MARK: - fixtures / helpers

  /// resume 未対応 agent を載せたタブ（消費時に素シェル化するが休眠チケットには数える）。
  func agentTab(_ id: String) -> TabState {
    TabState(
      cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: id), explicitTitle: nil)
  }

  static let plainTab = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)

  /// 素のシェルタブ 1 枚（既定）または指定タブ群を持つ workspace 状態。
  func tabbed(_ name: String, tabs: [TabState] = [plainTab]) -> WorkspaceState {
    WorkspaceState(name: name, rootPath: "/tmp", activeTab: 0, tabs: tabs)
  }

  /// ディスクへ workspaces を書いてから復元済み WindowController を返す。
  func restore(activeWorkspace: Int, _ workspaces: [WorkspaceState]) throws
    -> WindowController
  {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: activeWorkspace,
      workspaces: workspaces)
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  /// controlListWorkspaces から (name==) の行を引く。
  func row(_ wc: WindowController, name: String) -> [String: Any]? {
    wc.controlListWorkspaces().first { $0["name"] as? String == name }
  }

  // MARK: - controlActivateWorkspace

  /// 背景（active==false）workspace を activate すると、その workspace がアクティブになり、
  /// 戻り値は自身の id と当該 workspace のタブ ID 群（非空）。
  func testActivateBackgroundWorkspaceMakesItActiveAndReturnsTabIds() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("background")])
    XCTAssertEqual(wc.window.title, "main")

    let bg = try XCTUnwrap(row(wc, name: "background"))
    let bgId = try XCTUnwrap(bg["id"] as? Int)
    XCTAssertEqual(bg["active"] as? Bool, false, "activate 前は背景（非アクティブ）")

    let result = try XCTUnwrap(
      wc.controlActivateWorkspace(workspaceId: bgId), "既知 id の activate は非 nil")
    XCTAssertEqual(result.activeWorkspaceId, bgId, "戻りの activeWorkspaceId は指定した背景 WS 自身")
    XCTAssertFalse(result.tabIds.isEmpty, "全タブ mount 後のタブ ID 群を返す")
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
    XCTAssertEqual(again.tabIds, before.tabIds, "冪等: タブ集合は増えも変わりもしない")
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

  /// 返す tabIds は `list_tabs`（controlListTabs）の当該 workspace 導出と一致する
  /// （activate 応答と後続 list_tabs がズレない契約）。
  func testActivateReturnedTabIdsMatchListTabsDerivation() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [tabbed("main"), tabbed("background", tabs: [Self.plainTab, Self.plainTab])])
    let bgId = try XCTUnwrap(row(wc, name: "background")?["id"] as? Int)

    let result = try XCTUnwrap(wc.controlActivateWorkspace(workspaceId: bgId))
    let fromListTabs = wc.controlListTabs()
      .filter { $0["workspaceId"] as? Int == bgId }
      .compactMap { $0["tabId"] as? Int }
    XCTAssertEqual(result.tabIds.count, 2, "2 タブ分の id を返す")
    XCTAssertEqual(result.tabIds, fromListTabs, "activate の tabIds は list_tabs と同一導出")
  }

  /// 0タブの休眠 workspace を activate すると、前面化はするがシェルは自動起動せず、
  /// tabIds は空配列で返る（0タブ空状態の表示・自動起こしなしの契約）。
  func testActivateEmptyDormantWorkspaceShowsEmptyAndReturnsNoTabs() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed("main"),
        WorkspaceState(name: "empty", rootPath: "/tmp", activeTab: 0, tabs: []),  // 0タブ休眠
      ])
    let emptyId = try XCTUnwrap(row(wc, name: "empty")?["id"] as? Int)

    let result = try XCTUnwrap(wc.controlActivateWorkspace(workspaceId: emptyId))
    XCTAssertEqual(result.activeWorkspaceId, emptyId)
    XCTAssertTrue(result.tabIds.isEmpty, "0タブ WS はシェルを起こさず tabIds は空配列")
    XCTAssertEqual(wc.window.title, "empty", "0タブ WS も activate で前面化する")
    let projected = try XCTUnwrap(row(wc, name: "empty"))
    XCTAssertEqual(projected["active"] as? Bool, true)
    XCTAssertEqual(projected["activated"] as? Bool, false, "前面選択と起床済みタブの有無は別軸")
    XCTAssertEqual(projected["dormantAgentCount"] as? Int, 0)
  }

  // MARK: - controlListWorkspaces の dormantAgentCount 露出

  /// list_workspaces の全行に dormantAgentCount フィールドが Int で出る（休眠可視化の源）。
  func testListWorkspacesExposesDormantAgentCountOnEveryRow() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("background")])
    let rows = wc.controlListWorkspaces()
    XCTAssertFalse(rows.isEmpty)
    for r in rows {
      XCTAssertNotNil(r["activated"] as? Bool, "各行に activated(Bool) が露出する")
      XCTAssertNotNil(r["dormantAgentCount"] as? Int, "各行に dormantAgentCount(Int) が露出する")
    }
  }

  /// 休眠 workspace の dormantAgentCount は永続復元した agent 付きタブ数を反映する
  /// （agentState には出ない休眠 agent を、この永続カウントで露出する）。
  func testListWorkspacesDormantAgentCountReflectsPersistedAgents() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [
        tabbed("main"),
        tabbed("sleepers", tabs: [agentTab("a"), agentTab("b")]),  // 休眠 agent 2
        tabbed("quiet"),  // 休眠 agent 0
      ])
    XCTAssertEqual(
      row(wc, name: "sleepers")?["dormantAgentCount"] as? Int, 2, "永続 agent タブ 2 を反映")
    XCTAssertEqual(
      row(wc, name: "quiet")?["dormantAgentCount"] as? Int, 0, "agent 無しの休眠 WS は 0")
  }

  // MARK: - controlListTabs の agentSessionId 露出

  /// list_tabs の各タブに agentSessionId フィールドが出る。report_agent 未適用のタブは
  /// null（NSNull）で、agentState と同じ null 許容の写し方に揃う（resume の鍵）。
  func testListTabsExposesAgentSessionIdAsNullWhenUnset() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let tabs = wc.controlListTabs()
    XCTAssertFalse(tabs.isEmpty)
    for t in tabs {
      XCTAssertNotNil(t["agentSessionId"], "各タブ行に agentSessionId キーが存在する")
      XCTAssertTrue(t["agentSessionId"] is NSNull, "report_agent 未適用なら null")
    }
  }

  /// 休眠（未消費チケット）タブは、同一性（agentSessionId）は露出するが状態（agentState）は
  /// 出さない——報告は live にしか存在しないため。resume 非対応 CLI で固定する: resume 可能な
  /// 休眠は従来から値が出ており、「復元時に解決できないチケットを捨てる」設計への差し戻しは
  /// 未対応 CLI 側でしか観測できない。orbe-cli / orbe-mcp は agentSessionId を resume の鍵、
  /// agentState を状態として別軸で読む。
  func testListTabsExposesDormantTicketSessionIdWithoutState() throws {
    let wc = try restore(
      activeWorkspace: 0, [tabbed("main"), tabbed("sleeping", tabs: [agentTab("zzz")])])
    XCTAssertEqual(
      row(wc, name: "sleeping")?["activated"] as? Bool, false, "前提: 未 activate＝チケットは未消費")

    let tab = try XCTUnwrap(
      wc.controlListTabs().first { $0["workspaceName"] as? String == "sleeping" })

    XCTAssertEqual(tab["agentSessionId"] as? String, "zzz", "休眠のあいだも resume の鍵は見える")
    XCTAssertTrue(tab["agentState"] is NSNull, "休眠タブに報告状態は無い")
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

  /// create_workspace も、渡された rootPath が trim 後空なら -32602 で弾き workspace を作らない。
  ///
  /// 壊れると何が起きるか: rootPath が空白だけの workspace ができる。rootPath はその WS の全タブの
  /// cwd と worktree の基点なので、以後そこで開くタブもエージェントも意図と違う場所で走る。
  /// `set_workspace_root` が同じ値を -32602 で弾くのに `create_workspace` だけ通す割れ方になる。
  func testCreateWorkspaceEmptyRootPathIsRejected() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let before = wc.workspaces.count
    guard case .failure(let err) = wc.controlCreateWorkspace(name: "proj", rootPath: "   ")
    else { return XCTFail("空 rootPath での作成は failure") }
    XCTAssertEqual(err.code, -32602, "workspace rootPath is empty")
    XCTAssertEqual(wc.workspaces.count, before, "弾いた作成で workspace が増えない")
  }

  // MARK: - controlSpawn の cwd フォールバック（spawn）

  /// cwd 省略の spawn は対象 workspace の rootPath で開く（0タブ＝タブ不在のフォールバック）。
  /// GUI（Cmd+T）の newTabCwd と同一意味論で、従来の「常にホーム」ギャップの是正。
  func testSpawnWithoutCwdFallsBackToWorkspaceRootPath() throws {
    let wc = try restore(
      activeWorkspace: 0,
      [WorkspaceState(name: "empty", rootPath: "/tmp/empty-root", activeTab: 0, tabs: [])])
    let id = try XCTUnwrap(row(wc, name: "empty")?["id"] as? Int)
    let tabId = try XCTUnwrap(
      wc.controlSpawn(workspaceId: id, cwd: nil, command: nil), "0タブ WS への spawn は成功する")
    let tab = wc.controlListTabs().first { $0["tabId"] as? Int == tabId }
    XCTAssertEqual(
      tab?["cwd"] as? String, "/tmp/empty-root", "cwd 省略はホームでなく対象 WS の rootPath")
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
    let tabId = try XCTUnwrap(
      wc.controlSpawn(workspaceId: bgId, cwd: nil, command: nil), "背景 WS への spawn は成功する")
    let tab = wc.controlListTabs().first { $0["tabId"] as? Int == tabId }
    XCTAssertEqual(
      tab?["cwd"] as? String, "/tmp/bg-root", "対象（背景）WS の rootPath で開く")
    XCTAssertEqual(wc.window.title, "main", "アクティブ WS は変わらない")
  }
}
