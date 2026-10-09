import SwiftUI
import XCTest

@testable import Orbe

/// 受信タブの flow（ファイル分割の拡張）。撮り方・出力先は本体の `flow` を共有する。
extension DesignFlowSnapshotTests {
  /// ⇧⇥ で受信タブへ・打って絞り込み・⌘⌫ で捨てる（同じ位置の行が選ばれる）・↵ でタスクにする・← で棚・受信を選ぶ・
  /// → で中身（コマンドの受信と軽い agent の受信）・今すぐ受信（受信中…と、走っている間の断り）・space で止める・
  /// ⌘⌫ で削除・タスクのタブでタスクが Orbe の workspace に付いている、までを撮る。
  func testTaskPaletteIntake() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    let intake = palette.intake
    try flow(
      "task_palette_intake", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("start", {}),
        ("tab_github", { palette.toggleTab() }),
        ("tab_intake", { palette.toggleTab() }),
        ("filtered", { palette.query = "週報" }),
        ("cleared", { palette.query = "" }),
        ("dismissed", { intake.dismiss() }),
        ("accepted", { palette.submit() }),
        ("shelf", { intake.enterShelf() }),
        ("shelf_down", { intake.moveShelf(1) }),
        (
          "contents_command",
          {
            intake.showProposals(); intake.enterContents()
          }
        ),
        ("run_now", { intake.runNow() }),
        ("run_refused", { intake.runNow() }),
        (
          "contents_agent",
          {
            intake.showProposals(); intake.enterShelf(); intake.moveShelf(1); intake.moveShelf(1)
            intake.showProposals(); intake.enterContents()
          }
        ),
        ("paused", { intake.togglePause() }),
        ("deleted", { intake.deleteIntake() }),
        ("tasks_tab", { palette.setTab(.tasks) }),
      ])
  }
}
