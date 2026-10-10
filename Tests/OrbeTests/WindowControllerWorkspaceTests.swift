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

  /// 切替で往復しても workspace 集合は失われない（条件7 の観測可能な側面）。
  /// 戻った先の名前が保たれていることは、その workspace が削除/再生成されていない証左。
  func testRoundTripSwitchPreservesWorkspaces() {
    let wc = WindowController()
    wc.createWorkspace(name: "alpha", rootPath: "/tmp/ws-alpha")
    let alpha = wc.activeWorkspace
    wc.createWorkspace(name: "beta", rootPath: "/tmp/ws-beta")
    let beta = wc.activeWorkspace
    XCTAssertEqual(wc.window.title, "beta")

    wc.switchWorkspace(to: 0)  // default
    XCTAssertEqual(wc.window.title, "default")
    wc.switchWorkspace(to: alpha)  // alpha（消えていない）
    XCTAssertEqual(wc.window.title, "alpha", "離れて戻っても alpha は生存（名前保持）")
    wc.switchWorkspace(to: beta)  // beta（消えていない）
    XCTAssertEqual(wc.window.title, "beta", "離れて戻っても beta は生存（名前保持）")
  }

  /// 改名はアクティブ workspace の title に反映される（条件6 の改名・host 側）。
  func testRenameActiveWorkspaceUpdatesTitle() {
    let wc = WindowController()
    wc.createWorkspace(name: "old", rootPath: "/tmp/ws-old")
    wc.renameWorkspace(wc.activeWorkspace, to: "new")
    XCTAssertEqual(wc.window.title, "new", "アクティブ workspace の改名は title に反映")
  }

  /// 非アクティブ workspace を改名しても、改名後にそこへ切り替えると新名が見える（条件6・観測）。
  func testRenameInactiveWorkspaceIsRetained() {
    let wc = WindowController()
    wc.createWorkspace(name: "tmp", rootPath: "/tmp/ws-tmp")
    let tmp = wc.activeWorkspace
    wc.switchWorkspace(to: 0)  // default をアクティブに
    wc.renameWorkspace(tmp, to: "renamed")  // 非アクティブを改名
    XCTAssertEqual(wc.window.title, "default", "非アクティブの改名はアクティブ title を変えない")
    wc.switchWorkspace(to: tmp)
    XCTAssertEqual(wc.window.title, "renamed", "切替後に改名後の名前が見える")
  }

  /// アクティブ workspace を削除すると別 workspace に切り替わる（条件6 の削除・active ケース）。
  func testCloseActiveWorkspaceSwitchesToAnother() {
    let wc = WindowController()
    wc.createWorkspace(name: "second", rootPath: "/tmp/ws-second")
    XCTAssertEqual(wc.window.title, "second")
    wc.closeWorkspace(wc.activeWorkspace, origin: .gesture)  // アクティブ自身を削除
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

  /// 壊れた JSON を置いて起動するとクラッシュせず既定の単一 workspace(default) で開く（条件4・host 側）。
  func testCorruptDiskFallsBackToDefaultOnLaunch() throws {
    try Data("{ broken json ]".utf8).write(to: workspacesFile())
    let wc = WindowController()
    XCTAssertEqual(
      wc.window.title, "default",
      "壊れた JSON のときはクラッシュせず既定 workspace(default) で起動")
  }

  /// workspace パレットが行を MRU（lastUsedAt 降順）で並べる。最上段の Home と 2 段目の起源の後は、
  /// 永続 lastUsedAt の降順、nil（未使用）は最古で末尾。
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
      names, ["Home", "alpha", "newer", "older", "never"],
      "Home → 起源 → lastUsedAt 降順 → nil 末尾（MRU 並び）")
  }

  /// Home が最上段、起源 workspace（配列で最初の通常 workspace）が 2 段目に MRU より優先して固定される。
  /// Home が配列先頭にあっても起源にはならず、起源を最近使わず（最古）他を新しく使っても 2 段目のまま。
  /// 残りは MRU 順。
  func testPalettePinsHomeThenOriginWorkspace() throws {
    let t1 = Date(timeIntervalSinceReferenceDate: 1_000)
    let t2 = Date(timeIntervalSinceReferenceDate: 2_000)
    let t3 = Date(timeIntervalSinceReferenceDate: 3_000)
    func state(_ name: String, _ stamp: Date?) -> WorkspaceState {
      WorkspaceState(
        name: name, rootPath: "/", activeTab: 0,
        tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)],
        lastUsedAt: stamp)
    }
    // activeWorkspace=3（newer）が復元時 now 再刻印で最新。origin は最古 t1 だが固定で 2 段目。
    let home = WorkspaceState(name: "Home", rootPath: "/", activeTab: 0, tabs: [])
    WorkspacePersistence.save(
      WorkspacesFile(
        version: WorkspacePersistence.version, activeWorkspace: 3,
        workspaces: [
          home, state("origin", t1), state("older", t2), state("newer", t3),
        ], homeWorkspaceId: home.persistentId))

    let wc = WindowController()  // 上記をディスクから復元
    wc.showWorkspacePalette()
    let rows = try XCTUnwrap(wc.model.workspacePalette?.render.rows)
    let names = rows.dropLast().map(\.label)
    XCTAssertEqual(
      names, ["Home", "origin", "newer", "older"],
      "Home → 最初の通常 workspace（最古でも固定）→ 残りは MRU（now 再刻印の newer → older）")
  }

  /// 新規の state では default（active・タブ 1 枚）と Home（0 タブ）の 2 つで起動し、パレットの行は
  /// SessionStore の判断どおりに詳細メニューを出し分ける——Home の行は改名だけ、通常が 1 つだけの default は削除なし。
  func testFreshLaunchHasDefaultAndHomeWithPaletteActionsFromTheStore() throws {
    let wc = WindowController()
    XCTAssertEqual(wc.workspaces.map(\.name), ["default", "Home"])
    XCTAssertEqual(wc.activeWorkspace, 0)
    XCTAssertEqual(wc.workspaces.map(\.tabs.count), [1, 0])

    wc.showWorkspacePalette()
    let items = try XCTUnwrap(wc.model.workspacePalette?.items)
    XCTAssertEqual(items.map(\.name), ["Home", "default"])
    XCTAssertEqual(items.map(\.canSetDir), [false, true])
    XCTAssertEqual(items.map(\.canClose), [false, false])

    wc.dismissPalette()
    wc.createWorkspace(name: "second", rootPath: "/tmp/ws-second")
    wc.showWorkspacePalette()
    let after = try XCTUnwrap(wc.model.workspacePalette?.items)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: after.map { ($0.name, $0.canClose) }),
      ["Home": false, "default": true, "second": true], "通常が 2 つ以上なら default も消せる")
  }
}
