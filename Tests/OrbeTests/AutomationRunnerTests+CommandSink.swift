import XCTest

@testable import Orbe

/// 出力先のコマンド。届いた行を 1 行 1 オブジェクトで標準入力に受け、回の ID を `ORBE_RUN_ID` で受ける。行を作るもの（取得元か
/// 段）がある自動化では届いた行が 1 行以上のときだけ走り、無い自動化はトリガーのたびに走る。最後の段の出力が全行とも形違いの回・
/// コマンドが 0 以外で終わった回は失敗で、項目は次の回にもう一度流れる。
///
/// 壊れると何が起きるか: 新着の無い回にも投稿のコマンドが走る。段が 0 個の自動化がコマンドに届かない。取得元の無い自動化の回の
/// 開始が決まらず番人が回し続ける。やり直しの回に別の ID が渡り、同じ回の副作用が二重に起きる。
extension AutomationRunnerTests {
  static func commandSink(
    _ script: String = "~/bin/post.sh", directory: String? = nil, timeoutMinutes: Int? = nil
  ) -> AutomationSink {
    .command(
      AutomationSinkCommand(
        command: BackgroundCommand(script: script, directory: directory),
        timeoutMinutes: timeoutMinutes))
  }

  private func commandDefinition(
    sourced: Bool = true, steps: [AutomationStep] = [], timeoutMinutes: Int? = nil
  ) -> AutomationDefinition {
    var definition = AutomationStoreTests.definition()
    if !sourced { definition.source = nil }
    definition.steps = steps
    definition.sink = Self.commandSink(timeoutMinutes: timeoutMinutes)
    return definition
  }

  private func sinkInput(_ index: Int) -> BackgroundInput? {
    guard case .command(let command, let input) = jobs.calls[index].job.work,
      command.script == "~/bin/post.sh"
    else { return nil }
    return input
  }

  private func ended(_ exit: Int32, stderr: String = "") -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "~/bin/post.sh", startedAt: Date(), endedAt: Date(), ending: .exited(exit),
      output: .command(stdout: .init(), stderr: .init(data: Data(stderr.utf8))))
  }

  /// 取得元も段も無い自動化は、トリガーのたびに空の標準入力で走る。回の開始は Orbe が回を始めた時刻なので、番人は次の予定まで
  /// 待つ。
  func testACommandWithoutSourceOrStepsRunsOnEachTriggerWithEmptyStdin() throws {
    let automation = try create(commandDefinition(sourced: false))
    let runId = automation.runId

    now = automation.createdAt.addingTimeInterval(60)
    try runner.runNow(automation.id)
    XCTAssertEqual(jobs.calls.count, 1)
    let input = try XCTUnwrap(sinkInput(0))
    XCTAssertEqual(input.stdin, Data())
    XCTAssertEqual(input.environment, ["ORBE_RUN_ID": runId])
    XCTAssertEqual(jobs.calls[0].job.limits.elapsed, 120, "上限の既定は 2 分")
    XCTAssertEqual(jobs.calls[0].job.limits.idle, 120, "出力の無い時間も同じ上限")
    jobs.finish(0, ended(0))

    let stored = try XCTUnwrap(store.automation(automation.id))
    let run = try XCTUnwrap(stored.runs.first)
    XCTAssertNil(run.failure)
    XCTAssertEqual(
      run.sink,
      .command(AutomationCommandReport(commandLine: "~/bin/post.sh", ending: "exited 0", count: 0)))
    XCTAssertEqual(run.startedAt, now, "開始は回を始めた時刻（走らせたものの時刻ではない）")
    XCTAssertNotEqual(stored.runId, runId, "記録された回の次は別の ID")
    XCTAssertFalse(runner.isRunning(automation.id))
    XCTAssertEqual(stored.lastRunAt, now, "数え始めが回の開始へ進む（番人が回し続けない）")
  }

  /// 段が無ければ取得元の新しい項目の行がそのまま届き、新着の無い回はコマンドを起こさずに成功する。
  func testWithoutStepsTheNewItemsReachTheCommandAndNothingNewRunsNothing() throws {
    let automation = try create(commandDefinition())
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a", "b"]))

    let input = try XCTUnwrap(sinkInput(1))
    let lines = String(bytes: input.stdin ?? Data(), encoding: .utf8)?.split(separator: "\n") ?? []
    XCTAssertEqual(lines.map { AutomationPrompts.id(of: String($0)) }, ["a", "b"], "1 行 1 項目")
    jobs.finish(1, ended(0))
    XCTAssertEqual(
      store.automation(automation.id)?.runs.first?.sink,
      .command(AutomationCommandReport(commandLine: "~/bin/post.sh", ending: "exited 0", count: 2)))

    try runner.runNow(automation.id)
    jobs.finish(2, fetched(["a", "b"]))
    XCTAssertEqual(jobs.calls.count, 3, "新着の無い回はコマンドを起こさない")
    let quiet = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(quiet.failure)
    XCTAssertNil(quiet.sink, "走らなかった回は出力先の記録を持たない")
  }

  /// 最後の段の出力が届き、最後の agent の段は中間の段と同じ枠で頼まれる。段が 0 行を出した回は走らずに成功し、出力が全行とも
  /// 形違いの回は失敗にして項目を次の回に流し直す。
  func testTheLastStepFeedsTheCommandAndAllMalformedOutputFailsTheRun() throws {
    let step = AutomationStep(
      name: "要約", method: .agent(AutomationStepAgent(cli: "claude", model: nil, instruction: "要約")))
    let automation = try create(commandDefinition(steps: [step]))

    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))
    XCTAssertTrue(prompt(1).contains(#"Keep the "id" of each item you pass on"#), "中間の段の枠")
    jobs.finish(1, replied("not json\nalso not json"))
    XCTAssertEqual(jobs.calls.count, 2)
    var run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertEqual(run.failure, "every line of the output of the last step was malformed")
    XCTAssertEqual(run.steps.map(\.count), [0])
    XCTAssertEqual(run.steps.map(\.rejected.count), [2])
    XCTAssertNil(run.sink, "最後の段で落ちた回は出力先の記録を持たない")
    XCTAssertEqual(store.automation(automation.id)?.lastFetched, [], "項目は次の回にもう一度流れる")

    try runner.runNow(automation.id)
    jobs.finish(2, fetched(["a"]))
    jobs.finish(3, replied(""))
    XCTAssertEqual(jobs.calls.count, 4, "段が 0 行を出した回は走らない")
    run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(run.failure)
    XCTAssertNil(run.sink)

    try runner.runNow(automation.id)
    jobs.finish(4, fetched(["a", "b"]))
    jobs.finish(5, replied(#"{"id":"b","summary":"b"}"#))
    let input = try XCTUnwrap(sinkInput(6))
    XCTAssertEqual(input.stdin, Data(#"{"id":"b","summary":"b"}"#.appending("\n").utf8))
  }

  /// 0 以外で終わった回は標準エラーの抜粋つきの失敗で、出力先で落ちた印に出力先の記録を持ち、項目は次の回にもう一度流れる。
  /// 上限は書いた分で経過と無出力の両方に当てる。
  func testAFailingCommandFailsTheRunAndTheItemsFlowAgain() throws {
    let automation = try create(commandDefinition(timeoutMinutes: 10))
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))
    XCTAssertEqual(jobs.calls[1].job.limits.elapsed, 600)
    XCTAssertEqual(jobs.calls[1].job.limits.idle, 600)
    jobs.finish(1, ended(1, stderr: "rate limited\n"))

    let run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertEqual(run.failure, "the sink command ended: exited 1: rate limited")
    XCTAssertEqual(
      run.sink,
      .command(AutomationCommandReport(commandLine: "~/bin/post.sh", ending: "exited 1", count: 1)))
    try runner.runNow(automation.id)
    jobs.finish(2, fetched(["a"]))
    XCTAssertNotNil(sinkInput(3), "失敗した回の項目をもう一度渡す")
  }

  /// 記録される前に止めた回のやり直しは同じ ID を受ける——コマンドが ID で二重実行を防げる。
  func testARunStoppedBeforeItIsRecordedIsRetriedWithTheSameRunId() throws {
    let automation = try create(commandDefinition(sourced: false))
    try runner.runNow(automation.id)

    var edited = commandDefinition(sourced: false)
    edited.sink = Self.commandSink("~/bin/post.sh --all")
    _ = try runner.set(automation.id, edited)
    XCTAssertEqual(jobs.stopped, [0], "コマンドを書き換えると走っている回を止める")
    edited.sink = Self.commandSink()
    _ = try runner.set(automation.id, edited)
    try runner.runNow(automation.id)

    XCTAssertEqual(
      sinkInput(1)?.environment["ORBE_RUN_ID"], sinkInput(0)?.environment["ORBE_RUN_ID"])
    XCTAssertEqual(store.automation(automation.id)?.runs, [])
  }
}
