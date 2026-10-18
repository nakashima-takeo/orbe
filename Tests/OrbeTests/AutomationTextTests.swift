import XCTest

@testable import Orbe

/// 自動化の文——部品の回の要約（判定の候補の単数・複数・失敗・まだ回っていない）、時刻の今日 / ほかの日、いつ（cron の言い換え）。
///
/// 壊れると何が起きるか。英語で候補 1 件の回が「1 candidates」と読める。失敗した回が件数で出て、壊れた部品に気づけない。
/// 昨日の回が今日の時刻に見える。cron の言い換えが元の時刻と食い違い、表示と違う時刻に走ると読ませる
/// （1・7 月だけの式が「毎日」に見える）。
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

  private func judged(taken: Int, proposed: Int, failure: String? = nil) -> AutomationPartRun {
    let at = DesignSceneFixtures.automationAt(13)
    var run = AutomationPartRun(
      startedAt: at, endedAt: at, trigger: .schedule, taken: taken,
      execution: AutomationPartPass.Execution(
        commandLine: "claude -p", ending: "exited 0", count: 0))
    if let failure {
      run.failure = failure
    } else {
      run.result = .judge(proposed: proposed, resolved: 0, rejected: AutomationRejections())
    }
    return run
  }

  private static let judge = node("dev", "開発")

  private static func node(_ key: String, _ name: String) -> AutomationGraph.Node {
    let graph = try? AutomationGraph([
      DesignSceneFixtures.commandPart(
        "fetch", "取得", .manual, script: "cat", coverage: .newArrivals),
      DesignSceneFixtures.agentPart(
        key, name, .arrival, from: ["fetch"], instruction: "i", deliver: .taskCandidates),
    ])
    guard let node = graph?.node(key) else { preconditionFailure("the graph is valid") }
    return node
  }

  func testJudgeRunSummariesSaySingularAndPluralAndFailure() {
    let en = Self.automationText(.en)

    XCTAssertEqual(
      en.latest(Self.judge, judged(taken: 12, proposed: 1)), "13:00 Judge: 開発 · 12 → 1 candidate")
    XCTAssertEqual(
      en.latest(Self.judge, judged(taken: 12, proposed: 2)), "13:00 Judge: 開発 · 12 → 2 candidates")
    XCTAssertEqual(
      text.latest(Self.judge, judged(taken: 12, proposed: 2)), "13:00 判定: 開発 · 12 件 → 候補 2")
    XCTAssertEqual(
      text.latest(Self.judge, judged(taken: 3, proposed: 0, failure: "boom")),
      "13:00 判定: 開発 · 失敗 — boom")
    XCTAssertEqual(text.latest(Self.judge, nil), "判定: 開発 · まだ回っていない")
  }

  /// 失敗した部品は新しい失敗を先に言い、2 つ目からは数で言う。
  func testFailedParts() {
    let contact = Self.node("contact", "連絡")

    XCTAssertNil(text.failed([]))
    XCTAssertEqual(text.failed([contact]), "判定: 連絡 · 失敗")
    XCTAssertEqual(text.failed([contact, Self.judge]), "判定: 連絡 ほか 1 件 · 失敗")
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
      ("*/30 * * * *", "0:00〜23:30 の30分ごと"),
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

  /// 言い換えが元の時刻を一意に表せない形は、式のまま出す。式は途中で折れないよう、欄の間を改行しない空白でつなぐ。
  func testCronThatHasNoWordsShowsTheExpression() {
    for expression in [
      "0 9 * 1,7 *", "0,20,45 * * * *", "0/7 9 * * *", "0 1,2,3,5,8 * * *",
      "*/10 9-11,14-16 * * *",
    ] {
      XCTAssertEqual(
        text.when(DesignSceneFixtures.cron(expression)),
        "cron " + expression.replacingOccurrences(of: " ", with: "\u{00A0}"))
    }
  }

  func testCronInEnglish() {
    let en = Self.automationText(.en)
    let cases: [(String, String)] = [
      ("0 9,13 * * *", "daily at 9:00 / 13:00"),
      ("0 9 * * 1-5", "weekdays at 9:00"),
      ("0 10 * * 1,4", "every Mon, Thu at 10:00"),
      ("0 9 1 * *", "monthly on day 1 at 9:00"),
      ("0 9 1,15 * *", "monthly on days 1, 15 at 9:00"),
      ("*/10 9-18 * * 1-5", "weekdays every 10 min, 9:00–18:50"),
      ("5 * * * *", "hourly at :05"),
    ]
    for (expression, words) in cases {
      XCTAssertEqual(en.when(DesignSceneFixtures.cron(expression)), words, expression)
    }
  }
}
