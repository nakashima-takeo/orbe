import XCTest

@testable import Orbe

/// ボードの読み替え——一覧の行（前回の成否と時刻・次回）と、地図の溝の線の割り当て。
///
/// 壊れると何が起きるか: 失敗した部品があるのに一覧の印が成功に見え、壊れた部品に気づけない。地図の線が入力と違う行へつながり、
/// どの部品の出力がどこへ行くかを読み違える。
@MainActor
final class BoardAutomationSummaryTests: OrbeTestCase {
  private let text = AutomationText(
    l10n: LocalizationStore(language: .ja),
    today: .today(
      DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
    timeZone: DesignSceneFixtures.taskCalendar.timeZone)

  private func automations() -> [Automation] {
    DesignSceneFixtures.automationStore(DesignSceneFixtures.boardMapSamples()).automations
  }

  /// 失敗した部品があれば失敗の印。時刻はどの部品かを問わず最後に動いた時刻で、昨日なら「昨日」。
  func testListRowSaysTheLastMarkAndTime() throws {
    let all = automations()
    let charge = BoardAutomationSummary(all[0], text: text, next: nil)
    XCTAssertEqual(charge.mark, .failure)
    XCTAssertEqual(charge.last, "前回 14:56")

    let script = BoardAutomationSummary(all[1], text: text, next: nil)
    XCTAssertEqual(script.mark, .success)
    XCTAssertEqual(script.last, "前回 昨日 23:00")

    let wide = BoardAutomationSummary(all[2], text: text, next: nil)
    XCTAssertNil(wide.mark)
    XCTAssertEqual(wide.last, "まだ動いていない")
  }

  /// 見本の 12 部品の線: 行を上から見て、最後の受け手を迎える入力の線のうち最も左に点を置き、無ければ空いている最も左。
  func testMapLanesFollowTheInputs() throws {
    let detail = BoardAutomationDetailValue(
      automations()[0], text: text, running: { _ in false }, open: 0, next: nil)

    XCTAssertEqual(detail.rows.map(\.lanes.node), [0, 1, 2, 3, 4, 5, 3, 4, 5, 2, 0, 4, 0, 2])
    XCTAssertEqual(detail.laneCount, 6)
    let develop = detail.rows[10].lanes
    XCTAssertEqual(develop.bends, [1, 3], "CI と自分の担当だけの線が点へ曲がり込む")
    XCTAssertEqual(develop.through, [2, 4, 5])
  }
}
