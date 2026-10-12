import XCTest

@testable import Orbe

/// ボードの読み替え——自動化の回の記録から、流れの段の件数・回の結果の文・回の区分を作る規則。
///
/// 壊れると何が起きるか: 取得で落ちた回に件数が出て、どこまで届いたかを読み違える。判定が全部を落とした回が「新着なし」と読め、
/// 判定の指示文の誤りに気づけない。失敗した回が帯や履歴で失敗の色にならず、一覧の右端に理由の全文があふれる。
@MainActor
final class BoardAutomationSummaryTests: OrbeTestCase {
  private let text = AutomationText(
    l10n: LocalizationStore(language: .ja),
    today: .today(
      DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
    timeZone: DesignSceneFixtures.taskCalendar.timeZone)

  private func automation(_ runs: [AutomationRun]) -> Automation {
    Automation(
      id: 1,
      definition: DesignSceneFixtures.automationDefinition(
        "Slack",
        fetch: AutomationFetch(
          method: .command(BackgroundCommand(script: "~/bin/slack-dm.sh", directory: "~/work")),
          coverage: .newArrivals),
        when: .every(600)),
      paused: false, createdAt: DesignSceneFixtures.automationAt(9), lastFetched: [],
      reviewAll: false, lastRunAt: runs.first?.startedAt, runs: runs)
  }

  private func run(
    _ hour: Int, _ minute: Int, items: Int, newItems: Int, proposed: Int = 0, resolved: Int = 0,
    failure: String? = nil, judged: Bool = false
  ) -> AutomationRun {
    var run = DesignSceneFixtures.automationRun(
      at: DesignSceneFixtures.automationAt(hour, minute), items: items, newItems: newItems,
      proposed: proposed, failure: failure)
    if judged, run.judge == nil {
      run.judge = AutomationJudgeReport(
        commandLine: "claude -p", ending: "exited 1", proposed: 0, resolved: 0,
        rejected: AutomationRejections())
    }
    run.judge?.resolved = resolved
    return run
  }

  /// 前回の件数は最新の回から取り、その回が届いた段までを出す。処理 1 を出た数は提案と対応済みの和、出力先は提案の数。
  func testStageCountsAreTheLatestRunsUpToTheStageItReached() {
    let older = run(14, 30, items: 9, newItems: 9, proposed: 9)
    func counts(_ latest: AutomationRun) -> [Int?] {
      BoardAutomationSummary(automation([latest, older]), text: text).nodes.map(\.count)
    }
    XCTAssertEqual(
      counts(run(14, 40, items: 6, newItems: 5, proposed: 2, resolved: 1)), [nil, 6, 5, 3, 2])
    XCTAssertEqual(
      counts(run(14, 40, items: 6, newItems: 0)), [nil, 6, 0, nil, nil],
      "判定を起こさなかった回は処理と出力先へ届いていない")
    XCTAssertEqual(
      counts(run(14, 40, items: 6, newItems: 4, failure: "exited 1", judged: true)),
      [nil, 6, 4, nil, nil], "判定で落ちた回は既に見たものを除くまで")
    XCTAssertEqual(
      counts(run(14, 40, items: 0, newItems: 0, failure: "exited 1")), [nil, nil, nil, nil, nil],
      "取得で落ちた回は何も数えない")
  }

  func testRunResultsAndTones() {
    let summary = BoardAutomationSummary(
      automation([
        run(14, 40, items: 6, newItems: 5, proposed: 2),
        run(14, 30, items: 6, newItems: 0),
        run(14, 20, items: 6, newItems: 3),
        run(14, 10, items: 6, newItems: 3, resolved: 2),
        run(14, 0, items: 0, newItems: 0, failure: "取得元が終了コード 1"),
      ]), text: text)
    XCTAssertEqual(
      summary.runs.map(\.result),
      ["2件を追加", "新着なし", "処理 1 ですべて除外", "追加なし", "失敗：取得元が終了コード 1"])
    XCTAssertEqual(summary.runs.map(\.tone), [.produced, .quiet, .quiet, .quiet, .failed])
    XCTAssertEqual(summary.strip, [.failed, .quiet, .quiet, .quiet, .produced], "帯は古い回が左")
    XCTAssertEqual(summary.mark, "14:40 に 2件を追加")
    XCTAssertEqual(summary.last, "前回 今日 14:40　2件をタスク候補に追加")
  }

  func testMarksOfALatestFailureAndOfNoRun() {
    let failed = BoardAutomationSummary(
      automation([run(13, 0, items: 0, newItems: 0, failure: "boom")]), text: text)
    XCTAssertEqual(failed.mark, "13:00 に失敗")
    XCTAssertEqual(failed.last, "前回 今日 13:00　失敗")

    let quiet = BoardAutomationSummary(
      automation([run(16, 0, items: 6, newItems: 0)]), text: text)
    XCTAssertEqual(quiet.mark, "16:00 に新着なし")

    let never = BoardAutomationSummary(automation([]), text: text)
    XCTAssertNil(never.mark)
    XCTAssertEqual(never.last, "まだ回っていない")
    XCTAssertEqual(never.runs, [])
  }
}
