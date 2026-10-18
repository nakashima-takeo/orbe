import SwiftUI
import XCTest

@testable import Orbe

/// 提案タブの flow（ファイル分割の拡張）。撮り方・出力先は本体の `flow` を共有する。
extension DesignFlowSnapshotTests {
  /// ⇥ で GitHub タブ・提案タブへ（絞り込み欄に居て候補は選ばれていない）・打って絞り込み・↓ で棚・段を移る・⌘↵ で更新中…・
  /// 更新中の ⌘↵ の断り・→ で候補の一覧（先頭が選ばれる）・↓ で 2 行目・← で棚・→ で同じ行・⌘⌫ で捨てる（同じ位置の行が
  /// 選ばれる）・↵ でタスクにする・esc で絞り込み欄・タスクのタブでタスクが Home に付いている、までを撮る。
  func testTaskPaletteAutomation() throws {
    let palette = DesignSceneFixtures.taskPaletteModel(
      automations: DesignSceneFixtures.automationShelfSamples())
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
        ("filtered", { palette.query = "直す" }),
        ("cleared", { palette.query = "" }),
        ("shelf", { automation.enterShelf() }),
        ("shelf_down", { automation.moveShelf(1) }),
        ("refreshing", { automation.refresh() }),
        ("refresh_refused", { automation.refresh() }),
        ("proposals", { automation.enterProposals() }),
        ("proposals_down", { automation.moveProposal(1) }),
        ("back_to_shelf", { automation.enterShelf() }),
        ("same_row", { automation.enterProposals() }),
        ("dismissed", { automation.dismiss() }),
        ("accepted", { palette.submit() }),
        ("field", { automation.enterField() }),
        ("tasks_tab", { palette.setTab(.tasks) }),
      ])
  }
}
