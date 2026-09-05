import AppKit
import XCTest

@testable import Orbe

/// WindowController の workspace ライフサイクル（host 側）の観測可能な契約を固定する。
///
/// 重要: TerminalTabTests と異なり、WindowController の構築は実 NSWindow に
/// SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
/// ヘッドレスな純ロジック検証ではない。GhosttyKit が同梱された本環境でのみ走る。
///
/// 観測は主に window.title（= 現アクティブ workspace 名）で行う——切替・作成・改名・削除の結果として
/// 「どれがアクティブか」が、このライフサイクルの契約そのものだから。title で表せないもの
/// （MRU 並び・休眠 rollup）はパレットの render を、ディスクへ届いたかは workspaces.json を読む。
final class WindowControllerWorkspaceTests: OrbeTestCase {

  /// 起動直後に既定 workspace "default" が1つ存在する（条件1 の一部）。
  func testStartsWithDefaultWorkspace() {
    let wc = WindowController()
    XCTAssertEqual(wc.window.title, "default", "起動時の既定 workspace 名は default")
  }

  /// 既存と一致しない名前で作成すると、その workspace がアクティブになる（条件4 の host 側）。
  func testCreateWorkspaceMakesItActive() {
    let wc = WindowController()
    wc.createWorkspace(name: "infra")
    XCTAssertEqual(wc.window.title, "infra", "作成した workspace がアクティブ（title に反映）")
  }

  /// 既存 workspace を選ぶと、その workspace に切り替わる（条件5 の host 側・観測は title）。
  func testSwitchWorkspaceChangesActive() {
    let wc = WindowController()
    wc.createWorkspace(name: "infra")  // index 1, active
    XCTAssertEqual(wc.window.title, "infra")
    wc.switchWorkspace(to: 0)  // default へ戻す
    XCTAssertEqual(wc.window.title, "default", "index 0 への切替で default がアクティブ")
  }

  /// 切替で往復しても workspace 集合は失われない（条件7 の観測可能な側面）。
  /// 戻った先の名前が保たれていることは、その workspace が削除/再生成されていない証左。
  func testRoundTripSwitchPreservesWorkspaces() {
    let wc = WindowController()
    wc.createWorkspace(name: "alpha")  // index 1
    wc.createWorkspace(name: "beta")  // index 2, active
    XCTAssertEqual(wc.window.title, "beta")

    wc.switchWorkspace(to: 0)  // default
    XCTAssertEqual(wc.window.title, "default")
    wc.switchWorkspace(to: 1)  // alpha（消えていない）
    XCTAssertEqual(wc.window.title, "alpha", "離れて戻っても alpha は生存（名前保持）")
    wc.switchWorkspace(to: 2)  // beta（消えていない）
    XCTAssertEqual(wc.window.title, "beta", "離れて戻っても beta は生存（名前保持）")
  }

  /// 改名はアクティブ workspace の title に反映される（条件6 の改名・host 側）。
  func testRenameActiveWorkspaceUpdatesTitle() {
    let wc = WindowController()
    wc.createWorkspace(name: "old")  // index 1, active
    wc.renameWorkspace(1, to: "new")
    XCTAssertEqual(wc.window.title, "new", "アクティブ workspace の改名は title に反映")
  }

  /// 非アクティブ workspace を改名しても、改名後にそこへ切り替えると新名が見える（条件6・観測）。
  func testRenameInactiveWorkspaceIsRetained() {
    let wc = WindowController()
    wc.createWorkspace(name: "tmp")  // index 1, active
    wc.switchWorkspace(to: 0)  // default をアクティブに
    wc.renameWorkspace(1, to: "renamed")  // 非アクティブ(index 1)を改名
    XCTAssertEqual(wc.window.title, "default", "非アクティブの改名はアクティブ title を変えない")
    wc.switchWorkspace(to: 1)
    XCTAssertEqual(wc.window.title, "renamed", "切替後に改名後の名前が見える")
  }

  /// 最後の1つは削除されない（条件6 の削除ガード）。
  func testCloseLastWorkspaceIsBlocked() {
    let wc = WindowController()
    // 既定1つだけの状態で削除を試みる → 何も起きず default が残る。
    wc.closeWorkspace(0)
    XCTAssertEqual(wc.window.title, "default", "workspace が最後の1つのときは削除されない")
  }

  /// 複数あるとき、非アクティブを削除でき、アクティブは維持される（条件6 の削除）。
  func testCloseInactiveWorkspaceKeepsActive() {
    let wc = WindowController()
    wc.createWorkspace(name: "keep")  // index 1, active
    wc.createWorkspace(name: "drop")  // index 2, active
    wc.switchWorkspace(to: 1)  // keep をアクティブに（drop は非アクティブ）
    XCTAssertEqual(wc.window.title, "keep")
    wc.closeWorkspace(2)  // 非アクティブ drop を削除
    XCTAssertEqual(wc.window.title, "keep", "非アクティブ削除後もアクティブは keep のまま")
  }

  /// アクティブ workspace を削除すると別 workspace に切り替わる（条件6 の削除・active ケース）。
  func testCloseActiveWorkspaceSwitchesToAnother() {
    let wc = WindowController()
    wc.createWorkspace(name: "second")  // index 1, active
    XCTAssertEqual(wc.window.title, "second")
    wc.closeWorkspace(1)  // アクティブ自身を削除
    XCTAssertEqual(wc.window.title, "default", "アクティブ削除後は残った workspace がアクティブ")
  }

  // MARK: - 0タブ（休眠）workspace のライフサイクル・ディレクトリ設定

  /// ディレクトリ設定（setWorkspaceDir）は workspace の rootPath を更新し永続する（~ はホーム展開）。
  func testSetWorkspaceDirPersists() throws {
    let wc = WindowController()
    wc.setWorkspaceDir(0, to: "/tmp/project")
    wc.flushSave()
    let file = try XCTUnwrap(WorkspacePersistence.load())
    XCTAssertEqual(file.workspaces[0].rootPath, "/tmp/project", "ディレクトリ設定が rootPath に保存される")

    wc.setWorkspaceDir(0, to: "~/proj")  // ~ はホーム展開して保存される
    wc.flushSave()
    let expanded = try XCTUnwrap(WorkspacePersistence.load())
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertEqual(expanded.workspaces[0].rootPath, home + "/proj", "~ はホーム展開して rootPath に保存される")
  }

  /// 0タブで保存された workspace を起動時アクティブにしても、クラッシュせずエントリは生き title に出る
  /// （空表示のまま・シェルは自動起動しない）。
  func testRestoreEmptyActiveWorkspaceShowsEmpty() throws {
    let old = Date(timeIntervalSinceReferenceDate: 10)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 1,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(name: "empty", rootPath: "/tmp", activeTab: 0, tabs: [], lastUsedAt: old),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())

    let before = Date()
    let wc = WindowController()
    XCTAssertEqual(
      wc.window.title, "empty", "0タブ workspace をアクティブ復元してもエントリは生き title に出る")
    XCTAssertFalse(wc.current.activated, "前面表示と materialize 済みタブの有無は別軸")
    XCTAssertGreaterThanOrEqual(
      try XCTUnwrap(wc.current.lastUsedAt), before, "0 タブでも前面利用は MRU を進める")
  }

  /// 0タブの休眠 workspace へ切替えてもエントリは消えず、空表示のまま title に出る（自動起動しない）。
  func testSwitchToEmptyWorkspaceKeepsItAndShowsEmpty() throws {
    let old = Date(timeIntervalSinceReferenceDate: 10)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(name: "dormant", rootPath: "/tmp", activeTab: 0, tabs: [], lastUsedAt: old),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())

    let wc = WindowController()
    XCTAssertEqual(wc.window.title, "main")
    wc.switchWorkspace(to: 1)  // 0タブ workspace へ切替 → 空表示のまま
    XCTAssertEqual(wc.window.title, "dormant", "0タブ workspace へ切替えてもエントリは生存し空表示で開く")
    XCTAssertFalse(wc.current.activated)
    XCTAssertGreaterThan(try XCTUnwrap(wc.current.lastUsedAt), old)
    wc.switchWorkspace(to: 0)
    wc.switchWorkspace(to: 1)
    XCTAssertEqual(wc.window.title, "dormant", "離れて戻っても dormant は消えていない")
  }

  // MARK: - ディスクからの再起動復元（条件2: 起動時に同じ構成・アクティブ workspace を復元）

  /// 事前に workspaces.json を書いてから WindowController を起動すると、
  /// 保存された activeWorkspace の workspace 名が title に出る（= アクティブ含め復元される）。
  func testRestoresActiveWorkspaceFromDiskOnLaunch() throws {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 1,  // 2 番目をアクティブにして保存
      workspaces: [
        WorkspaceState(
          name: "alpha", rootPath: "/tmp/alpha", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "bravo", rootPath: "/tmp/bravo", activeTab: 0,
          tabs: [
            TabState(cwd: "/tmp", agent: nil, explicitTitle: nil),
            TabState(cwd: "/tmp", agent: nil, explicitTitle: nil),
          ]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())

    let wc = WindowController()
    XCTAssertEqual(
      wc.window.title, "bravo",
      "起動時に保存された activeWorkspace(=bravo・2 タブ) が復元されアクティブになる")
    // 復元した非アクティブ workspace も生存している（切替で名前が見える）
    wc.switchWorkspace(to: 0)
    XCTAssertEqual(wc.window.title, "alpha", "保存された別 workspace(alpha) も復元されている")
  }

  /// 壊れた JSON を置いて起動するとクラッシュせず既定の単一 workspace(default) で開く（条件4・host 側）。
  func testCorruptDiskFallsBackToDefaultOnLaunch() throws {
    try Data("{ broken json ]".utf8).write(to: workspacesFile())
    let wc = WindowController()
    XCTAssertEqual(
      wc.window.title, "default",
      "壊れた JSON のときはクラッシュせず既定 workspace(default) で起動")
  }

  /// 既存 workspace 間の切替（switchWorkspace 経由）でアクティブに lastUsedAt が刻まれ、flushSave 後に
  /// ディスクへ残る（MRU 並べ替えキー）。刻印がディスクまで届いて初めて次回起動の並びが決まるので、
  /// 観測はモデルではなくディスク経由で行う。
  func testSwitchStampsLastUsedAtOnDisk() throws {
    let wc = WindowController()
    wc.createWorkspace(name: "infra")  // index 1, active
    let before = Date()
    wc.switchWorkspace(to: 0)  // default(index 0) へ切替 → default に lastUsedAt 刻印
    wc.flushSave()

    let file = try XCTUnwrap(WorkspacePersistence.load())
    let active = file.workspaces[file.activeWorkspace]
    XCTAssertEqual(active.name, "default", "切替先 default がアクティブ")
    let stamp = try XCTUnwrap(active.lastUsedAt, "切替でアクティブ workspace に lastUsedAt が刻まれる")
    XCTAssertGreaterThanOrEqual(stamp, before, "刻印時刻は切替操作の時点（now）")
  }

  /// workspace パレットが行を MRU（lastUsedAt 降順）で並べる。復元直後のアクティブは select 経由で
  /// now に再刻印され先頭、残りは永続 lastUsedAt の降順、nil（未使用）は最古で末尾。
  /// 並べ替えは host 側 reloadPalette が担うため、観測は model.workspacePalette.render.rows で行う。
  func testPaletteOrdersByMRU() throws {
    let t1 = Date(timeIntervalSinceReferenceDate: 1_000)
    let t2 = Date(timeIntervalSinceReferenceDate: 2_000)
    func state(_ name: String, _ stamp: Date?) -> WorkspaceState {
      WorkspaceState(
        name: name, rootPath: "/", activeTab: 0,
        tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)],
        lastUsedAt: stamp)
    }
    // activeWorkspace=0（alpha）は復元時に now で再刻印され先頭へ。残りは t2 > t1 > nil の順。
    WorkspacePersistence.save(
      WorkspacesFile(
        version: WorkspacePersistence.version, activeWorkspace: 0,
        workspaces: [
          state("alpha", nil), state("older", t1), state("newer", t2), state("never", nil),
        ]))

    let wc = WindowController()  // 上記をディスクから復元
    wc.showWorkspacePalette()
    let rows = try XCTUnwrap(wc.model.workspacePalette?.render.rows)
    let names = rows.dropLast().map(\.label)
    XCTAssertEqual(
      names, ["alpha", "newer", "older", "never"],
      "アクティブ先頭 → lastUsedAt 降順 → nil 末尾（MRU 並び）")
  }

  /// 起源 workspace（配列先頭 offset 0）は MRU より優先して常に最上位へ固定される。
  /// offset 0 を最近使わず（最古）他を新しく使っても、先頭は offset 0 のまま。残りは MRU 順。
  func testPalettePinsOriginWorkspaceFirst() throws {
    let t1 = Date(timeIntervalSinceReferenceDate: 1_000)
    let t2 = Date(timeIntervalSinceReferenceDate: 2_000)
    let t3 = Date(timeIntervalSinceReferenceDate: 3_000)
    func state(_ name: String, _ stamp: Date?) -> WorkspaceState {
      WorkspaceState(
        name: name, rootPath: "/", activeTab: 0,
        tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)],
        lastUsedAt: stamp)
    }
    // activeWorkspace=2（newer）が復元時 now 再刻印で最新。origin(offset0) は最古 t1 だが固定で先頭。
    WorkspacePersistence.save(
      WorkspacesFile(
        version: WorkspacePersistence.version, activeWorkspace: 2,
        workspaces: [
          state("origin", t1), state("older", t2), state("newer", t3),
        ]))

    let wc = WindowController()  // 上記をディスクから復元
    wc.showWorkspacePalette()
    let rows = try XCTUnwrap(wc.model.workspacePalette?.render.rows)
    let names = rows.dropLast().map(\.label)
    XCTAssertEqual(
      names, ["origin", "newer", "older"],
      "origin(offset 0) は最古でも常に先頭 → 残りは MRU（now 再刻印の newer → older）")
  }

  // MARK: - 休眠 agent 数（未 activated タブに残る復元 agent）

  /// TerminalTab(restoring:) の休眠は resume 未対応 agent（消費時に素シェル化する）も含めて
  /// 数える——resume 可否は消費まで判定しない。
  func testDormantIncludesResumeUnsupported() {
    let unsupported: TerminalTab.ResumeSpawn = { _ in nil }  // 消費時に素シェル化
    let tab = TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: "a"), explicitTitle: nil),
      resumeSpawn: unsupported)
    XCTAssertTrue(tab.isDormant, "resume 未対応でもチケットは消費まで休眠に数える")

    let plain = TerminalTab(cwd: "/tmp")
    XCTAssertFalse(plain.isDormant, "新規タブは休眠を持たない")
  }

  /// Workspace.dormantAgentCount() は休眠タブの数（下の fixture は全タブ未 activated）。
  func testDormantAgentCountCountsDormantTabs() {
    let resume: TerminalTab.ResumeSpawn = { _ in nil }
    let ws = Workspace(name: "sleepers", rootPath: "/tmp")
    for id in ["a", "b", "c"] {
      ws.tabs.append(
        TerminalTab(
          restoring: TabState(
            cwd: "/tmp", agent: AgentSession(command: "unknown", sessionId: id),
            explicitTitle: nil),
          resumeSpawn: resume))
    }
    ws.tabs.append(
      TerminalTab(
        restoring: TabState(cwd: "/tmp", agent: nil, explicitTitle: nil), resumeSpawn: resume))
    XCTAssertEqual(ws.dormantAgentCount(), 3, "休眠チケットを持つタブの数")
  }

  /// 構成を変えて flushSave すると実際にディスクへ書かれ、再起動相当の新 WindowController で復元される。
  func testFlushSaveThenReloadRestoresAcrossInstances() throws {
    let wc1 = WindowController()
    wc1.createWorkspace(name: "persisted")  // index 1, active
    wc1.flushSave()  // デバウンス待たず確定保存

    let saved = try workspacesFile()
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: saved.path), "flushSave で実ファイルが書かれる")

    let wc2 = WindowController()  // 再起動相当（同じ override path から load）
    XCTAssertEqual(wc2.window.title, "persisted", "新インスタンスがディスクから persisted をアクティブ復元")
  }
}
