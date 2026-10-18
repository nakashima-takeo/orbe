import XCTest

@testable import Orbe

/// 提案タブの候補の一覧の頭——判定の部品ごとの最新の回の 1 行。
///
/// 壊れると何が起きるか: 判定が失敗した・まだ判定していないのに「候補なし」と読め、候補が来ない理由に気づけない。
@MainActor
final class TaskPaletteAutomationListTests: OrbeTestCase {
  /// 「時刻 部品の名前　結果」。結果は候補の数・候補なし・失敗の説明で、まだ回っていなければ時刻なしで「まだ判定していない」。
  func testHeadlineSaysEachJudgesLatestRun() throws {
    let store = DesignSceneFixtures.automationStore(DesignSceneFixtures.automationShelfSamples())
    let text = AutomationText(
      l10n: LocalizationStore(language: .ja),
      today: .today(
        DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
      timeZone: DesignSceneFixtures.taskCalendar.timeZone)
    func latest(_ id: Int, _ part: String) throws -> String {
      let automation = try XCTUnwrap(store.automation(id))
      let node = try XCTUnwrap(automation.graph.node(part))
      return TaskPaletteAutomationList.latest(node, automation.state(part).runs.first, text)
    }

    XCTAssertEqual(try latest(1, "dev"), "9:00 開発の依頼を選ぶ\u{3000}候補 2 件")
    XCTAssertEqual(
      try latest(1, "contact"), "13:00 返事が要る連絡を選ぶ\u{3000}失敗：制限時間内に終わらなかった")
    XCTAssertEqual(try latest(4, "judge"), "14:51 判定\u{3000}候補なし")
    XCTAssertEqual(try latest(5, "judge"), "判定\u{3000}まだ判定していない")
  }
}
