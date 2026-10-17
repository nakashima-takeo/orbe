import XCTest

@testable import Orbe

/// 起こした claude に渡す最初の入力を固定する。
@MainActor
final class SecretaryTextTests: OrbeTestCase {
  private let ja = LocalizationStore(language: .ja)
  private let en = LocalizationStore(language: .en)

  func testTypedTextIsPassedAsTypedWithoutItsSurroundingBlanks() {
    XCTAssertEqual(
      SecretaryText.firstInput(.text("  見積もりを\n山田さんに送る\n"), l10n: ja),
      "依頼: 見積もりを\n山田さんに送る")
    XCTAssertNil(
      SecretaryText.firstInput(.text(" \n\u{0}\t "), l10n: ja), "空白と制御文字だけは頼めない")
  }

  func testBoardInstructionsNameTheBundledAutomationSkill() {
    XCTAssertTrue(
      SecretaryText.instructions(for: .board, .ja, pluginName: "orbe-agent-dev")
        .contains("`orbe-agent-dev:automation`"))
    XCTAssertTrue(
      SecretaryText.instructions(for: .board, .en, pluginName: nil).contains("`automation`"),
      "同梱の無い起動ではスキル名だけを名指しする")
    XCTAssertFalse(
      SecretaryText.instructions(for: .palette, .ja, pluginName: "orbe-agent-dev")
        .contains("automation"), "⌘⇧X の役目は自動化のスキルを使わない")
  }

  func testAFixNamesTheAutomation() throws {
    let automation = try XCTUnwrap(
      DesignSceneFixtures.automationStore(DesignSceneFixtures.boardAutomationSamples())
        .automations[2])
    XCTAssertEqual(
      SecretaryText.firstInput(.automationFix(automation), l10n: ja),
      "依頼: 自動化 \(automation.id)「\(automation.definition.name)」を直す。")
    XCTAssertEqual(
      SecretaryText.firstInput(.automationFix(automation), l10n: en),
      "Request: Fix automation \(automation.id) “\(automation.definition.name)”.")
  }
}
