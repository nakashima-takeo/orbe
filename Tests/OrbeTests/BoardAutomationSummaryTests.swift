import XCTest

@testable import Orbe

/// ボードの読み替え——自動化の回の記録から、流れの段の件数・回の結果の文・回の区分を作る規則。
///
/// 壊れると何が起きるか: 取得で落ちた回に件数が出て、どこまで届いたかを読み違える。判定が全部を落とした回が「新着なし」と読め、
/// 判定の指示文の誤りに気づけない。失敗した回が帯や履歴で失敗の色にならず、一覧の右端に理由の全文があふれる。
@MainActor
final class BoardAutomationSummaryTests: OrbeTestCase {
  let text = AutomationText(
    l10n: LocalizationStore(language: .ja),
    today: .today(
      DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
    timeZone: DesignSceneFixtures.taskCalendar.timeZone)

  private func automation(
    _ runs: [AutomationRun], steps: [AutomationStep]? = nil, sourced: Bool = true
  ) -> Automation {
    var definition = DesignSceneFixtures.automationDefinition(
      "Slack",
      source: AutomationSource(
        method: .command(BackgroundCommand(script: "~/bin/slack-dm.sh", directory: "~/work")),
        coverage: .newArrivals),
      trigger: .every(600))
    if let steps { definition.steps = steps }
    if !sourced { definition.source = nil }
    return Automation(
      id: 1, definition: definition, paused: false,
      createdAt: DesignSceneFixtures.automationAt(9), lastFetched: [], reviewAll: false,
      lastRunAt: runs.first?.startedAt, runs: runs)
  }

  /// 段が出した数は、最後の段では提案と対応済みの行の和。`steps` を渡せば各段の出した数を、`names` の段名で記録にし、
  /// 最後の段は `countedBySink` なら出力先が数えた段（偽なら 0 行を出して止めた段）にする。
  private func run(
    _ hour: Int, _ minute: Int, items: Int, fresh: Int, proposed: Int = 0, resolved: Int = 0,
    steps: [Int]? = nil, names: [String] = ["判定"], countedBySink: Bool = true,
    failure: String? = nil, failedInStep: Bool = false
  ) -> AutomationRun {
    var run = DesignSceneFixtures.automationRun(
      at: DesignSceneFixtures.automationAt(hour, minute), items: items, fresh: fresh,
      proposed: proposed, failure: failure)
    if failedInStep {
      run.fresh = fresh
      run.steps = [Self.report(0, name: names[0])]
    }
    if let steps {
      run.steps = zip(steps, names).map { Self.report($0, name: $1) }
      run.lastStepCountedBySink = countedBySink
    }
    if resolved > 0 {
      run.steps[run.steps.count - 1].count = proposed + resolved
      run.sink = .taskCandidates(
        AutomationTaskCandidatesReport(proposed: proposed, resolved: resolved))
    }
    return run
  }

  private static func report(_ count: Int, name: String) -> AutomationStepReport {
    AutomationStepReport(
      name: name, commandLine: "claude -p", ending: "exited 0", count: count,
      rejected: AutomationRejections())
  }

  private static func agentStep(_ name: String) -> AutomationStep {
    AutomationStep(
      name: name, method: .agent(AutomationStepAgent(cli: "claude", model: nil, instruction: name)))
  }

  /// 前回の件数は最新の回の段ごとの件数から取り、その回が届いた段までを出す。出力先は提案の数。
  func testStageCountsAreTheLatestRunsUpToTheStageItReached() {
    let older = run(14, 30, items: 9, fresh: 9, proposed: 9)
    func counts(_ latest: AutomationRun) -> [Int?] {
      BoardAutomationSummary(automation([latest, older]), text: text).nodes.map(\.count)
    }
    XCTAssertEqual(
      counts(run(14, 40, items: 6, fresh: 5, proposed: 2, resolved: 1)), [nil, 6, 5, 3, 2])
    XCTAssertEqual(
      counts(run(14, 40, items: 6, fresh: 0)), [nil, 6, 0, nil, nil],
      "新しい項目が無かった回は処理と出力先へ届いていない")
    XCTAssertEqual(
      counts(run(14, 40, items: 6, fresh: 4, failure: "exited 1", failedInStep: true)),
      [nil, 6, 4, nil, nil], "段で落ちた回は、その段の手前まで")
    var sinkFailed = run(
      14, 40, items: 6, fresh: 4, steps: [3], failure: "the sink command ended: exited 1",
      failedInStep: true)
    sinkFailed.sink = .command(
      AutomationCommandReport(commandLine: "~/bin/post.sh", ending: "exited 1", count: 3))
    var commanding = automation([sinkFailed])
    commanding.redefine { $0.sink = AutomationRunnerTests.commandSink() }
    XCTAssertEqual(
      BoardAutomationSummary(commanding, text: text).nodes.map(\.count), [nil, 6, 4, 3, nil],
      "出力先で落ちた回は最後の段まで出し、出力先は出さない")
    XCTAssertEqual(
      counts(run(14, 40, items: 0, fresh: 0, failure: "exited 1")), [nil, nil, nil, nil, nil],
      "取得元で落ちた回は何も数えない")
  }

  /// 段を並べた自動化は段ごとに名前・手段・解いたモデルと件数を出す。途中の段が 0 件を出した回は、その先へ届いていない。
  func testStepsAreListedWithTheirResolvedModelsAndCounts() {
    let summary = BoardAutomationSummary(
      automation(
        [
          run(
            14, 40, items: 6, fresh: 5, steps: [3, 0], names: ["雑談を除く", "依頼を絞る"],
            countedBySink: false)
        ],
        steps: [Self.agentStep("雑談を除く"), Self.agentStep("依頼を絞る"), Self.agentStep("判定")]),
      text: text)
    XCTAssertEqual(
      summary.nodes.map(\.role),
      [.trigger, .source, .orbe, .step(1), .step(2), .step(3), .output])
    XCTAssertEqual(summary.nodes[3].title, "雑談を除く")
    XCTAssertEqual(
      summary.nodes.compactMap(\.means),
      [.command("コマンド"), .model("haiku"), .model("haiku"), .model("sonnet")])
    XCTAssertEqual(summary.nodes.map(\.count), [nil, 6, 5, 3, 0, nil, nil])
    XCTAssertEqual(summary.runs.map(\.result), ["処理 2 ですべて除外"])
  }

  /// 書き換えても回の記録は残る。前回の件数は段名の並びと出力先の種類が合う段にだけ出し、最初に食い違った段から先と、種類の
  /// 違う出力先（とそれが数えた最後の段）には出さない。今の最後の段には、出力先が数えた数だけを出す。
  func testCountsAreShownOnlyOnStagesTheLatestRunRanAs() {
    let ran = run(14, 40, items: 6, fresh: 5, proposed: 2, steps: [5, 2], names: ["A", "B"])
    func counts(_ steps: [String], sink: AutomationSink = .taskCandidates) -> [Int?] {
      var rewritten = automation([ran], steps: steps.map(Self.agentStep))
      rewritten.redefine { $0.sink = sink }
      return BoardAutomationSummary(rewritten, text: text).nodes.map(\.count)
    }
    XCTAssertEqual(counts(["A", "B"]), [nil, 6, 5, 5, 2, 2], "同じ並びなら全段に出す")
    XCTAssertEqual(
      counts(["A", "X", "B"]), [nil, 6, 5, 5, nil, nil, nil], "足した段から先と出力先は出さない")
    XCTAssertEqual(counts(["X", "B"]), [nil, 6, 5, nil, nil, nil], "名前の変わった段から先は出さない")
    XCTAssertEqual(
      counts(["A"]), [nil, 6, 5, nil, nil], "段を消すと、最後の段になった段の数は出力先が数えたものでない")
    XCTAssertEqual(
      counts(["A", "B"], sink: .report), [nil, 6, 5, 5, nil, nil],
      "出力先の種類が違えば、出力先とそれが数えた最後の段は出さない")
  }

  /// 出力先が報告の回を、報告の定義のまま段を書き換えた直後の件数。最後の段の数は報告の有無（1・0）で、出した行の数ではない。
  private func reportCounts(after steps: [String]) -> [Int?] {
    var ran = run(14, 40, items: 6, fresh: 5, steps: [5, 1], names: ["A", "B"])
    ran.sink = .report(text: "PR は 2 件")
    var rewritten = automation([ran], steps: steps.map(Self.agentStep))
    rewritten.redefine { $0.sink = .report }
    return BoardAutomationSummary(rewritten, text: text).nodes.map(\.count)
  }

  func testAStepAddedAfterTheLastStepOfAReportHidesTheReportCount() {
    XCTAssertEqual(reportCounts(after: ["A", "B"]), [nil, 6, 5, 5, 1, 1])
    XCTAssertEqual(
      reportCounts(after: ["A", "B", "C"]), [nil, 6, 5, 5, nil, nil, nil],
      "報告の有無を、中間の段が出した行の数として出さない")
  }

  func testRemovingTheLastStepOfAReportHidesTheRowsOfTheNewLastStep() {
    XCTAssertEqual(
      reportCounts(after: ["A"]), [nil, 6, 5, nil, nil], "中間の段が出した行の数を、報告の有無として出さない")
  }

  /// 途中の段が 0 行で止まった回の最後の段は、その段が出した数。出力先の種類だけを変えても段の数は出し、出力先は出さない。
  func testChangingOnlyTheSinkKeepsTheCountsOfARunStoppedByAnEmptyStep() {
    let stopped = run(
      14, 40, items: 6, fresh: 5, steps: [3, 0], names: ["A", "B"], countedBySink: false)
    for sink in [AutomationSink.report, AutomationRunnerTests.commandSink()] {
      var rewritten = automation([stopped], steps: ["A", "B", "C"].map(Self.agentStep))
      rewritten.redefine { $0.sink = sink }
      XCTAssertEqual(
        BoardAutomationSummary(rewritten, text: text).nodes.map(\.count),
        [nil, 6, 5, 3, 0, nil, nil])
    }
  }

  /// タスク候補の出力先は、0 件でも採用・見送りの累計を出力先の段の注記に出す。
  func testTheTaskCandidatesOutputNotesTheTally() throws {
    var counted = automation([])
    XCTAssertEqual(
      BoardAutomationSummary(counted, text: text).nodes.last?.notes, ["これまでに採用 0件 / 見送り 0件"])

    counted = Automation(
      id: 1, definition: counted.definition,
      sinkState: .taskCandidates(AutomationTaskCandidatesState(accepted: 9, dismissed: 3)),
      paused: false, createdAt: counted.createdAt, lastFetched: [], reviewAll: false, runs: [])
    let output = try XCTUnwrap(BoardAutomationSummary(counted, text: text).nodes.last)
    XCTAssertEqual(output.role, .output)
    XCTAssertEqual(output.notes, ["これまでに採用 9件 / 見送り 3件"])
  }

  func testAnAutomationWithoutASourceIsTriggerThenOutput() {
    let summary = BoardAutomationSummary(automation([], steps: [], sourced: false), text: text)
    XCTAssertEqual(summary.nodes.map(\.role), [.trigger, .output])
    XCTAssertFalse(summary.counted)
  }

  func testRunResultsAndTones() {
    let summary = BoardAutomationSummary(
      automation([
        run(14, 40, items: 6, fresh: 5, proposed: 2),
        run(14, 30, items: 6, fresh: 0),
        run(14, 20, items: 6, fresh: 3),
        run(14, 10, items: 6, fresh: 3, resolved: 2),
        run(14, 0, items: 0, fresh: 0, failure: "取得元が終了コード 1"),
      ]), text: text)
    XCTAssertEqual(
      summary.runs.map(\.result),
      ["2件を追加", "新着なし", "処理 1 ですべて除外", "追加なし", "失敗：取得元が終了コード 1"])
    XCTAssertEqual(summary.runs.map(\.tone), [.produced, .quiet, .quiet, .quiet, .failed])
    XCTAssertEqual(summary.strip, [.failed, .quiet, .quiet, .quiet, .produced], "帯は古い回が左")
    XCTAssertEqual(summary.mark, "14:40 に 2件を追加")
    XCTAssertEqual(summary.last, "前回 今日 14:40　2件をタスク候補に追加")
  }

  /// 出力先のコマンドは、コマンドの全文・作業ディレクトリを出力先の段に出し（手段の札は題と同じ語なので出さない）、走った回を
  /// 「完了」として出した回に数える。件数の列の出力先は渡した行の数で、新着の無い回は出力先へ届いていないので出さない。
  func testACommandOutputShowsItsCommandAndCountsRunsAsDone() throws {
    func ran(_ hour: Int, count: Int, sourced: Bool) -> AutomationRun {
      var run = DesignSceneFixtures.automationRun(
        at: DesignSceneFixtures.automationAt(hour), items: 3, fresh: 3)
      if !sourced {
        run.source = nil
        run.fresh = nil
      }
      run.steps = []
      run.lastStepCountedBySink = false
      run.sink = .command(
        AutomationCommandReport(
          commandLine: "~/bin/daily-note.sh", ending: "exited 0", count: count))
      return run
    }
    func commanding(_ runs: [AutomationRun], sourced: Bool) -> Automation {
      var definition = automation([], steps: [], sourced: sourced).definition
      definition.sink = AutomationRunnerTests.commandSink(
        "~/bin/daily-note.sh", directory: "/Users/me")
      return Automation(
        id: 1, definition: definition, paused: false,
        createdAt: DesignSceneFixtures.automationAt(9), lastFetched: [], reviewAll: false,
        runs: runs)
    }

    let alone = BoardAutomationSummary(
      commanding([ran(23, count: 0, sourced: false)], sourced: false), text: text)
    XCTAssertEqual(alone.output, "コマンド")
    let output = try XCTUnwrap(alone.nodes.last)
    XCTAssertEqual(output.role, .output)
    XCTAssertNil(output.means)
    XCTAssertEqual(output.verbatim, "~/bin/daily-note.sh")
    XCTAssertEqual(output.notes, ["作業ディレクトリ  /Users/me"])
    XCTAssertEqual(alone.runs.map(\.result), ["完了"])
    XCTAssertEqual(alone.runs.map(\.tone), [.produced])
    XCTAssertEqual(alone.mark, "23:00 に完了")
    XCTAssertEqual(alone.last, "前回 今日 23:00　完了")

    let sourced = BoardAutomationSummary(
      commanding(
        [ran(23, count: 3, sourced: true), run(22, 0, items: 3, fresh: 0)], sourced: true),
      text: text)
    XCTAssertEqual(sourced.nodes.map(\.count), [nil, 3, 3, 3])
    XCTAssertEqual(sourced.runs.map(\.result), ["完了", "新着なし"])
    XCTAssertEqual(sourced.runs.map(\.tone), [.produced, .quiet])

    var nothingNew = run(22, 0, items: 3, fresh: 0)
    nothingNew.sink = nil
    let quiet = BoardAutomationSummary(commanding([nothingNew], sourced: true), text: text)
    XCTAssertEqual(quiet.nodes.map(\.count), [nil, 3, 0, nil])
  }

  func testMarksOfALatestFailureAndOfNoRun() {
    let failed = BoardAutomationSummary(
      automation([run(13, 0, items: 0, fresh: 0, failure: "boom")]), text: text)
    XCTAssertEqual(failed.mark, "13:00 に失敗")
    XCTAssertEqual(failed.last, "前回 今日 13:00　失敗")

    let quiet = BoardAutomationSummary(
      automation([run(16, 0, items: 6, fresh: 0)]), text: text)
    XCTAssertEqual(quiet.mark, "16:00 に新着なし")

    let never = BoardAutomationSummary(automation([]), text: text)
    XCTAssertNil(never.mark)
    XCTAssertEqual(never.last, "まだ回っていない")
    XCTAssertEqual(never.runs, [])
  }
}
