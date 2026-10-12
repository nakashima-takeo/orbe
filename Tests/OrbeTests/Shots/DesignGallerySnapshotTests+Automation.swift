import SwiftUI
import XCTest

@testable import Orbe

/// 受信タブの gallery（見本 R3Inbox.png と同じ 1440×900 の窓）。
extension DesignGallerySnapshotTests {
  func renderTaskPaletteAutomationSnapshots(
    _ write: (String, TaskPaletteModel, CGFloat, CGFloat) throws -> Void
  ) throws {
    func model(_ file: AutomationsFile? = nil) -> TaskPaletteModel {
      let palette = DesignSceneFixtures.taskPaletteModel(automations: file)
      palette.setTab(.automation)
      return palette
    }

    // 見本どおり: 棚で Slack の 1 つ目を選び、提案の一覧の先頭に居る。
    let design = model()
    design.automation.tapShelf(.automation(1))
    try write("automation_design.png", design, 1440, 900)

    try write("automation_all.png", model(), 1440, 900)

    // 棚の 2 行目の全種（次の時刻・止めている・実行中…・前回は失敗・候補なし）。
    let running = model()
    try? running.automation.runner.runNow(1)
    running.automation.enterShelf()
    try write("automation_shelf_running.png", running, 1440, 900)

    let command = model()
    command.automation.tapShelf(.automation(1))
    command.automation.enterContents()
    try write("automation_contents_command.png", command, 1440, 900)

    let agent = model()
    agent.automation.tapShelf(.automation(3))
    agent.automation.enterContents()
    try write("automation_contents_agent.png", agent, 1440, 900)

    // 取得と判定の中身は行数で切らず、折り返して全文を出す（長い依頼文・使えるツール・指示文・コマンドと作業ディレクトリ）。
    let long = DesignSceneFixtures.automationLongFile()
    let longAgent = model(long)
    longAgent.automation.tapShelf(.automation(3))
    longAgent.automation.enterContents()
    try write("automation_contents_long_agent.png", longAgent, 1440, 900)
    let longCommand = model(long)
    longCommand.automation.tapShelf(.automation(1))
    longCommand.automation.enterContents()
    try write("automation_contents_long_command.png", longCommand, 1440, 900)

    // 走っている間の今すぐ実行は、フッターに赤で断る。
    let refused = model()
    refused.automation.tapShelf(.automation(1))
    refused.automation.enterContents()
    refused.automation.perform(.runNow)
    refused.automation.perform(.runNow)
    try write("automation_contents_running.png", refused, 1440, 900)

    let crowded = model(DesignSceneFixtures.automationCrowdedFile())
    crowded.automation.tapShelf(.automation(1))
    crowded.automation.jumpProposal(1)
    try write("automation_crowded.png", crowded, 1440, 900)

    try write("automation_empty.png", model(DesignSceneFixtures.automationEmptyFile()), 1440, 900)

    let small = model()
    small.automation.tapShelf(.automation(1))
    try write("automation_small.png", small, 800, 560)
  }
}
