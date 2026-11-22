import OrbeTestSupport
import XCTest

@testable import Orbe

/// 裏の 1 回の時間の上限——経過時間と無出力の上限で切り、出力が無出力の上限を延ばし、無出力の上限を外した実行は経過時間の上限
/// だけで止まる。どれも、手で進める時計を渡した実行の上で確かめる。
///
/// 壊れると何が起きるか。終わらない子プロセスを待つ予定が永久に止まる。出力を流している正常な実行が、無出力の上限で切られる。
/// 無出力の上限を外した実行が、出力の無い間に切られたり、経過時間を過ぎても止まらなかったりする。
extension BackgroundProcessTests {
  /// 出力が届くと、実行の開始からの経過が無出力の上限を超えても、無出力の上限は延びる。子は、合図のたびに 1 行出力し、
  /// 終わりの合図を受けたら終了コード 0 で終わる。
  private func assertOutputPostponesTheIdleLimit(
    stderr: Bool, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let tick = scratch("tick")
    let release = scratch("release")
    let echo = stderr ? "echo tick >&2" : "echo tick"
    let script = """
      while [ ! -e '\(release)' ]; do
        if [ -e '\(tick)' ]; then rm '\(tick)'; \(echo); fi
        sleep 0.05
      done
      """
    let pending = start(timed(spec(script, idle: Self.idleLimit)))
    let first = try awaitLimit(file: file, line: line)
    // 上限の長さは、張られた予約の期限から読む（張られてから時刻は進めていない）。
    let limit = first.deadline - clock.timerNow

    XCTAssertEqual(clock.advance(by: limit * 3 / 4), 0, "前提: 上限の手前では走らない", file: file, line: line)
    let outputAt = clock.timerNow
    let read = clock.readings
    touch(tick)
    pumpMain(until: { self.clock.readings > read }, "子の出力が届く", file: file, line: line)
    XCTAssertEqual(clock.advance(by: limit * 3 / 4), 1, "前提: 最初の期限は過ぎている", file: file, line: line)
    XCTAssertTrue(
      clock.scheduled.contains { abs(($0.deadline - outputAt) - limit) < 0.001 },
      "最後の出力から数え直した期限で、上限の予約を張り直す", file: file, line: line)

    touch(release)
    XCTAssertEqual(
      try outcome(of: pending, file: file, line: line).ending, .exited(0),
      "出力の後に無出力の上限が過ぎていないなら、最初からの経過が無出力の上限を超えても切ってはいけない。"
        + "進めた呼び出しの中で切っていれば、子がその後に 0 で終わっても、終わり方は無出力の上限による打ち切りになる",
      file: file, line: line)
  }

  /// 出力が流れていても、経過時間の上限は延びない。
  func testElapsedLimitStopsEvenWhileOutputFlows() throws {
    let pending = start(
      timed(spec("while :; do echo tick; sleep 0.1; done", elapsed: 30, idle: 60)))
    let limit = try awaitLimit()

    XCTAssertEqual(
      clock.advance(by: (limit.deadline - clock.timerNow) / 2), 0, "前提: 上限の手前では走らない")
    let read = clock.readings
    pumpMain(until: { self.clock.readings > read }, "前提: 時刻を進めた後にも、子の出力が届く")
    clock.advance(to: limit.deadline)

    XCTAssertEqual(try outcome(of: pending).ending, .limited(.elapsed))
  }

  func testIdleLimitStopsSilentChild() throws {
    let pending = start(timed(spec("sleep 30", idle: Self.idleLimit)))
    let limit = try awaitLimit()

    XCTAssertGreaterThanOrEqual(
      clock.advance(to: limit.deadline), 1,
      "時刻を無出力の上限の期限まで進めると、上限の予約は、進めた呼び出しの中で走る。進めた呼び出しが戻った時点で"
        + "まだ走り終えていないと、次の 2 つの確認は、子を切っていないことを確かめられなくなる。1 つは "
        + "testWithoutIdleLimitSilentChildRunsUntilTheElapsedLimit にある「黙っていても、経過の上限の手前では、"
        + "上限の予約を走らせない」という確認、もう 1 つは testOutputKeepsIdleLimitAway・testStderrKeepsIdleLimitAway "
        + "にある「最後の出力から数え直した期限で、上限の予約を張り直す」という確認")
    XCTAssertEqual(try outcome(of: pending).ending, .limited(.idle))
  }

  /// 無出力の上限を外した実行は、黙っていても切らず、経過時間の上限で止まる。
  func testWithoutIdleLimitSilentChildRunsUntilTheElapsedLimit() throws {
    let pending = start(timed(spec("sleep 30", elapsed: 30, idle: nil)))
    let limit = try awaitLimit()
    let silent = limit.deadline + -1
    XCTAssertGreaterThan(
      silent - clock.timerNow, Self.idleLimit,
      "前提: 経過の上限の手前まで黙る時間は、testIdleLimitStopsSilentChild で切れる無出力の上限より長い")

    clock.advance(to: silent)
    XCTAssertTrue(clock.isScheduled(limit), "黙っていても、経過の上限の手前では、上限の予約を走らせない")
    clock.advance(to: limit.deadline)

    XCTAssertEqual(try outcome(of: pending).ending, .limited(.elapsed))
  }

  /// 出力が流れている間は、合計が無出力の上限を超えても切らない。
  func testOutputKeepsIdleLimitAway() throws {
    try assertOutputPostponesTheIdleLimit(stderr: false)
  }

  /// 標準エラーへの出力も、生きている印として数える。
  func testStderrKeepsIdleLimitAway() throws {
    try assertOutputPostponesTheIdleLimit(stderr: true)
  }
}
