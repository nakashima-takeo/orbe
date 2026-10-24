import XCTest

@testable import Orbe

/// 定義を読めない自動化と不明な記録のボードの見え方。
///
/// 壊れると何が起きるか: 定義を読めない自動化が一覧から消え、利用者が気づかないまま候補と記録が残り続ける。読めない自動化に
/// 流す・止めるが効いたように見える。消せない・直しを頼めない。不明な記録 1 件で実行履歴が描けない。
@MainActor
final class BoardAutomationUnreadableTests: OrbeTestCase {
  private func model() -> BoardAutomationModel {
    BoardAutomationModel(
      runner: DesignSceneFixtures.automationRunner(
        store: DesignSceneFixtures.boardUnreadableStore()))
  }

  /// 読めない自動化は一覧の先頭（失敗の群）に理由を持って並び、詳細の地図は無い。「修正を依頼」は自動化の名前と理由の原文を
  /// 依頼の欄に書き出し、⌘⌫ で消せる。流す・止める ⇄ 再開は効かない。
  func testAnUnreadableAutomationIsListedWithItsReasonAndCanOnlyBeFixedOrDeleted() throws {
    let model = model()
    let first = try XCTUnwrap(model.standings.first)
    XCTAssertEqual(first.id, 2)
    XCTAssertEqual(first.name, "GitHub: レビュー依頼")
    XCTAssertEqual(first.unreadable?.hasPrefix("invalid nodes[1].instruction"), true)

    model.move(1)
    XCTAssertEqual(model.selectedUnreadable?.id, 2)
    XCTAssertNil(model.selectedAutomation)
    model.enterMap()
    XCTAssertEqual(model.place, .list, "地図は無い")
    model.perform(.togglePause)
    model.perform(.flow(.ends))
    XCTAssertFalse(model.runner.isRunning(2))

    let reason = try XCTUnwrap(first.unreadable)
    model.draftFixOfUnreadable(l10n: LocalizationStore(language: .ja))
    XCTAssertEqual(model.requestText, "自動化「GitHub: レビュー依頼」の修正：\(reason)")
    model.move(1)
    model.draftFixOfUnreadable(l10n: LocalizationStore(language: .en))
    XCTAssertEqual(
      model.requestText, "Fix the automation “GitHub: レビュー依頼”: \(reason)")
    model.move(1)
    model.perform(.delete)
    XCTAssertEqual(model.store.unreadable, [])
  }

  /// 中身を読めない回は、カードの実行履歴に時刻と成否だけの行として出る。
  func testAnUnknownRecordShowsOnlyItsTimeAndOutcome() throws {
    let automation = try XCTUnwrap(model().store.automation(1))
    let text = AutomationText(
      l10n: LocalizationStore(language: .ja),
      today: .today(
        DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
      timeZone: DesignSceneFixtures.taskCalendar.timeZone)

    let card = try XCTUnwrap(
      BoardAutomationNodeValue(
        automation, key: "fetch", text: text, running: false, next: nil, open: 0))

    guard case .run(let entry) = card.runs.first else { return XCTFail("\(card.runs)") }
    XCTAssertEqual(entry.at, "14:45")
    XCTAssertEqual(entry.result, "成功（記録を読み込めません）")
  }
}
