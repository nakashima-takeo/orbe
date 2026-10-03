import AppKit
import XCTest

@testable import Orbe

/// worktree パレットがリポジトリを探す基点（`WorktreePaletteDataProvider` に渡す cwd）と、0 タブの workspace で
/// Enter したときに開くタブを固定する。基点は「この workspace で新タブを開くならどこから始まるか」——
/// アクティブタブの cwd、0 タブならその workspace の root path。
///
/// 壊れると何が起きるか: 0 タブの workspace で ⌘T を押すと非 git のホームを探しに行き、全セクションが
/// 空のまま Enter も効かない（パレットが袋小路になる）。逆に root path を常に基点にすると、タブで別の
/// リポジトリへ cd して使っている人に、居る場所と無関係なリポジトリの行が並ぶ。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
@MainActor
final class WindowControllerWorktreePaletteBaseTests: OrbeTestCase {

  private func restore(_ workspace: WorkspaceState) throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0, workspaces: [workspace])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  func testZeroTabWorkspaceSearchesRepositoryFromItsRootPath() throws {
    let wc = try restore(
      WorkspaceState(name: "zero", rootPath: "/tmp/ws-root", activeTab: 0, tabs: []))
    XCTAssertTrue(wc.current.tabs.isEmpty, "前提: アクティブ workspace は 0 タブ")

    wc.showWorktreePalette()
    defer { wc.dismissPalette() }

    XCTAssertEqual(
      wc.model.worktreePaletteProvider?.cwd, "/tmp/ws-root",
      "0 タブでは workspace の root path から探す（ホームではない）")
  }

  func testWorkspaceWithTabsSearchesRepositoryFromActiveTabCwd() throws {
    let wc = try restore(
      WorkspaceState(
        name: "main", rootPath: "/tmp/ws-root", activeTab: 0,
        tabs: [TabState(cwd: "/tmp/tab", agent: nil, explicitTitle: nil)]))
    try XCTUnwrap(wc.current.tabs.first).surface.currentPwd = "/tmp/tab/elsewhere"

    wc.showWorktreePalette()
    defer { wc.dismissPalette() }

    XCTAssertEqual(
      wc.model.worktreePaletteProvider?.cwd, "/tmp/tab/elsewhere",
      "タブがあればアクティブタブの実効 cwd から探す（root path ではない）")
  }

  func testEnterInZeroTabWorkspaceOpensTabAtResolvedWorktreeInThatWorkspace() throws {
    let repo = try makeRepository()
    let wc = try restore(WorkspaceState(name: "zero", rootPath: repo, activeTab: 0, tabs: []))
    XCTAssertTrue(wc.current.tabs.isEmpty, "前提: アクティブ workspace は 0 タブ")
    let toplevel = GitRunner.shared.runSync(["rev-parse", "--show-toplevel"], cwd: repo)
      .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)

    wc.showWorktreePalette()
    let palette = try XCTUnwrap(wc.model.worktreePalette)
    XCTAssertTrue(
      pump { palette.items.contains { $0.action == .open(.directory(path: toplevel)) } },
      "root path のリポジトリの worktree 行が並ぶ")
    palette.chooseTarget(at: try XCTUnwrap(palette.targets.firstIndex(of: .shell)))
    let row = try XCTUnwrap(
      palette.items.firstIndex { $0.action == .open(.directory(path: toplevel)) })

    palette.activate(at: row)

    XCTAssertEqual(wc.model.overlay, .none, "パレットは閉じる")
    XCTAssertEqual(wc.current.name, "zero", "開くのは worktree パレットを開いた workspace")
    XCTAssertEqual(wc.current.tabs.map(\.cwd), [toplevel], "選んだ行の解決先で新タブが 1 枚開く")
    let opened = try XCTUnwrap(wc.current.tabs.first)
    XCTAssertTrue(
      pump { wc.window.firstResponder === opened.surface }, "キー入力はその新タブの surface へ入る")
  }

  /// 開いた後に（制御 API 等で）アクティブな workspace が替わっても、タブは開いた workspace に開く。
  func testEnterOpensTheTabInTheWorkspaceThePaletteWasOpenedIn() throws {
    let repo = try makeRepository()
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "opened", rootPath: repo, activeTab: 0, tabs: []),
        WorkspaceState(name: "other", rootPath: "/tmp", activeTab: 0, tabs: []),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    let toplevel = GitRunner.shared.runSync(["rev-parse", "--show-toplevel"], cwd: repo)
      .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)

    wc.showWorktreePalette()
    let palette = try XCTUnwrap(wc.model.worktreePalette)
    XCTAssertTrue(
      pump { palette.items.contains { $0.action == .open(.directory(path: toplevel)) } })
    palette.chooseTarget(at: try XCTUnwrap(palette.targets.firstIndex(of: .shell)))
    wc.switchWorkspace(to: 1)
    XCTAssertEqual(wc.current.name, "other", "前提: アクティブな workspace が替わった")

    palette.activate(
      at: try XCTUnwrap(
        palette.items.firstIndex { $0.action == .open(.directory(path: toplevel)) }))

    XCTAssertEqual(wc.workspaces[0].tabs.map(\.cwd), [toplevel], "開いた workspace にタブが開く")
    XCTAssertTrue(wc.workspaces[1].tabs.isEmpty, "切り替わった先の workspace には開かない")
  }

  /// root path に置く 1 コミットのリポジトリ（origin 無し＝gh へは問い合わせない）。
  private func makeRepository() throws -> String {
    let dir = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("repo").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "x".write(
      toFile: (dir as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    for args in [
      ["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"],
      ["config", "user.name", "t"], ["add", "-A"], ["commit", "-qm", "init"],
    ] {
      XCTAssertTrue(GitRunner.shared.runSync(args, cwd: dir).isSuccess, "git \(args[0])")
    }
    return dir
  }

  /// main queue を回しながら条件の成立を待つ（provider の completion と次 tick のフォーカス確定は main で届く）。
  private func pump(_ condition: () -> Bool, timeout: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
      usleep(5_000)
    }
    return condition()
  }
}

/// パレットは開いた時点の workspace に結び付く。前回のベースはその workspace から読み、作成に成功したら
/// その workspace へ書く。
@MainActor
final class WorktreePaletteWorkspaceBindingTests: OrbeTestCase {

  private func restore(_ workspaces: [WorkspaceState]) throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0, workspaces: workspaces)
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  /// 前回のベースは、開いた workspace の値を provider に渡す（再起動後も読み戻る）。
  func testPreviousBaseIsReadFromTheOpeningWorkspace() throws {
    let wc = try restore([
      WorkspaceState(
        name: "a", rootPath: "/tmp/a", activeTab: 0, tabs: [], lastWorktreeBase: "origin/rel"),
      WorkspaceState(name: "b", rootPath: "/tmp/b", activeTab: 0, tabs: []),
    ])
    wc.showWorktreePalette()
    XCTAssertEqual(wc.model.worktreePaletteProvider?.previousBase, "origin/rel")
    wc.dismissPalette()

    wc.switchWorkspace(to: 1)
    wc.showWorktreePalette()
    defer { wc.dismissPalette() }
    XCTAssertNil(wc.model.worktreePaletteProvider?.previousBase, "別の workspace の前回は読まない")
  }

  /// 書き込みはその workspace にだけ効き、閉じた workspace には書かない。
  func testRememberWritesOnlyToALiveWorkspace() throws {
    let wc = try restore([
      WorkspaceState(name: "a", rootPath: "/tmp/a", activeTab: 0, tabs: []),
      WorkspaceState(name: "b", rootPath: "/tmp/b", activeTab: 0, tabs: []),
    ])
    let a = wc.workspaces[0]
    let b = wc.workspaces[1]
    wc.rememberWorktreeBase("origin/main", in: b)
    XCTAssertNil(a.lastWorktreeBase)
    XCTAssertEqual(b.lastWorktreeBase, "origin/main")

    wc.closeWorkspace(1, origin: .gesture)
    wc.rememberWorktreeBase("origin/dev", in: b)
    XCTAssertEqual(b.lastWorktreeBase, "origin/main", "閉じた workspace には書かない")
  }
}
