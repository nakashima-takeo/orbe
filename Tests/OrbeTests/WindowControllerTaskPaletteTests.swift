import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// ⌘⇧X のタスク画面を実 `WindowController` から開き・閉じる配線を固定する。開いた workspace の写しと、
/// 画面を閉じる・別の画面へ差し替わるときの打ちかけの編集の確定。
///
/// 壊れると何が起きるか: タブが 0 枚の workspace でタスク画面が開かない。画面で足したタスクが、見ている
/// workspace ではなく別の workspace に付く。詳細を打ちかけのまま esc 以外で画面を閉じたり ⌘⌘ で
/// 差し替えたりすると、打った内容が黙って消える。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerTaskPaletteTests: OrbeTestCase {
  private let mainId = UUID()
  private let emptyId = UUID()

  /// 1 枚のタブを持つ main と、0 枚の empty（前面）を復元する。
  private func launchOnAnEmptyWorkspace() throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 1,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)], persistentId: mainId),
        WorkspaceState(
          name: "empty", rootPath: "/tmp", activeTab: 0, tabs: [], persistentId: emptyId),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    return WindowController()
  }

  private func openTaskPalette(_ wc: WindowController) throws -> TaskPaletteModel {
    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))
    XCTAssertEqual(wc.presentedOverlay, .taskPalette)
    return try XCTUnwrap(wc.model.taskPalette)
  }

  /// 詳細を打ちかけた状態。
  private func typeDescription(_ text: String, on palette: TaskPaletteModel) throws -> Int {
    let item = try palette.store.add(TaskDraft(title: "詳細を書く"))
    palette.reconcile()
    palette.jump(1)
    palette.enterDetail()
    palette.tapField(.description)
    palette.draftText = text
    return item.id
  }

  func testOpensOnAWorkspaceWithNoTabsAndAddsTasksToThatWorkspace() throws {
    let wc = try launchOnAnEmptyWorkspace()

    let palette = try openTaskPalette(wc)
    palette.query = "見積もりを出す"
    palette.submit()

    XCTAssertEqual(palette.workspaces.opened, .init(id: emptyId, name: "empty"))
    XCTAssertEqual(
      palette.workspaces.all.map(\.id), [mainId, emptyId, try XCTUnwrap(wc.store.orbeWorkspaceId)],
      "サイドバーの順（Orbe の workspace も選べる）")
    XCTAssertEqual(wc.taskStore.tasks.last?.workspace, emptyId, "画面を開いた workspace に付く")
  }

  /// GitHub タブのリポジトリは ⌘T と同じ基点（アクティブタブの cwd）で解決する——workspace の root が別の場所
  /// （既定 workspace の ~ など）でも、タブがいるリポジトリの Issue・PR を出す。
  func testTheGitHubTabResolvesTheRepositoryFromTheActiveTabsDirectory() throws {
    let caseDir = TestScratch.caseDir
    let tabDirectory = caseDir.appendingPathComponent("repo-a").path
    let root = caseDir.appendingPathComponent("repo-b").path
    for path in [tabDirectory, root] {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: root, activeTab: 0,
          tabs: [TabState(cwd: tabDirectory, agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    let wc = WindowController()

    let palette = try openTaskPalette(wc)

    XCTAssertEqual(palette.root, tabDirectory)
    XCTAssertNotNil(GitHubOpenLists.shared.roots[tabDirectory], "その場所でリポジトリを解決しに行く")
    XCTAssertNil(GitHubOpenLists.shared.roots[root])
  }

  /// 日本語入力の変換中の ⌘T は、タスク画面が握らずに変換へ渡す（⌘T の画面へ切り替えて未確定の文字を
  /// 捨てない）。変換中でなければ握る。
  func testCommandTWhileComposingIsLeftToTheInputMethod() throws {
    let wc = try launchOnAnEmptyWorkspace()
    _ = try openTaskPalette(wc)
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
    wc.window.contentView?.addSubview(editor)
    addTeardownBlock { @MainActor in editor.removeFromSuperview() }
    XCTAssertTrue(wc.window.makeFirstResponder(editor), "前提: 主窓の焦点が入力欄")
    editor.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertNotNil(IMEComposition.composingTextView(in: wc.window), "前提: 主窓で変換中")

    XCTAssertFalse(wc.handleWindowKeyCommand(.showWorktreePalette))
    XCTAssertEqual(wc.presentedOverlay, .taskPalette, "⌘T の画面へ切り替わらない")

    editor.unmarkText()
    XCTAssertTrue(wc.handleWindowKeyCommand(.showWorktreePalette), "変換中でなければ握る")
  }

  func testClosingTheScreenCommitsTheEditInProgress() throws {
    let wc = try launchOnAnEmptyWorkspace()
    let palette = try openTaskPalette(wc)
    let id = try typeDescription("閉じても残る", on: palette)

    wc.dismissPalette()

    XCTAssertEqual(wc.presentedOverlay, .none)
    XCTAssertNil(wc.model.taskPalette)
    XCTAssertEqual(wc.taskStore.tasks.first { $0.id == id }?.description, "閉じても残る")
  }

  func testSwappingToTheAttentionPaletteCommitsTheEditInProgress() throws {
    let wc = try launchOnAnEmptyWorkspace()
    let palette = try openTaskPalette(wc)
    let id = try typeDescription("差し替わっても残る", on: palette)

    wc.toggleAttentionPalette()

    XCTAssertEqual(wc.presentedOverlay, .attentionPalette)
    XCTAssertEqual(wc.taskStore.tasks.first { $0.id == id }?.description, "差し替わっても残る")
  }
}
