import Foundation
import OrbeTestSupport
import XCTest

/// テストの待ちの関数（`RunLoopWait`）が、約束どおりに待つことを固定する。
///
/// ここが崩れると、待ちを通るテストが、確かめたつもりのことを確かめなくなる。`holds(for:)` が見張らなくなると、
/// 実時間で見張る否定条件の全部が、本番が壊れても緑のまま通る。`waitUntil` が待たなくなると、条件の成立を待つ
/// テストが、条件が成り立つ前の状態を測る。
final class RunLoopWaitTests: OrbeTestCase {
  func testWaitUntilReturnsTrueAsSoonAsTheConditionHolds() {
    var checks = 0
    XCTAssertTrue(
      waitUntil(5) {
        checks += 1
        return checks == 3
      })
    XCTAssertEqual(checks, 3, "成り立った時点で見るのをやめる")
  }

  func testWaitUntilReturnsFalseAfterTheTimeout() {
    let start = Date()
    XCTAssertFalse(waitUntil(0.05) { false })
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.05, "期限まで待ってから諦める")
  }

  func testWaitUntilRunsTheMainQueueWhileWaiting() {
    var delivered = false
    DispatchQueue.main.async { delivered = true }
    XCTAssertTrue(waitUntil(5) { delivered })
  }

  func testWaitUntilDoesNotRunTheRunLoopWhenTheConditionAlreadyHolds() {
    var ran = false
    DispatchQueue.main.async { ran = true }
    XCTAssertTrue(waitUntil(5) { true })
    XCTAssertFalse(ran, "既に成り立っていれば、ランループを回さない")
    nextTurn()
  }

  func testPumpMainWaitsForTheCondition() {
    var delivered = false
    DispatchQueue.main.async { delivered = true }
    pumpMain(until: { delivered }, "main のキューの仕事が走る")
  }

  func testPumpMainRecordsTheFailureAtTheCallingLine() {
    var callingLine = 0
    let options = XCTExpectedFailure.Options()
    options.issueMatcher = {
      $0.compactDescription.contains("0.05 秒以内に成立しない: 成り立たない条件")
        && $0.sourceCodeContext.location?.lineNumber == callingLine
        && $0.sourceCodeContext.location?.fileURL.lastPathComponent == "RunLoopWaitTests.swift"
    }
    XCTExpectFailure("成り立たない条件は、呼び出した行で失敗になる", options: options)
    callingLine = #line + 1
    pumpMain(until: { false }, timeout: 0.05, "成り立たない条件")
  }

  func testPumpMainOnceRunsWorkQueuedOnTheMainQueue() {
    var ran = false
    DispatchQueue.main.async { ran = true }
    pumpMainOnce()
    XCTAssertTrue(ran)
  }

  func testNextTurnReturnsAfterWorkQueuedBeforeItRan() {
    var order: [Int] = []
    DispatchQueue.main.async { order.append(1) }
    DispatchQueue.main.async { order.append(2) }
    nextTurn()
    XCTAssertEqual(order, [1, 2])
  }

  func testHoldsReturnsFalseOnceTheConditionBreaks() {
    var checks = 0
    XCTAssertFalse(
      holds(for: 5) {
        checks += 1
        return checks < 3
      })
    XCTAssertEqual(checks, 3, "破れた時点で見張るのをやめる")
  }

  func testHoldsRunsTheMainQueueWhileWatching() {
    var broken = false
    DispatchQueue.main.async { broken = true }
    XCTAssertFalse(holds(for: 5) { !broken }, "見張るあいだ、main のキューの仕事を走らせる")
  }

  func testHoldsWatchesForTheWholeDuration() {
    var checks = 0
    let start = Date()
    XCTAssertTrue(
      holds(for: 0.05) {
        checks += 1
        return true
      })
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.05, "渡した秒数のあいだ見張る")
    XCTAssertGreaterThan(checks, 1, "見張るあいだ、条件を見直す")
  }

  func testSleepUntilSeesAChangeMadeByAnotherThread() {
    let flag = NSLock()
    var set = false
    DispatchQueue.global().async { flag.withLock { set = true } }
    XCTAssertTrue(sleepUntil(5) { flag.withLock { set } })
  }

  func testSleepUntilReturnsFalseAfterTheTimeoutWithoutRunningTheRunLoop() {
    var ran = false
    DispatchQueue.main.async { ran = true }
    let start = Date()
    XCTAssertFalse(sleepUntil(0.05) { false })
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.05, "期限まで待ってから諦める")
    XCTAssertFalse(ran, "sleepUntil は待つあいだ、ランループを回さない")
    nextTurn()
  }
}
