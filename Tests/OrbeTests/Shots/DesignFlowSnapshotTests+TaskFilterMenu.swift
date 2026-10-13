import SwiftUI
import XCTest

@testable import Orbe

/// タスク画面の絞り込みのメニューの flow（ファイル分割の拡張）。
extension DesignFlowSnapshotTests {
  /// 小さい窓（800×560）で workspace が 36 個あるとき、workspace のメニューはカードの下端の手前までに収まり、
  /// 下端まで送ると最後の workspace が見えて選べ、続けて 3 つオンにしても（ドロップダウンの表記が伸びて折り返しても）
  /// メニューは開いた位置から動かない、までを撮る。
  func testTaskPaletteWorkspaceMenu() throws {
    let palette = DesignSceneFixtures.taskPaletteModel(
      workspaces: DesignSceneFixtures.taskManyWorkspaces)
    let picks = DesignSceneFixtures.taskManyWorkspaces.all.suffix(3).reversed().map(\.id)
    try hostedTaskPaletteFlow(
      "task_palette_workspace_menu", palette, size: NSSize(width: 800, height: 560),
      steps: [
        ("menu", { _ in palette.toggleFilterMenu(.workspace) }),
        ("menu_bottom", { host in self.scrollToBottom(in: host, pick: { $0.last }) }),
        ("menu_one_on", { _ in palette.toggleWorkspaceFilter(picks[0]) }),
        ("menu_two_on", { _ in palette.toggleWorkspaceFilter(picks[1]) }),
        ("menu_three_on", { _ in palette.toggleWorkspaceFilter(picks[2]) }),
      ])
  }

  /// 通常の窓（1440×900）で期限のメニューを開き、続けて 3 つオンにしても（ドロップダウンの表記が伸びて折り返しても）
  /// メニューは開いた位置から動かない、までを撮る。
  func testTaskPaletteDueMenu() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    try hostedTaskPaletteFlow(
      "task_palette_due_menu", palette, size: NSSize(width: 1440, height: 900),
      steps: [
        ("menu", { _ in palette.toggleFilterMenu(.due) }),
        ("menu_one_on", { _ in palette.toggleDueFilter(.overdue) }),
        ("menu_two_on", { _ in palette.toggleDueFilter(.today) }),
        ("menu_three_on", { _ in palette.toggleDueFilter(.withinWeek) }),
      ])
  }
}
