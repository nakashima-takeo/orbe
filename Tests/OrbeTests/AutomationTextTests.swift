import XCTest

@testable import Orbe

/// 自動化の文——失敗と外れた行の言い方、時刻の今日 / 昨日 / ほかの日、いつ（cron の言い換え）。
///
/// 壊れると何が起きるか。失敗が英文だけで出て、何が起きたか読めない。原文が消えて AI に渡す文と照らせない。
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

  private func failed(_ failure: AutomationFailure, ending: AutomationEnding) -> AutomationPartRun {
    let at = DesignSceneFixtures.automationAt(13)
    var run = AutomationPartRun(
      startedAt: at, endedAt: at, trigger: .schedule, taken: 3,
      execution: AutomationPartPass.Execution(commandLine: "claude -p", ending: ending, count: 0))
    run.failure = failure
    return run
  }

  private static let judge = node("dev", "開発の依頼を選ぶ")

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

  /// 失敗は日本語の説明に原文を括弧で添える。部品の申告は説明の頭に文を添え、原文を重ねない。英語の画面は原文を重ねず
  /// （説明も原文も英語で、同じことを 2 度言うため）、原文にだけある抜粋（標準エラー・最初の外れた行）だけを添える。
  func testFailureSaysTheKindWithTheOriginal() {
    XCTAssertEqual(
      text.failure(failed(.ended(detail: ""), ending: .timeLimit), node: Self.judge),
      #"制限時間内に終わらなかった（the part "dev" ended: stopped at the time limit）"#)
    XCTAssertEqual(
      text.failure(failed(.ended(detail: "boom"), ending: .exited(1)), node: Self.judge),
      #"終了コード 1 で終わった（the part "dev" ended: exited 1: boom）"#)
    XCTAssertEqual(
      text.failure(failed(.reported("Slack に届かない"), ending: .exited(0)), node: Self.judge),
      "部品が失敗を申告した：Slack に届かない")
    XCTAssertEqual(
      Self.automationText(.en).failure(
        failed(.ended(detail: ""), ending: .timeLimit), node: Self.judge),
      "didn’t finish within the time limit")
    XCTAssertEqual(
      Self.automationText(.en).failure(
        failed(.ended(detail: "boom"), ending: .exited(1)), node: Self.judge),
      "exited with code 1: boom")
    var broke = failed(.brokeRules, ending: .exited(0))
    broke.breach = AutomationPartRun.Breach(
      lines: AutomationRejections([AutomationBrokenLine(line: 2, fault: .notJSON)]),
      redo: AutomationPartRun.Redo(
        firstCall: broke.execution,
        lines: AutomationRejections([AutomationBrokenLine(line: 3, fault: .missingKey("link"))])))
    XCTAssertEqual(
      Self.automationText(.en).failure(broke, node: Self.judge),
      "output format errors weren’t fixed: line 3: missing link", "出し直しでも外れていた最初の行")
  }

  /// 外れた行は「n 行目：<説明>」。
  func testBrokenLine() {
    XCTAssertEqual(
      text.line(AutomationBrokenLine(line: 3, fault: .missingKey("link"))), "3 行目：link が無い")
    XCTAssertEqual(text.line(AutomationBrokenLine(line: 5, fault: .notJSON)), "5 行目：JSON として読めない")
  }

  /// 一覧の時刻は、今日なら時刻だけ、昨日なら「昨日」、ほかは日付付き。
  func testRecent() {
    XCTAssertEqual(text.recent(DesignSceneFixtures.automationAt(16, 41)), "16:41")
    XCTAssertEqual(text.recent(DesignSceneFixtures.automationAt(23, 0, daysAgo: 1)), "昨日 23:00")
    XCTAssertEqual(text.recent(DesignSceneFixtures.automationAt(10, 0, daysAgo: 2)), "10/2 10:00")
  }

  func testWhen() {
    XCTAssertEqual(text.when(.every(1800)), "30分ごと")
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
