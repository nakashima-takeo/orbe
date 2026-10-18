import SwiftUI
import XCTest

@testable import Orbe

/// 提案タブの gallery（見本 R3Inbox.png・O2Palette と同じ 1440×900 の窓）。
extension DesignGallerySnapshotTests {
  func renderTaskPaletteAutomationSnapshots(
    _ write: (String, TaskPaletteModel, CGFloat, CGFloat) throws -> Void
  ) throws {
    func model(_ file: [AutomationSample]? = nil) -> TaskPaletteModel {
      let palette = DesignSceneFixtures.taskPaletteModel(automations: file)
      palette.setTab(.automation)
      return palette
    }

    // 見本どおり: 棚で Slack の 1 つ目を選び、候補の一覧の先頭に居る。
    let design = model()
    design.automation.tapShelf(.automation(1))
    design.automation.enterProposals()
    try write("automation_design.png", design, 1440, 900)

    // 開いた直後: 絞り込み欄に居て、候補は選ばれていない（印なし・詳細は空）。
    try write("automation_all.png", model(), 1440, 900)

    // 付け先を持たない候補は、詳細の付け先に Home が出る。
    let home = model()
    home.automation.enterProposals()
    home.automation.moveProposal(1)
    try write("automation_destination_home.png", home, 1440, 900)

    try renderTaskPaletteAutomationShelfSnapshots(write)

    let crowded = model(DesignSceneFixtures.automationCrowdedSamples())
    crowded.automation.tapShelf(.automation(1))
    crowded.automation.enterProposals()
    crowded.automation.jumpProposal(1)
    try write("automation_crowded.png", crowded, 1440, 900)

    try write("automation_empty.png", model([]), 1440, 900)

    let small = model()
    small.automation.tapShelf(.automation(1))
    small.automation.enterProposals()
    try write("automation_small.png", small, 800, 560)
  }

  /// 棚の見本（見本 O2Palette）: 棚の 2 行目の全種（次の判定・届いたら・手動・停止中・更新中…・候補なし・失敗した部品）、
  /// 判定ごとの一覧の頭、出どころの部品の名前。
  private func renderTaskPaletteAutomationShelfSnapshots(
    _ write: (String, TaskPaletteModel, CGFloat, CGFloat) throws -> Void
  ) throws {
    func model() -> TaskPaletteModel {
      let palette = DesignSceneFixtures.taskPaletteModel(
        automations: DesignSceneFixtures.automationShelfSamples())
      palette.setTab(.automation)
      try? palette.automation.runner.flow(2, to: .judges)
      return palette
    }

    // 開いた直後: 絞り込み欄に居て、棚の「すべて」は焦点の無い薄い地。
    try write("automation_shelf_field.png", model(), 1440, 900)

    // 棚に居る（見本の状態）: 受け持ちの全部を選び、Sentry は更新中。
    let shelf = model()
    shelf.automation.enterShelf()
    shelf.automation.moveShelf(1)
    try write("automation_shelf.png", shelf, 1440, 900)

    // 候補の一覧に居る: 先頭が選ばれ、詳細の見出しに取得の部品の名前。棚の段は焦点の無い薄い地。
    let list = model()
    list.automation.tapShelf(.automation(1))
    list.automation.enterProposals()
    try write("automation_shelf_list.png", list, 1440, 900)

    // 出どころの部品の名前を引けない候補（消えた自動化が出した）。
    let unnamed = model()
    unnamed.automation.tapShelf(.automation(1))
    unnamed.automation.enterProposals()
    unnamed.automation.jumpProposal(1)
    try write("automation_shelf_unnamed.png", unnamed, 1440, 900)

    // 更新中の ⌘↵ は、フッターに赤で断る。
    let refused = model()
    refused.automation.enterShelf()
    refused.automation.moveShelf(1)
    refused.automation.moveShelf(1)
    refused.automation.refresh()
    try write("automation_shelf_refused.png", refused, 1440, 900)

    try write("automation_shelf_small.png", shelf, 800, 560)
  }
}
