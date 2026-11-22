import OrbeTestSupport
import XCTest

@testable import Orbe

/// 手で進める時計が、期限の来た待ち手だけを起こし、期限の来た予約だけを走らせること。どちらも、時刻を進めたときにだけ起きる。
///
/// 打ち切りのテスト（git・gh・PATH の検出・裏の 1 回）は、この時計の上で「切る」「切らない」を確かめる。この時計が壊れると、切れるはずの
/// 実行が切れずにテストが上限まで待つか、切れてはいけない実行が切れたのに見逃す。
final class ManualClockTests: OrbeTestCase {
  private let clock = ManualClock()
  private let semaphore = DispatchSemaphore(value: 0)

  /// 裏のスレッドで、止める時計の上で `semaphore` を待つ。返る閉包は、起きたときの戻り値（まだなら nil）。
  private func sleepInBackground(until deadline: WaitClock.Instant?) -> () -> Bool? {
    let woke = Box()
    DispatchQueue.global().async { [clock, semaphore] in
      woke.set(clock.waits.sleep(on: semaphore, until: deadline))
    }
    return { woke.value }
  }

  func testADeadlineWakesTheSleeperOnlyWhenTheClockReachesIt() throws {
    let deadline = clock.now + 10
    let woke = sleepInBackground(until: deadline)
    let sleeper = try XCTUnwrap(clock.awaitSleeper(until: deadline), "期限で眠る")

    XCTAssertEqual(clock.advance(by: 9), 0, "期限の手前では起こさない")
    XCTAssertTrue(clock.isAsleep(sleeper))
    XCTAssertEqual(clock.advance(to: deadline), 1, "期限で起こす")
    XCTAssertFalse(clock.isAsleep(sleeper), "期限で起こした待ち手は、進めた呼び出しが戻った時点で眠っていない")
    pumpMain(until: { woke() != nil })
    XCTAssertEqual(woke(), false, "期限で起きたことを返す")
    XCTAssertEqual(clock.sleeping, [], "起きた待ち手は眠りの一覧から消える")
  }

  func testASleeperWithoutADeadlineWakesOnlyOnTheSignal() throws {
    let woke = sleepInBackground(until: nil)
    let sleeper = try XCTUnwrap(clock.awaitSleeper(until: nil), "期限なしで眠る")

    XCTAssertEqual(clock.advance(by: 86_400), 0, "時刻を進めても起こさない")
    XCTAssertTrue(clock.isAsleep(sleeper))
    semaphore.signal()
    pumpMain(until: { woke() != nil })
    XCTAssertEqual(woke(), true, "合図で起きたことを返す")
    XCTAssertFalse(clock.isAsleep(sleeper), "合図で起きた待ち手は眠っていない")
  }

  /// 待ち手が眠る前に時刻が期限を過ぎていれば、眠らずに期限切れを返す（進めた時刻を取りこぼさない）。
  func testAPassedDeadlineReturnsWithoutSleeping() {
    let deadline = clock.now + 1
    clock.advance(by: 5)
    XCTAssertFalse(clock.waits.sleep(on: semaphore, until: deadline))
    XCTAssertEqual(clock.sleeping, [])
  }

  func testAConditionSleeperWakesAtItsDeadline() {
    let condition = NSCondition()
    let deadline = clock.now + 2
    let woke = Box()
    DispatchQueue.global().async { [clock] in
      condition.lock()
      defer { condition.unlock() }
      woke.set(clock.waits.sleep(on: condition, until: deadline))
    }
    XCTAssertNotNil(clock.awaitSleeper(until: deadline))
    XCTAssertEqual(clock.advance(to: deadline), 1)
    pumpMain(until: { woke.value != nil })
    XCTAssertEqual(woke.value, false)
  }

  /// 本番の型が時刻を読むと `readings` が増える。テストが `now`・`timerNow` を読んでも増えない。
  func testReadingsCountOnlyTheReadsThroughTheClock() {
    _ = clock.now
    _ = clock.timerNow
    XCTAssertEqual(clock.readings, 0)
    _ = clock.waits.now()
    _ = clock.waits.now()
    _ = clock.timers.now()
    XCTAssertEqual(clock.readings, 3)
  }

  // MARK: - 予約

  private let queue = DispatchQueue(label: "dev.orbe.tests.manual-clock")
  private let onQueue = DispatchSpecificKey<Bool>()

  /// 走った予約の 1 件。走ったときに読んだ予約の時計の時刻と、`queue` の上で走ったかを持つ。
  private struct Run {
    let name: String
    let at: TimerClock.Instant
    let onQueue: Bool
  }

  /// 予約が走った順の記録。
  private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Run] = []
    func append(_ name: String, at: TimerClock.Instant, onQueue: Bool) {
      lock.withLock { stored.append(Run(name: name, at: at, onQueue: onQueue)) }
    }
    var names: [String] { lock.withLock { stored.map(\.name) } }
    var all: [Run] { lock.withLock { stored } }
  }

  private func schedule(
    _ name: String, at deadline: TimerClock.Instant, into fired: Fired
  ) -> @Sendable () -> Void {
    let timers = clock.timers
    return timers.schedule(deadline, queue) { [onQueue] in
      fired.append(
        name, at: timers.now(), onQueue: DispatchQueue.getSpecific(key: onQueue) == true)
    }
  }

  func testAReservationRunsOnItsQueueOnlyWhenTheClockReachesItsDeadline() throws {
    queue.setSpecific(key: onQueue, value: true)
    let fired = Fired()
    let deadline = clock.timerNow + 10
    _ = schedule("a", at: deadline, into: fired)
    let reservation = try XCTUnwrap(clock.scheduled.first)
    XCTAssertEqual(reservation.deadline, deadline)

    XCTAssertEqual(clock.advance(by: 9), 0, "期限の手前では走らせない")
    XCTAssertTrue(clock.isScheduled(reservation))
    XCTAssertEqual(
      clock.advance(by: 5), 1,
      "期限を過ぎた予約は、時刻を進めた呼び出しの中で走る。進めた呼び出しが戻った時点でまだ走り終えていないと、"
        + "testACancelledReservationDoesNotRun の「取り消した予約は、期限を過ぎても走らない」という確認は、"
        + "予約が走る前に行われるので、取り消しが効かなくても通る")
    let run = try XCTUnwrap(fired.all.first)
    XCTAssertTrue(run.onQueue, "渡したキューの上で走る")
    XCTAssertGreaterThanOrEqual(
      run.at, deadline, "走る処理が読む時刻は、期限を過ぎている（本番は、走った処理の中で、期限を過ぎたかを測り直す）")
    XCTAssertLessThan(run.at, deadline + 1, "走る処理が読む時刻は、進め先の時刻ではなく、その予約の期限")
    XCTAssertFalse(clock.isScheduled(reservation), "走った予約は一覧から消える")
    XCTAssertEqual(clock.timerNow - deadline, 4, accuracy: 0.001, "走らせた後に、進め先の時刻まで進む")
  }

  func testACancelledReservationDoesNotRun() {
    let fired = Fired()
    let cancel = schedule("a", at: clock.timerNow + 1, into: fired)
    cancel()

    XCTAssertEqual(clock.advance(by: 5), 0)
    XCTAssertEqual(fired.names, [], "取り消した予約は、期限を過ぎても走らない")
    XCTAssertEqual(clock.scheduled, [])
  }

  /// 期限の来た予約は、期限の順に走る。走った処理が張った予約も、期限が来ていれば、同じ呼び出しの中で走る。
  func testDueReservationsRunInDeadlineOrderIncludingOnesTheyArm() {
    let fired = Fired()
    let start = clock.timerNow
    let timers = clock.timers
    _ = schedule("late", at: start + 3, into: fired)
    _ = timers.schedule(start + 1, queue) {
      fired.append("early", at: timers.now(), onQueue: true)
      _ = timers.schedule(timers.now() + 1, self.queue) {
        fired.append("armed", at: timers.now(), onQueue: true)
      }
    }

    XCTAssertEqual(clock.advance(by: 5), 3)
    XCTAssertEqual(fired.names, ["early", "armed", "late"])
    for (run, expected) in zip(fired.all, [1.0, 2, 3]) {
      XCTAssertEqual(run.at - start, expected, accuracy: 0.001, "\(run.name) は、その期限の時刻で走る")
    }
  }

  /// 予約の時計の時刻と止める時計の時刻は、同じだけ進む。
  func testBothClocksAdvanceTogether() {
    let wait = clock.now
    let timer = clock.timerNow
    clock.advance(to: timer + 7)
    XCTAssertEqual(clock.now - wait, 7, accuracy: 0.001)
    clock.advance(to: clock.now + 3)
    XCTAssertEqual(clock.timerNow - timer, 10, accuracy: 0.001)
  }

  private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ value: Bool) { lock.withLock { stored = value } }
    var value: Bool? { lock.withLock { stored } }
  }
}
