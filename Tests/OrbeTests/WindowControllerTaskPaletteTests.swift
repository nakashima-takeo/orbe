import AppKit
import XCTest

@testable import Orbe

/// ⌘⇧X のタスク画面を実 `WindowController` から開き・閉じる配線を固定する。開いた workspace の写しと、
/// 画面を閉じる・別の画面へ差し替わるときの打ちかけの編集の確定。
///
/// 壊れると何が起きるか: タブが 0 枚の workspace でタスク画面が開かない。画面で足したタスクが、見ている
/// workspace ではなく別の workspace に付く。メモを打ちかけのまま esc 以外で画面を閉じたり ⌘⌘ で
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

  /// メモを打ちかけた状態。
  private func typeMemo(_ text: String, on palette: TaskPaletteModel) throws -> Int {
    let item = try palette.store.add(TaskDraft(title: "メモを書く"))
    palette.reconcile()
    palette.jump(1)
    palette.enterDetail()
    palette.tapField(.memo)
    palette.draftText = text
    return item.id
  }

  func testOpensOnAWorkspaceWithNoTabsAndAddsTasksToThatWorkspace() throws {
    let wc = try launchOnAnEmptyWorkspace()

    let palette = try openTaskPalette(wc)
    palette.query = "見積もりを出す"
    palette.submit()

    XCTAssertEqual(palette.workspaces.opened, .init(id: emptyId, name: "empty"))
    XCTAssertEqual(palette.workspaces.all.map(\.id), [mainId, emptyId], "サイドバーの順")
    XCTAssertEqual(wc.taskStore.tasks.last?.workspace, emptyId, "画面を開いた workspace に付く")
  }

  func testClosingTheScreenCommitsTheEditInProgress() throws {
    let wc = try launchOnAnEmptyWorkspace()
    let palette = try openTaskPalette(wc)
    let id = try typeMemo("閉じても残る", on: palette)

    wc.dismissPalette()

    XCTAssertEqual(wc.presentedOverlay, .none)
    XCTAssertNil(wc.model.taskPalette)
    XCTAssertEqual(wc.taskStore.tasks.first { $0.id == id }?.memo, "閉じても残る")
  }

  func testSwappingToTheAttentionPaletteCommitsTheEditInProgress() throws {
    let wc = try launchOnAnEmptyWorkspace()
    let palette = try openTaskPalette(wc)
    let id = try typeMemo("差し替わっても残る", on: palette)

    wc.toggleAttentionPalette()

    XCTAssertEqual(wc.presentedOverlay, .attentionPalette)
    XCTAssertEqual(wc.taskStore.tasks.first { $0.id == id }?.memo, "差し替わっても残る")
  }
}
