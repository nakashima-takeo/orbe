import XCTest

@testable import Orbe

/// ボードの読み替え——自動化の定義と回の記録から、流れの段の件数・回の結果の文・回の区分を作る規則。
///
/// 壊れると何が起きるか: 取得で落ちた回に件数が出て、どこまで届いたかを読み違える。判定が全部を落とした回が「新着なし」と読め、
/// 判定の指示文の誤りに気づけない。失敗した回が一覧の上に来ず、帯や履歴でも失敗の色にならない。
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
    failure: String? = nil, judged: Bool? = nil
  ) -> AutomationRun {
    var run = DesignSceneFixtures.automationRun(
      at: DesignSceneFixtures.automationAt(hour, minute), items: items, newItems: newItems,
      proposed: proposed, failure: failure)
    if judged == true, run.judge == nil {
      run.judge = AutomationJudgeReport(
        commandLine: "claude -p", ending: "exited 1", proposed: 0, resolved: 0,
        rejected: AutomationRejections())
    }
    run.judge?.resolved = resolved
    return run
  }

  private func counts(_ summary: BoardAutomationSummary) -> [Int?] { summary.nodes.map(\.count) }

  func testTheDefinitionReadsAsTriggerSourceSeenJudgeAndTaskCandidates() {
    let summary = BoardAutomationSummary(
      automation([run(14, 40, items: 6, newItems: 5, proposed: 2, resolved: 1)]), text: text)
    XCTAssertEqual(summary.nodes.map(\.role), [.trigger, .source, .orbe, .step(1), .output])
    XCTAssertEqual(summary.nodes.map(\.title), ["10分ごと", "", "既に見たものを除く", "判定", "タスク候補"])
    XCTAssertEqual(summary.nodes[1].means, .command("コマンド"))
    XCTAssertEqual(summary.nodes[1].source, "~/bin/slack-dm.sh")
    XCTAssertEqual(summary.nodes[1].note, "作業ディレクトリ  ~/work")
    XCTAssertEqual(summary.nodes[3].means, .model("sonnet"))
    XCTAssertEqual(counts(summary), [nil, 6, 5, 3, 2], "処理 1 を出た数は提案と対応済みの和、出力先は提案の数")
    XCTAssertTrue(summary.counted)
  }

  /// 失敗した回は届いた段までを数える。
  func testAFailedRunCountsOnlyTheStagesItReached() {
    let fetchFailed = BoardAutomationSummary(
      automation([run(13, 0, items: 0, newItems: 0, failure: "exited 1")]), text: text)
    XCTAssertEqual(counts(fetchFailed), [nil, nil, nil, nil, nil], "取得で落ちた回は何も数えない")

    let judgeFailed = BoardAutomationSummary(
      automation([run(13, 0, items: 6, newItems: 4, failure: "exited 1", judged: true)]),
      text: text)
    XCTAssertEqual(counts(judgeFailed), [nil, 6, 4, nil, nil], "判定で落ちた回は既に見たものを除くまで")

    let nothingNew = BoardAutomationSummary(
      automation([run(13, 0, items: 6, newItems: 0)]), text: text)
    XCTAssertEqual(counts(nothingNew), [nil, 6, 0, nil, nil], "判定を起こさなかった回は処理と出力先へ届いていない")
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

  /// 「今すぐ」の回は時刻の後に印を添え、ほかの日の回は日付付き。
  func testRunTimes() {
    var now = run(14, 12, items: 6, newItems: 0)
    now.trigger = .now
    var yesterday = run(13, 0, items: 6, newItems: 0)
    yesterday.startedAt = DesignSceneFixtures.automationAt(13, 0, daysAgo: 1)
    let summary = BoardAutomationSummary(automation([now, yesterday]), text: text)
    XCTAssertEqual(summary.runs.map(\.at), ["14:12 今すぐ", "10/3 13:00"])
  }

  func testMarksOfALatestFailureAndOfNoRun() {
    let failed = BoardAutomationSummary(
      automation([run(13, 0, items: 0, newItems: 0, failure: "boom")]), text: text)
    XCTAssertEqual(failed.mark, "13:00 に失敗")
    XCTAssertEqual(failed.last, "前回 今日 13:00　失敗：boom")

    let quiet = BoardAutomationSummary(
      automation([run(16, 0, items: 6, newItems: 0)]), text: text)
    XCTAssertEqual(quiet.mark, "16:00 に新着なし")

    let never = BoardAutomationSummary(automation([]), text: text)
    XCTAssertNil(never.mark)
    XCTAssertEqual(never.last, "まだ回っていない")
    XCTAssertEqual(never.runs, [])
  }

  /// 立ち位置の群と右端は、最新の回の区分から決まる。
  func testStandingFollowsTheLatestTone() {
    let runner = DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardDesignFile())
    let standings = runner.store.automations.map {
      BoardAutomationStanding($0, runner: runner, now: DesignSceneFixtures.automationNow)
    }
    XCTAssertEqual(standings.map(\.group), [.active, .active, .failing, .paused, .active])
    XCTAssertEqual(
      standings.map(\.mark), [.ran(.produced), .ran(.quiet), .ran(.failed), .paused, .neverRan])
  }
}
