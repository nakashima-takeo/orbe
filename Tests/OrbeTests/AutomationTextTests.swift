import XCTest

@testable import Orbe

/// 提案タブの文——回の要約（処理した回・新しい項目が無かった回・失敗した回・まだ回っていない）と、時刻の今日 / ほかの日。
///
/// 壊れると何が起きるか。新しい項目が無かった回が「新しい 0 件を処理 → 候補 0」と読め、処理が走ったように見える。失敗した回が
/// 件数で出て、壊れた受信に気づけない。昨日の回が今日の時刻に見える。
@MainActor
final class AutomationTextTests: OrbeTestCase {
  private let text = automationText(.ja)

  private static func automationText(_ language: Language) -> AutomationText {
    AutomationText(
      l10n: LocalizationStore(language: language),
      today: .today(
        DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
      timeZone: DesignSceneFixtures.taskCalendar.timeZone)
  }

  func testRunSummaries() {
    let at = DesignSceneFixtures.automationAt
    XCTAssertEqual(
      text.runHeadline(
        DesignSceneFixtures.automationRun(at: at(13, 0, 0), items: 9, fresh: 4, proposed: 2)),
      "13:00 の回 · 9 件取得 → 新しい 4 件を処理 → 候補 2")
    XCTAssertEqual(
      text.runDetail(
        DesignSceneFixtures.automationRun(at: at(9, 12, 0), items: 14, fresh: 3, proposed: 1)),
      "今日 9:12 · 14 件取得 → 新しい 3 件を処理 → 候補 1 件")
    XCTAssertEqual(
      text.runHeadline(DesignSceneFixtures.automationRun(at: at(13, 0, 1), items: 9, fresh: 0)),
      "10/3 13:00 の回 · 9 件取得 → 新しい項目なし")
    XCTAssertEqual(
      text.runHeadline(
        DesignSceneFixtures.automationRun(at: at(9, 0, 0), items: 0, fresh: 0, failure: "boom")),
      "9:00 の回 · 失敗 — boom")
    XCTAssertEqual(text.runHeadline(nil), "まだ回っていない")
  }

  /// 英語は候補が 1 件なら単数で言う。日本語は助数詞で単複不変。
  func testProposedCountSingularAndPlural() {
    let at = DesignSceneFixtures.automationAt
    let one = DesignSceneFixtures.automationRun(
      at: at(13, 0, 0), items: 9, fresh: 4, proposed: 1)
    let two = DesignSceneFixtures.automationRun(
      at: at(13, 0, 0), items: 9, fresh: 4, proposed: 2)
    let en = Self.automationText(.en)
    XCTAssertEqual(en.runHeadline(one), "13:00 run · fetched 9 → processed 4 new → 1 candidate")
    XCTAssertEqual(en.runHeadline(two), "13:00 run · fetched 9 → processed 4 new → 2 candidates")
    XCTAssertEqual(en.runDetail(one), "today 13:00 · fetched 9 → processed 4 new → 1 candidate")
    XCTAssertEqual(en.runDetail(two), "today 13:00 · fetched 9 → processed 4 new → 2 candidates")
    XCTAssertEqual(text.runHeadline(one), "13:00 の回 · 9 件取得 → 新しい 4 件を処理 → 候補 1")
    XCTAssertEqual(text.runDetail(two), "今日 13:00 · 9 件取得 → 新しい 4 件を処理 → 候補 2 件")
  }

  func testWhen() {
    XCTAssertEqual(text.when(.every(1800)), "30分ごと")
    XCTAssertEqual(text.next(DesignSceneFixtures.automationAt(17, 0)), "次回 17:00")
  }

  /// よくある形だけを言葉にし、言葉は元の時刻の集合を一意に表す（範囲は最初と最後の該当時刻）。
  func testCronInWords() {
    let cases: [(String, String)] = [
      ("5 9,13 * * *", "毎日 9:05 / 13:05"),
      ("0 9 * * 1-5", "平日 9:00"),
      ("0 10 * * 0,6", "土日 10:00"),
      ("0 10 * * 1", "毎週月曜 10:00"),
      ("0 10 * * 1,4", "毎週月・木曜 10:00"),
      ("0 9 1,15 * *", "毎月1日・15日 9:00"),
      ("*/30 * * * *", "30分ごと"),
      ("*/10 9-18 * * 1-5", "平日 9:00〜18:50 の10分ごと"),
      ("*/10 9-18 * * *", "9:00〜18:50 の10分ごと"),
      ("5 * * * *", "毎時5分"),
      ("0 9-18 * * 1-5", "平日 9:00〜18:00 の1時間ごと"),
      ("0 */2 * * *", "0:00〜22:00 の2時間ごと"),
    ]
    for (expression, words) in cases {
      XCTAssertEqual(text.when(DesignSceneFixtures.cron(expression)), words, expression)
    }
  }

  /// 言い換えが元の時刻を一意に表せない形は、式のまま出す。
  func testCronThatHasNoWordsShowsTheExpression() {
    for expression in [
      "0 9 * 1,7 *", "0,20,45 * * * *", "0/7 9 * * *", "0 1,2,3,5,8 * * *",
      "*/10 9-11,14-16 * * *",
    ] {
      XCTAssertEqual(text.when(DesignSceneFixtures.cron(expression)), "cron " + expression)
    }
  }

  func testCronInEnglish() {
    let en = Self.automationText(.en)
    let cases: [(String, String)] = [
      ("0 9,13 * * *", "daily at 9:00 / 13:00"),
      ("0 9 * * 1-5", "weekdays at 9:00"),
      ("0 10 * * 1,4", "every Mon, Thu at 10:00"),
      ("0 9 1 * *", "monthly on day 1 at 9:00"),
      ("*/10 9-18 * * 1-5", "weekdays every 10 min, 9:00–18:50"),
      ("5 * * * *", "hourly at :05"),
    ]
    for (expression, words) in cases {
      XCTAssertEqual(en.when(DesignSceneFixtures.cron(expression)), words, expression)
    }
  }
}
