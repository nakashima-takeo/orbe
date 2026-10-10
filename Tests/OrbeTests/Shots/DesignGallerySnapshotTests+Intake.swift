import SwiftUI
import XCTest

@testable import Orbe

/// 受信タブの gallery（見本 R3Inbox.png と同じ 1440×900 の窓）。
extension DesignGallerySnapshotTests {
  func renderTaskPaletteIntakeSnapshots(
    _ write: (String, TaskPaletteModel, CGFloat, CGFloat) throws -> Void
  ) throws {
    func model(_ file: IntakesFile? = nil) -> TaskPaletteModel {
      let palette = DesignSceneFixtures.taskPaletteModel(intakes: file)
      palette.setTab(.intake)
      return palette
    }

    // 見本どおり: 棚で Slack の 1 つ目を選び、提案の一覧の先頭に居る。
    let design = model()
    design.intake.tapShelf(.intake(1))
    try write("intake_design.png", design, 1440, 900)

    try write("intake_all.png", model(), 1440, 900)

    // 棚の 2 行目の全種（次の時刻・止めている・実行中…・前回は失敗・候補なし）。
    let running = model()
    try? running.intake.runner.runNow(1)
    running.intake.enterShelf()
    try write("intake_shelf_running.png", running, 1440, 900)

    let command = model()
    command.intake.tapShelf(.intake(1))
    command.intake.enterContents()
    try write("intake_contents_command.png", command, 1440, 900)

    let agent = model()
    agent.intake.tapShelf(.intake(3))
    agent.intake.enterContents()
    try write("intake_contents_agent.png", agent, 1440, 900)

    // 取得と判定の中身は行数で切らず、折り返して全文を出す（長い依頼文・使えるツール・指示文・コマンドと作業ディレクトリ）。
    let long = DesignSceneFixtures.intakeLongFile()
    let longAgent = model(long)
    longAgent.intake.tapShelf(.intake(3))
    longAgent.intake.enterContents()
    try write("intake_contents_long_agent.png", longAgent, 1440, 900)
    let longCommand = model(long)
    longCommand.intake.tapShelf(.intake(1))
    longCommand.intake.enterContents()
    try write("intake_contents_long_command.png", longCommand, 1440, 900)

    // 走っている間の今すぐ実行は、フッターに赤で断る。
    let refused = model()
    refused.intake.tapShelf(.intake(1))
    refused.intake.enterContents()
    refused.intake.runNow()
    refused.intake.runNow()
    try write("intake_contents_running.png", refused, 1440, 900)

    let crowded = model(DesignSceneFixtures.intakeCrowdedFile())
    crowded.intake.tapShelf(.intake(1))
    crowded.intake.jumpProposal(1)
    try write("intake_crowded.png", crowded, 1440, 900)

    try write("intake_empty.png", model(DesignSceneFixtures.intakeEmptyFile()), 1440, 900)

    let small = model()
    small.intake.tapShelf(.intake(1))
    try write("intake_small.png", small, 800, 560)
  }
}
