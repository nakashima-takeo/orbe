import AppKit
import XCTest

@testable import Orbe

/// Dispatch パレットがリポジトリを探す基点（`DispatchDataProvider` に渡す cwd）と、0 タブの workspace で
/// Enter したときに開くタブを固定する。基点は「この workspace で新タブを開くならどこから始まるか」——
/// アクティブタブの cwd、0 タブならその workspace の root path。
///
/// 壊れると何が起きるか: 0 タブの workspace で ⌘⇧X を押すと非 git のホームを探しに行き、全セクションが
/// 空のまま Enter も効かない（パレットが袋小路になる）。逆に root path を常に基点にすると、タブで別の
/// リポジトリへ cd して使っている人に、居る場所と無関係なリポジトリの行が並ぶ。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
@MainActor
final class WindowControllerDispatchBaseTests: OrbeTestCase {

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

    wc.showDispatchPalette()
    defer { wc.dismissPalette() }

    XCTAssertEqual(
      wc.model.dispatchProvider?.cwd, "/tmp/ws-root", "0 タブでは workspace の root path から探す（ホームではない）")
  }

  func testWorkspaceWithTabsSearchesRepositoryFromActiveTabCwd() throws {
    let wc = try restore(
      WorkspaceState(
        name: "main", rootPath: "/tmp/ws-root", activeTab: 0,
        tabs: [TabState(cwd: "/tmp/tab", agent: nil, explicitTitle: nil)]))
    try XCTUnwrap(wc.current.tabs.first).surface.currentPwd = "/tmp/tab/elsewhere"

    wc.showDispatchPalette()
    defer { wc.dismissPalette() }

    XCTAssertEqual(
      wc.model.dispatchProvider?.cwd, "/tmp/tab/elsewhere",
      "タブがあればアクティブタブの実効 cwd から探す（root path ではない）")
  }

  func testEnterInZeroTabWorkspaceOpensTabAtResolvedWorktreeInThatWorkspace() throws {
    let repo = try makeRepository()
    let wc = try restore(WorkspaceState(name: "zero", rootPath: repo, activeTab: 0, tabs: []))
    XCTAssertTrue(wc.current.tabs.isEmpty, "前提: アクティブ workspace は 0 タブ")
    let toplevel = GitRunner.shared.runSync(["rev-parse", "--show-toplevel"], cwd: repo)
      .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)

    wc.showDispatchPalette()
    let palette = try XCTUnwrap(wc.model.dispatchPalette)
    XCTAssertTrue(
      pump { palette.items.contains { $0.action == .worktree(path: toplevel) } },
      "root path のリポジトリの worktree 行が並ぶ")
    palette.selectedTargetIndex = try XCTUnwrap(palette.targets.firstIndex(of: .shell))
    let row = try XCTUnwrap(palette.items.firstIndex { $0.action == .worktree(path: toplevel) })

    palette.activate(at: row)

    XCTAssertEqual(wc.model.overlay, .none, "パレットは閉じる")
    XCTAssertEqual(wc.current.name, "zero", "開くのは Dispatch を開いた workspace")
    XCTAssertEqual(wc.current.tabs.map(\.cwd), [toplevel], "選んだ行の解決先で新タブが 1 枚開く")
    let opened = try XCTUnwrap(wc.current.tabs.first)
    XCTAssertTrue(
      pump { wc.window.firstResponder === opened.surface }, "キー入力はその新タブの surface へ入る")
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
