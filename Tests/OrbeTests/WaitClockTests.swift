import XCTest

@testable import Orbe

/// 本番の止める時計（壁時計）が、期限で実時間に起き、合図でも起きること。
///
/// git・gh・PATH の検出の打ち切りのテストは手で進める時計の上で走るので、実時間で期限が来る経路を通るのはここだけ。壊れると、
/// 返らない git や gh が打ち切られずに固まる（待ちが期限で起きない場合と、待ちは起きても時計の時刻が進んでいないため、
/// 待ち手が期限の過ぎたことを知らない場合）か、合図が届いても上限まで返らない（合図で起きない）。
final class WaitClockTests: OrbeTestCase {
  private let clock = WaitClock.wall

  func testSemaphoreSleepWakesAtTheDeadlineAndOnTheSignal() {
    let semaphore = DispatchSemaphore(value: 0)
    let started = clock.now()
    XCTAssertFalse(clock.sleep(on: semaphore, until: started + 0.05), "期限で起きる")
    XCTAssertGreaterThanOrEqual(clock.now() - started, 0.04, "期限まで待ち、時計の時刻もその分進む")

    DispatchQueue.global().async { semaphore.signal() }
    XCTAssertTrue(clock.sleep(on: semaphore, until: clock.now() + 60), "合図で起きる")

    DispatchQueue.global().async { semaphore.signal() }
    XCTAssertTrue(clock.sleep(on: semaphore, until: nil), "期限なしでも、合図で起きる")
  }

  func testConditionSleepWakesAtTheDeadlineAndOnTheBroadcast() {
    let condition = NSCondition()
    condition.lock()
    defer { condition.unlock() }
    let started = clock.now()
    XCTAssertFalse(clock.sleep(on: condition, until: started + 0.05), "期限で起きる")
    XCTAssertGreaterThanOrEqual(clock.now() - started, 0.04, "期限まで待ち、時計の時刻もその分進む")

    // 鍵はこのスレッドが待ちに入るまで放さないので、合図は待ちの後に届く。
    let flag = Flag()
    DispatchQueue.global().async {
      condition.lock()
      flag.raise()
      condition.broadcast()
      condition.unlock()
    }
    while !flag.isRaised {
      XCTAssertTrue(clock.sleep(on: condition, until: clock.now() + 60), "合図で起きる")
    }
  }

  private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
  }
}
