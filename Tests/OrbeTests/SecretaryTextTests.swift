import XCTest

@testable import Orbe

/// 起こした claude に渡す最初の入力と、出どころごとの役目の指示を固定する。
@MainActor
final class SecretaryTextTests: OrbeTestCase {
  private let ja = LocalizationStore(language: .ja)
  private let en = LocalizationStore(language: .en)

  func testTypedTextIsPassedAsTypedWithoutItsSurroundingBlanks() {
    XCTAssertEqual(
      SecretaryText.body(.text("  見積もりを\n山田さんに送る\n"), l10n: ja), "見積もりを\n山田さんに送る")
    XCTAssertNil(SecretaryText.body(.text(" \n\u{0}\t "), l10n: ja), "空白と制御文字だけは頼めない")
  }

  func testAFixNamesTheTaskAutoAdd() {
    let automation = DesignSceneFixtures.boardAutomations()[2]
    XCTAssertEqual(
      SecretaryText.body(.automationFix(automation), l10n: ja),
      "タスクの自動追加 \(automation.id)「\(automation.definition.name)」を直す。")
    XCTAssertEqual(
      SecretaryText.body(.automationFix(automation), l10n: en),
      "Fix task auto-add \(automation.id) “\(automation.definition.name)”.")
  }

  func testEachOriginHasItsOwnRole() {
    XCTAssertTrue(SecretaryText.instructions(for: .palette, .ja).contains("add_task"))
    XCTAssertTrue(SecretaryText.instructions(for: .board, .ja).contains("set_intake"))
  }
}
