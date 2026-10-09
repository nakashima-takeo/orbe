import XCTest

@testable import Orbe

/// 予定の番人——新しい予定はすぐには走らない、時刻が来たら 1 回走る、過ぎていた回は何回分でも 1 回だけ、重ねて走らせない、
/// 再登録・外す・期限は走っている回を止めてその結果を返さない、「期限が来た」は 1 度だけ、時計の変更で数え直す。
///
/// 壊れると何が起きるか。再起動の直後に claude が何本も立ち上がる。走っている回の結果が外した予定の記録として保存される。
/// 期限の切れた待ちが走り続ける。スリープ明けにタイマーの発火を待って、過ぎた予定がいつまでも走らない。
final class BackgroundSchedulerTests: OrbeTestCase {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private var now = Date(timeIntervalSince1970: 1_800_000_000)
  private var armed: (date: Date, fire: () -> Void)?
  private var runner: FakeRunner!
  private var scheduler: BackgroundScheduler!
  private var events: [String: [BackgroundScheduler.Event]] = [:]

  override func setUp() {
    runner = FakeRunner()
    scheduler = BackgroundScheduler(run: runner.run)
    scheduler.now = { [unowned self] in now }
    scheduler.calendar = { Calendar(identifier: .gregorian) }
    scheduler.arm = { [unowned self] date, fire in
      armed = (date, fire)
      return { [unowned self] in armed = nil }
    }
  }

  override func tearDown() {
    scheduler = nil
  }

  private func schedule(every interval: TimeInterval = 60, deadline: Date? = nil)
    -> BackgroundSchedule
  {
    BackgroundSchedule(
      job: .command(.init(script: "true")), timing: .every(interval), deadline: deadline)
  }

  private func register(
    _ schedule: BackgroundSchedule? = nil, id: String = "a", anchor: Date? = nil
  ) throws {
    let record: (BackgroundScheduler.Event) -> Void = { [unowned self] event in
      events[id, default: []].append(event)
    }
    try scheduler.register(
      id: id, schedule: schedule ?? self.schedule(), anchor: anchor ?? now, onEvent: record)
  }

  /// 時計を進め、張られた予約が来ていれば発火させる。
  private func advance(to date: Date) {
    now = date
    if let armed, armed.date <= date { armed.fire() }
  }

  private func result(startedAt: Date) -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "true", startedAt: startedAt, endedAt: startedAt, ending: .exited(0),
      output: .none)
  }

  // MARK: - 数える

  func testNewScheduleWaitsOneInterval() throws {
    try register()

    XCTAssertEqual(runner.calls.count, 0, "作った直後には走らない")
    XCTAssertEqual(armed?.date, start.addingTimeInterval(60))
  }

  func testRunsWhenTheTimeComesAndCountsFromThatRun() throws {
    try register()

    advance(to: start.addingTimeInterval(60))
    XCTAssertEqual(runner.calls.count, 1)
    runner.finish(0, with: result(startedAt: now))

    XCTAssertEqual(events["a"], [.ran(result(startedAt: now))])
    XCTAssertEqual(armed?.date, now.addingTimeInterval(60), "次は走った回から 1 間隔後")
  }

  /// 再起動やスリープで何回分過ぎていても、走るのは 1 回だけで、その後は規則どおりに戻る。
  func testOverdueRunsOnceThenResumesTheRule() throws {
    try register(anchor: start.addingTimeInterval(-3600))

    XCTAssertEqual(runner.calls.count, 1)
    runner.finish(0, with: result(startedAt: now))

    XCTAssertEqual(runner.calls.count, 1, "過ぎた 60 回分を積まない")
    XCTAssertEqual(armed?.date, now.addingTimeInterval(60))
  }

  /// 走っている間に次の回が来ても重ねない。終わった時点で数え直す。
  func testDoesNotOverlapWhileRunning() throws {
    try register()
    advance(to: start.addingTimeInterval(60))

    now = start.addingTimeInterval(600)
    scheduler.recount()
    scheduler.runNow(id: "a")

    XCTAssertEqual(runner.calls.count, 1)
  }

  /// タイマーの発火に頼らない。時計が変わったら数え直し、過ぎていた予定を走らせる。
  func testClockChangeRecounts() throws {
    try register()
    now = start.addingTimeInterval(120)

    NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)

    XCTAssertEqual(runner.calls.count, 1)
  }

  /// 時計が大きく戻って数え始めが未来になったら、数え始めを今にそろえて数え直す（戻った分だけ予定が止まらない）。
  func testClockMovedBackBeforeAnchorRecountsFromNow() throws {
    try register()
    now = start.addingTimeInterval(-86400)

    NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)

    XCTAssertEqual(armed?.date, now.addingTimeInterval(60))
  }

  /// タイムゾーンが変わったら、毎日の時刻を新しいタイムゾーンで数え直す（予約の発火を待たない）。
  func testTimeZoneChangeRecountsDailyTimesInTheNewZone() throws {
    var zone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
    scheduler.calendar = {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = zone
      return calendar
    }
    // start は 08:00 UTC（17:00 JST）。
    try register(
      BackgroundSchedule(
        job: .command(.init(script: "true")),
        timing: .daily([BackgroundTimeOfDay(hour: 9, minute: 0)]), deadline: nil))
    XCTAssertEqual(armed?.date, start.addingTimeInterval(16 * 3600), "前提: 翌日 9:00 JST")

    zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)

    XCTAssertEqual(armed?.date, start.addingTimeInterval(1 * 3600), "当日 9:00 UTC")
  }

  /// 予定が複数あれば、最も早い回に合わせて待つ。
  func testWaitsForTheEarliestOfSeveralSchedules() throws {
    try register(schedule(every: 60), id: "fast")
    try register(schedule(every: 300), id: "slow")

    XCTAssertEqual(armed?.date, start.addingTimeInterval(60))
    advance(to: start.addingTimeInterval(60))

    XCTAssertEqual(runner.calls.count, 1, "早い予定の時刻に、早い予定だけが走る")
  }

  func testRunNowStartsImmediately() throws {
    try register()

    scheduler.runNow(id: "a")

    XCTAssertEqual(runner.calls.count, 1)
  }

  func testInvalidScheduleIsRejected() {
    XCTAssertThrowsError(try register(schedule(every: 10))) {
      XCTAssertEqual($0 as? BackgroundJobError, .intervalTooShort)
    }
  }

  // MARK: - 外す・再登録

  func testReRegisterStopsTheRunningRunAndDropsItsResult() throws {
    try register()
    scheduler.runNow(id: "a")

    try register(anchor: start.addingTimeInterval(-30))
    runner.finish(0, with: result(startedAt: now))

    XCTAssertEqual(runner.stopped, [0])
    XCTAssertNil(events["a"], "外した回の結果は返さない")
    XCTAssertEqual(armed?.date, start.addingTimeInterval(30), "新しい数え始めで数え直す")
  }

  func testRemoveStopsTheRunningRunAndForgetsTheSchedule() throws {
    try register()
    scheduler.runNow(id: "a")

    scheduler.remove(id: "a")
    runner.finish(0, with: result(startedAt: now))
    advance(to: start.addingTimeInterval(3600))

    XCTAssertEqual(runner.stopped, [0])
    XCTAssertEqual(runner.calls.count, 1)
    XCTAssertNil(events["a"])
    XCTAssertNil(armed)
  }

  // MARK: - 期限

  func testDeadlineExpiresOnceAndStopsCounting() throws {
    try register(schedule(deadline: start.addingTimeInterval(30)))
    XCTAssertEqual(armed?.date, start.addingTimeInterval(30))

    advance(to: start.addingTimeInterval(30))
    scheduler.recount()

    XCTAssertEqual(events["a"], [.expired])
    XCTAssertEqual(runner.calls.count, 0)
    XCTAssertNil(armed)
  }

  /// 期限が来たら、走っている回を止め、その結果は返さない。
  func testDeadlineStopsTheRunningRun() throws {
    try register(schedule(deadline: start.addingTimeInterval(90)))
    advance(to: start.addingTimeInterval(60))
    XCTAssertEqual(armed?.date, start.addingTimeInterval(90), "走っている間も期限を見張る")

    advance(to: start.addingTimeInterval(90))
    runner.finish(0, with: result(startedAt: start.addingTimeInterval(60)))

    XCTAssertEqual(runner.stopped, [0])
    XCTAssertEqual(events["a"], [.expired])
  }

  // MARK: - 使い手の中からの呼び直し

  /// 出来事を受けた使い手が、その場で登録し直しても数えが崩れない。
  func testReRegisterFromEventHandlerIsCounted() throws {
    try scheduler.register(
      id: "a", schedule: schedule(deadline: start.addingTimeInterval(30)), anchor: now
    ) { [unowned self] _ in
      try? register(id: "b")
    }

    advance(to: start.addingTimeInterval(30))

    XCTAssertEqual(armed?.date, start.addingTimeInterval(90), "登録し直した予定の時刻で張り直す")
  }
}

/// 実行の係の代役。呼ばれた順に番号を振り、止める手と終わらせる口を持つ。
private final class FakeRunner {
  private(set) var calls: [(job: BackgroundJob, completion: (BackgroundRunResult) -> Void)] = []
  private(set) var stopped: [Int] = []

  func run(_ job: BackgroundJob, completion: @escaping (BackgroundRunResult) -> Void)
    -> BackgroundRunHandle
  {
    let index = calls.count
    calls.append((job, completion))
    return BackgroundRunHandle { [unowned self] in stopped.append(index) }
  }

  func finish(_ index: Int, with result: BackgroundRunResult) {
    calls[index].completion(result)
  }
}
