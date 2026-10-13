import XCTest

@testable import Orbe

/// 起こした claude に渡す最初の入力を固定する。
@MainActor
final class SecretaryTextTests: OrbeTestCase {
  private let ja = LocalizationStore(language: .ja)
  private let en = LocalizationStore(language: .en)

  func testTypedTextIsPassedAsTypedWithoutItsSurroundingBlanks() {
    XCTAssertEqual(
      SecretaryText.firstInput(.text("  見積もりを\n山田さんに送る\n"), from: .palette, l10n: ja),
      "依頼: 見積もりを\n山田さんに送る")
    XCTAssertNil(
      SecretaryText.firstInput(.text(" \n\u{0}\t "), from: .palette, l10n: ja), "空白と制御文字だけは頼めない")
  }

  func testAFixNamesTheTaskAutoAdd() {
    let automation = DesignSceneFixtures.boardAutomations()[2]
    XCTAssertEqual(
      SecretaryText.firstInput(.automationFix(automation), from: .board, l10n: ja),
      "依頼: タスクの自動追加 \(automation.id)「\(automation.definition.name)」を直す。")
    XCTAssertEqual(
      SecretaryText.firstInput(.automationFix(automation), from: .board, l10n: en),
      "Request: Fix task auto-add \(automation.id) “\(automation.definition.name)”.")
  }
}
