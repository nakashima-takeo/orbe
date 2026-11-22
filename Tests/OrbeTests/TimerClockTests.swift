import XCTest

@testable import Orbe

/// 本番の予約の時計（稼働時間）が、予約を、期限になったら渡したキューの上で走らせ、取り消した予約は走らせないこと。
///
/// 裏の 1 回（`BackgroundProcess`）の打ち切りのテストは、手で進める時計の上で走るので、実時間で期限が来る経路を通るのはここだけ。
/// 壊れると、予約が走らない場合は、終わらない子プロセスが上限で打ち切られない。取り消しの閉包を捨てた猶予の予約が消える場合は、
/// SIGKILL と汲み出しの猶予が効かず、`run` が返らない。取り消しが効かない場合は、取り消したはずの上限の判定が、終わった実行の上で走る。
final class TimerClockTests: OrbeTestCase {
  private let clock = TimerClock.uptime
  private let queue = DispatchQueue(label: "dev.orbe.tests.timer-clock")
  private let onQueue = DispatchSpecificKey<Bool>()

  private final class Record: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (at: TimerClock.Instant, onQueue: Bool)?
    func set(at: TimerClock.Instant, onQueue: Bool) { lock.withLock { stored = (at, onQueue) } }
    var value: (at: TimerClock.Instant, onQueue: Bool)? { lock.withLock { stored } }
  }

  /// 取り消しの閉包を捨てても、予約は残って走る（裏の 1 回の猶予の予約は、取り消しの閉包を持たない）。
  func testAReservationRunsOnItsQueueAtItsDeadlineEvenWhenItsCancelIsDropped() throws {
    queue.setSpecific(key: onQueue, value: true)
    let record = Record()
    let fired = expectation(description: "fire")
    let scheduledAt = clock.now()
    _ = clock.schedule(scheduledAt + 0.05, queue) { [clock, onQueue] in
      record.set(at: clock.now(), onQueue: DispatchQueue.getSpecific(key: onQueue) == true)
      fired.fulfill()
    }
    wait(for: [fired], timeout: 5)

    let run = try XCTUnwrap(record.value)
    XCTAssertTrue(run.onQueue, "渡したキューの上で走る")
    XCTAssertGreaterThanOrEqual(run.at - scheduledAt, 0.04, "期限まで待ち、時計の時刻もその分進む")
  }

  func testACancelledReservationDoesNotRun() throws {
    let cancelled = Record()
    let cancel = clock.schedule(clock.now() + 0.01, queue) { [clock] in
      cancelled.set(at: clock.now(), onQueue: true)
    }
    cancel()
    // 同じキューの上の、期限が後の予約を目印にする。取り消しが効かなければ、取り消した予約は目印より先に走っている。
    let marker = expectation(description: "marker")
    _ = clock.schedule(clock.now() + 0.2, queue) { marker.fulfill() }
    wait(for: [marker], timeout: 5)

    XCTAssertNil(
      cancelled.value,
      "取り消した予約は走らない。目印の予約が走ることは、testAReservationRunsOnItsQueueAtItsDeadlineEvenWhenItsCancelIsDropped"
        + " が確かめる。予約が走らなくなったら、この確認は目印を待てずに落ちる")
  }
}
