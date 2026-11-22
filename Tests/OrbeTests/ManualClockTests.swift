import OrbeTestSupport
import XCTest

@testable import Orbe

/// 手で進める時計が、期限の来た待ち手だけを、時刻を進めたときに起こすこと。
///
/// 打ち切りのテスト（git・gh・PATH の検出）は、この時計の上で「切る」「切らない」を確かめる。壊れると、切れるはずの実行が
/// 切れずにテストが上限まで待つか、切れてはいけない実行が切れたのに見逃す。
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

  /// 本番の型が時刻を読むと `readings` が増える。テストが `now` を読んでも増えない。
  func testReadingsCountOnlyTheReadsThroughTheClock() {
    _ = clock.now
    XCTAssertEqual(clock.readings, 0)
    _ = clock.waits.now()
    _ = clock.waits.now()
    XCTAssertEqual(clock.readings, 2)
  }

  private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ value: Bool) { lock.withLock { stored = value } }
    var value: Bool? { lock.withLock { stored } }
  }
}
