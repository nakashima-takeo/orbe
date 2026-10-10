import XCTest

@testable import Orbe

/// 受信タブの文——回の要約（判定した回・新しい項目が無かった回・失敗した回・まだ回っていない）と、時刻の今日 / ほかの日。
///
/// 壊れると何が起きるか。新しい項目が無かった回が「新しい 0 件を判定 → 候補 0」と読め、判定が走ったように見える。失敗した回が
/// 件数で出て、壊れた受信に気づけない。昨日の回が今日の時刻に見える。
@MainActor
final class IntakeTextTests: OrbeTestCase {
  private let text = intakeText(.ja)

  private static func intakeText(_ language: Language) -> IntakeText {
    IntakeText(
      l10n: LocalizationStore(language: language),
      today: .today(
        DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
      timeZone: DesignSceneFixtures.taskCalendar.timeZone)
  }

  func testRunSummaries() {
    let at = DesignSceneFixtures.intakeAt
    XCTAssertEqual(
      text.runHeadline(
        DesignSceneFixtures.intakeRun(at: at(13, 0, 0), items: 9, newItems: 4, proposed: 2)),
      "13:00 の回 · 9 件取得 → 新しい 4 件を判定 → 候補 2")
    XCTAssertEqual(
      text.runDetail(
        DesignSceneFixtures.intakeRun(at: at(9, 12, 0), items: 14, newItems: 3, proposed: 1)),
      "今日 9:12 · 14 件取得 → 新しい 3 件を判定 → 候補 1 件")
    XCTAssertEqual(
      text.runHeadline(DesignSceneFixtures.intakeRun(at: at(13, 0, 1), items: 9, newItems: 0)),
      "10/3 13:00 の回 · 9 件取得 → 新しい項目なし")
    XCTAssertEqual(
      text.runHeadline(
        DesignSceneFixtures.intakeRun(at: at(9, 0, 0), items: 0, newItems: 0, failure: "boom")),
      "9:00 の回 · 失敗 — boom")
    XCTAssertEqual(text.runHeadline(nil), "まだ回っていない")
  }

  /// 英語は候補が 1 件なら単数で言う。日本語は助数詞で単複不変。
  func testProposedCountSingularAndPlural() {
    let at = DesignSceneFixtures.intakeAt
    let one = DesignSceneFixtures.intakeRun(at: at(13, 0, 0), items: 9, newItems: 4, proposed: 1)
    let two = DesignSceneFixtures.intakeRun(at: at(13, 0, 0), items: 9, newItems: 4, proposed: 2)
    let en = Self.intakeText(.en)
    XCTAssertEqual(en.runHeadline(one), "13:00 run · fetched 9 → judged 4 new → 1 candidate")
    XCTAssertEqual(en.runHeadline(two), "13:00 run · fetched 9 → judged 4 new → 2 candidates")
    XCTAssertEqual(en.runDetail(one), "today 13:00 · fetched 9 → judged 4 new → 1 candidate")
    XCTAssertEqual(en.runDetail(two), "today 13:00 · fetched 9 → judged 4 new → 2 candidates")
    XCTAssertEqual(text.runHeadline(one), "13:00 の回 · 9 件取得 → 新しい 4 件を判定 → 候補 1")
    XCTAssertEqual(text.runDetail(two), "今日 13:00 · 9 件取得 → 新しい 4 件を判定 → 候補 2 件")
  }

  func testWhen() {
    XCTAssertEqual(text.when(.every(1800)), "30 分ごと")
    XCTAssertEqual(
      text.when(.daily([.init(hour: 13, minute: 0), .init(hour: 9, minute: 5)])), "毎日 9:05・13:00")
  }
}
