import SwiftUI
import XCTest

@testable import Orbe

/// 提案タブの flow（ファイル分割の拡張）。撮り方・出力先は本体の `flow` を共有する。
extension DesignFlowSnapshotTests {
  /// ⇥ で GitHub タブ・提案タブへ・打って絞り込み・⌘⌫ で捨てる（同じ位置の行が選ばれる）・↵ でタスクにする・← で棚・受信を選ぶ・
  /// → で中身（コマンドの受信と軽い agent の受信）・今すぐ実行（実行中…と、走っている間の断り）・space で止める・
  /// ⌘⌫ で削除・タスクのタブでタスクが Home に付いている、までを撮る。
  func testTaskPaletteAutomation() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    let automation = palette.automation
    try flow(
      "task_palette_automation", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("start", {}),
        ("tab_github", { palette.setTab(palette.tab.next) }),
        ("tab_automation", { palette.setTab(palette.tab.next) }),
        ("filtered", { palette.query = "週報" }),
        ("cleared", { palette.query = "" }),
        ("dismissed", { automation.dismiss() }),
        ("accepted", { palette.submit() }),
        ("shelf", { automation.enterShelf() }),
        ("shelf_down", { automation.moveShelf(1) }),
        (
          "contents_command",
          {
            automation.showProposals(); automation.enterContents()
          }
        ),
        ("run_now", { automation.perform(.runNow) }),
        ("run_refused", { automation.perform(.runNow) }),
        (
          "contents_agent",
          {
            automation.showProposals(); automation.enterShelf()
            automation.moveShelf(1); automation.moveShelf(1)
            automation.showProposals(); automation.enterContents()
          }
        ),
        ("paused", { automation.perform(.togglePause) }),
        ("deleted", { automation.perform(.delete) }),
        ("tasks_tab", { palette.setTab(.tasks) }),
      ])
  }
}
