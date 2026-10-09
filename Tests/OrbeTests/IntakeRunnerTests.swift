import XCTest

@testable import Orbe

/// 受信の走らせ役——取得 → 新しい項目 → 判定 → 確定を番人の 1 回として進める。新しい項目が無ければ判定を起こさない、
/// 走っている間の「今すぐ」は断る、取得か判定の書き換え・削除は走っている回を止めて結果を捨てる、名前やいつの書き換え・
/// 止める／再開は走っている回を止めない、失敗した回は何も進めない。
///
/// 壊れると何が起きるか。新しいものが無い回にも claude が立ち上がる。止める／再開で取得中の回が殺される。書き換える前の
/// 取得の結果が新しい定義の回として確定する。ツールが使えなかった回を 0 件と読み、提案が一斉に下がる。
final class IntakeRunnerTests: OrbeTestCase {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private var now = Date(timeIntervalSince1970: 1_800_000_000)
  private var armed: (date: Date, fire: () -> Void)?
  private var jobs: FakeJobs!
  private var store: IntakeStore!
  private var runner: IntakeRunner!

  override func setUp() {
    jobs = FakeJobs()
    store = IntakeStore(file: nil)
    runner = makeRunner()
  }

  private func makeRunner() -> IntakeRunner {
    let scheduler = BackgroundScheduler { _, _ in BackgroundRunHandle {} }
    scheduler.now = { [unowned self] in now }
    scheduler.calendar = { Calendar(identifier: .gregorian) }
    scheduler.arm = { [unowned self] date, fire in
      armed = (date, fire)
      return { [unowned self] in armed = nil }
    }
    let runner = IntakeRunner(store: store, scheduler: scheduler, run: jobs.run)
    runner.now = { [unowned self] in now }
    return runner
  }

  private func advance(to date: Date) {
    now = date
    if let armed, armed.date <= date { armed.fire() }
  }

  private func create(_ definition: IntakeDefinition = IntakeStoreTests.definition()) throws
    -> Intake
  {
    try runner.set(nil, definition)
  }

  private func line(_ id: String) -> String {
    #"{"id":"\#(id)","link":"https://example.com/\#(id)","body":"\#(id) の本文","time":"2026-10-10T09:00:00Z"}"#
  }

  private func fetched(_ ids: [String], exit: Int32 = 0, stderr: String = "") -> BackgroundRunResult
  {
    BackgroundRunResult(
      commandLine: "fetch", startedAt: now, endedAt: now, ending: .exited(exit),
      output: .command(
        stdout: .init(data: Data(ids.map(line).joined(separator: "\n").utf8)),
        stderr: .init(data: Data(stderr.utf8))))
  }

  private func replied(_ text: String, isError: Bool = false) -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "claude -p", startedAt: now, endedAt: now, ending: .exited(0),
      output: .agent(reply: BackgroundAgentReply(text: text, isError: isError), stderr: .init()))
  }

  private func prompt(_ index: Int) -> String {
    guard case .agent(let call) = jobs.calls[index].job.work else { return "" }
    return call.prompt
  }

  // MARK: - 1 回

  func testScheduledRunJudgesOnlyNewItemsAndCommits() throws {
    let intake = try create()

    advance(to: start.addingTimeInterval(1800))
    XCTAssertEqual(jobs.calls.map(\.job), [.command(BackgroundCommand(script: "fetch"))])
    XCTAssertTrue(runner.isRunning(intake.id))
    jobs.finish(0, fetched(["a", "b"]))

    XCTAssertEqual(jobs.calls.count, 2, "新しい項目があるので判定を起こす")
    guard case .agent(let call) = jobs.calls[1].job.work else { return XCTFail("判定は agent") }
    XCTAssertEqual(call.tools, [], "判定はツールを持たない")
    XCTAssertEqual(call.model, "haiku")
    jobs.finish(1, replied(#"{"propose":"a","title":"a に返信する"}"#))

    XCTAssertFalse(runner.isRunning(intake.id))
    XCTAssertEqual(store.proposals.map(\.title), ["a に返信する"])
    let run = try XCTUnwrap(store.intake(intake.id)?.runs.first)
    XCTAssertEqual(run.trigger, .schedule)
    XCTAssertEqual(run.fetch.items, 2)
    XCTAssertEqual(run.newItems, 2)
    XCTAssertEqual(run.judge?.proposed, 1)
    XCTAssertNil(run.failure)
    XCTAssertEqual(store.intake(intake.id)?.lastRunAt, now)
    XCTAssertEqual(armed?.date, now.addingTimeInterval(1800), "取得の開始から数え直す")
  }

  /// 前の回に無かった項目だけが判定に回り、新しい項目が無い回は判定を起こさない。
  func testOnlyNewItemsReachTheJudgeAndNoNewItemsMeansNoJudge() throws {
    let intake = try create()
    try runner.runNow(intake.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, replied(""))

    try runner.runNow(intake.id)
    jobs.finish(2, fetched(["a", "b"]))
    XCTAssertTrue(prompt(3).contains(#""id":"b""#))
    XCTAssertFalse(prompt(3).contains(#""id":"a""#), "前の回に取れた項目は判定に回さない")
    jobs.finish(3, replied(""))

    try runner.runNow(intake.id)
    jobs.finish(4, fetched(["a", "b"]))

    XCTAssertEqual(jobs.calls.count, 5, "新しい項目が無い回は判定を起こさない")
    let run = try XCTUnwrap(store.intake(intake.id)?.runs.first)
    XCTAssertEqual(run.trigger, .now)
    XCTAssertEqual(run.newItems, 0)
    XCTAssertNil(run.judge)
    XCTAssertFalse(runner.isRunning(intake.id))
  }

  func testRunNowIsRefusedWhileRunning() throws {
    let intake = try create()
    try runner.runNow(intake.id)

    XCTAssertThrowsError(try runner.runNow(intake.id)) {
      XCTAssertEqual($0 as? IntakeError, .running(intake.id))
    }
    XCTAssertThrowsError(try runner.runNow(99)) {
      XCTAssertEqual($0 as? IntakeError, .intakeNotFound(99))
    }
    XCTAssertEqual(jobs.calls.count, 1)
  }

  /// 止めた受信は予定では回らないが、「今すぐ」は受ける。
  func testPausedIntakeRunsOnlyWhenAskedNow() throws {
    let intake = try create()
    _ = try runner.pause(intake.id, true)

    advance(to: start.addingTimeInterval(86400))
    XCTAssertEqual(jobs.calls.count, 0)
    XCTAssertNil(runner.nextRunAt(store.intake(intake.id)!))

    try runner.runNow(intake.id)
    XCTAssertEqual(jobs.calls.count, 1)
  }

  /// 長く止めていた受信を再開すると、数え始め（最後に回った時刻）は動かないので、過ぎた回として 1 回すぐ回る。
  func testResumingALongPausedIntakeRunsOnceRightAway() throws {
    let intake = try create()
    try runner.runNow(intake.id)
    jobs.finish(0, fetched([]))
    _ = try runner.pause(intake.id, true)
    advance(to: start.addingTimeInterval(86400))
    XCTAssertEqual(jobs.calls.count, 1, "止めている間は回らない")

    _ = try runner.pause(intake.id, false)

    XCTAssertEqual(jobs.calls.count, 2, "再開したらまず最新を取る")
    guard jobs.calls.count == 2 else { return }
    XCTAssertTrue(runner.isRunning(intake.id))
    jobs.finish(1, fetched([]))
    XCTAssertEqual(store.intake(intake.id)?.runs.first?.trigger, .schedule)
    XCTAssertEqual(jobs.calls.count, 2, "過ぎた回は何回分でも 1 回だけ")
  }

  /// 番人の予定に載ったまま受信がストアから消えていても、回はすぐ終わり、「走っている」が残らない。
  func testMissingIntakeEndsTheRunAtOnce() throws {
    let intake = try create()
    try store.delete(intake.id)

    advance(to: start.addingTimeInterval(1800))

    XCTAssertFalse(runner.isRunning(intake.id))
    XCTAssertEqual(jobs.calls.count, 0)
    XCTAssertEqual(armed?.date, now.addingTimeInterval(1800), "終わりを受けて数え直している")
  }

  // MARK: - 書き換えと競合

  /// 取得か判定の書き換えは、走っている段を止め、その結果を新しい定義の回として確定しない。
  func testReworkStopsTheRunningRunAndDropsItsResult() throws {
    let intake = try create()
    try runner.runNow(intake.id)

    _ = try runner.set(intake.id, IntakeStoreTests.definition(script: "fetch --since 1d"))
    jobs.finish(0, fetched(["a"]))

    XCTAssertEqual(jobs.stopped, [0])
    XCTAssertEqual(jobs.calls.count, 1, "止めた回の続き（判定）を起こさない")
    XCTAssertEqual(store.intake(intake.id)?.runs, [])
    XCTAssertFalse(runner.isRunning(intake.id))
  }

  /// 判定の最中に書き換えても同じ。判定の結果は捨てる。
  func testReworkDuringTheJudgeDropsTheJudgement() throws {
    let intake = try create()
    try runner.runNow(intake.id)
    jobs.finish(0, fetched(["a"]))

    _ = try runner.set(intake.id, IntakeStoreTests.definition(instruction: "別の指示"))
    jobs.finish(1, replied(#"{"propose":"a","title":"古い指示の提案"}"#))

    XCTAssertEqual(jobs.stopped, [1])
    XCTAssertEqual(store.proposals, [])
  }

  /// 名前やいつだけの書き換え・止める／再開は、走っている回を止めない。
  func testRenameAndPauseKeepTheRunningRun() throws {
    let intake = try create()
    try runner.runNow(intake.id)

    _ = try runner.set(intake.id, IntakeStoreTests.definition("新しい名前", when: .every(600)))
    _ = try runner.pause(intake.id, true)
    _ = try runner.pause(intake.id, false)
    XCTAssertTrue(runner.isRunning(intake.id))
    jobs.finish(0, fetched([]))

    XCTAssertEqual(jobs.stopped, [])
    XCTAssertEqual(store.intake(intake.id)?.runs.count, 1)
    XCTAssertEqual(armed?.date, now.addingTimeInterval(600), "新しいいつで数え直す")
  }

  func testDeleteStopsTheRunningRun() throws {
    let intake = try create()
    try runner.runNow(intake.id)

    try runner.delete(intake.id)
    jobs.finish(0, fetched(["a"]))

    XCTAssertEqual(jobs.stopped, [0])
    XCTAssertEqual(jobs.calls.count, 1)
    XCTAssertNil(armed)
  }

  // MARK: - 失敗した回

  func testFetchFailureLeavesProposalsAndRecordsTheReason() throws {
    let intake = try create()
    try runner.runNow(intake.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, replied(#"{"propose":"a","title":"返信する"}"#))

    try runner.runNow(intake.id)
    jobs.finish(2, fetched([], exit: 1, stderr: "token expired\n"))

    XCTAssertEqual(store.proposals.count, 1, "失敗を 0 件と読んで提案を下げない")
    XCTAssertEqual(store.intake(intake.id)?.lastFetched.map(\.id), ["a"])
    XCTAssertEqual(
      store.intake(intake.id)?.runs.first?.failure, "the fetch ended: exited 1: token expired")
  }

  /// 判定が失敗した回は取得済みも進めないので、同じ項目は次の回でまた判定に回る。
  func testJudgeFailureKeepsTheItemsNewForTheNextRun() throws {
    let intake = try create()
    try runner.runNow(intake.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, replied("overloaded", isError: true))

    let run = try XCTUnwrap(store.intake(intake.id)?.runs.first)
    XCTAssertEqual(run.failure, "the judge agent reported an error: overloaded")
    XCTAssertEqual(store.intake(intake.id)?.lastFetched, [])
    try runner.runNow(intake.id)
    jobs.finish(2, fetched(["a"]))
    XCTAssertEqual(jobs.calls.count, 4, "同じ項目をまた判定に回す")
  }

  /// 取得役の agent は固定の枠で依頼され、指定したツールが使えなかった回は失敗として何も進めない。
  func testAgentFetchUsesTheFixedFrameAndFailsWhenToolsAreUnavailable() throws {
    var definition = IntakeStoreTests.definition()
    definition.fetch = .agent(
      IntakeAgentFetch(
        cli: "claude", model: "haiku", tools: ["mcp__slack__search"], request: "自分宛の DM"))
    let intake = try create(definition)
    try runner.runNow(intake.id)

    guard case .agent(let call) = jobs.calls[0].job.work else { return XCTFail("取得役は agent") }
    XCTAssertEqual(call.tools, ["mcp__slack__search"])
    XCTAssertEqual(call.prompt, IntakePrompts.fetch(request: "自分宛の DM"))
    jobs.finish(
      0,
      BackgroundRunResult(
        commandLine: "claude -p", startedAt: now, endedAt: now,
        ending: .toolsUnavailable(["mcp__slack__search"]),
        output: .agent(reply: nil, stderr: .init())))

    XCTAssertEqual(
      store.intake(intake.id)?.runs.first?.failure,
      "the fetch ended: tools unavailable: mcp__slack__search")
    XCTAssertEqual(jobs.calls.count, 1)
  }

  /// 取得役の agent は、最終応答の行を項目として読み、新しい項目を判定へ回す。
  func testAgentFetchReadsItemsFromItsReply() throws {
    var definition = IntakeStoreTests.definition()
    definition.fetch = .agent(
      IntakeAgentFetch(
        cli: "claude", model: "haiku", tools: ["mcp__slack__search"], request: "自分宛の DM"))
    let intake = try create(definition)
    try runner.runNow(intake.id)

    jobs.finish(0, replied(line("a")))

    guard jobs.calls.count == 2 else { return XCTFail("取れた項目を判定に回す: \(jobs.calls.count)") }
    XCTAssertTrue(prompt(1).contains(#""id":"a""#))
  }

  // MARK: - 起動

  /// 起動時に、保存された受信を最後に回った時刻から数えて載せ直す。過ぎていれば 1 回だけすぐ回る。
  func testStartRegistersStoredIntakesFromTheirLastRun() throws {
    let intake = try create()
    try runner.runNow(intake.id)
    jobs.finish(0, fetched([]))

    now = start.addingTimeInterval(7200)
    let restarted = makeRunner()
    restarted.start()

    XCTAssertEqual(jobs.calls.count, 2, "過ぎていた回を 1 回だけ回す")
    XCTAssertTrue(restarted.isRunning(intake.id))
  }
}

/// 実行の係の代役。呼ばれた順に番号を振り、止める手と終わらせる口を持つ。
private final class FakeJobs {
  private(set) var calls: [(job: BackgroundJob, completion: (BackgroundRunResult) -> Void)] = []
  private(set) var stopped: [Int] = []

  func run(_ job: BackgroundJob, completion: @escaping (BackgroundRunResult) -> Void)
    -> BackgroundRunHandle
  {
    let index = calls.count
    calls.append((job, completion))
    return BackgroundRunHandle { [unowned self] in stopped.append(index) }
  }

  func finish(_ index: Int, _ result: BackgroundRunResult) {
    calls[index].completion(result)
  }
}
