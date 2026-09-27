import XCTest

@testable import OrbeEditorEngine

/// 記録係の規則（出来事→present・落ちたコマ・描画スレッド自身の遅れと GPU・合成の遅れの振り分け）。朝の場の判定と
/// 計測の関門の数字はここから出る。壊れると、落ちていないコマを落ちたと数える、描画スレッドの遅れを見逃す、要約の
/// 分位や割合がずれる。
final class FrameRecorderTests: XCTestCase {
  /// 2 進で割り切れる刻み（境目ちょうどの比較を誤差で崩さない）。
  private let period = 1.0 / 128

  private func recorder() -> FrameRecorder {
    let recorder = FrameRecorder()
    recorder.keepsTotals = true
    recorder.period = period
    return recorder
  }

  private func drawn(
    _ frame: Int, target: Double = 1, committed: Double = 0, events: [Double] = [],
    moving: Bool = true, gesture: Int = 1
  ) -> FrameRecorder.Drawn {
    FrameRecorder.Drawn(
      frame: frame, target: target, cpu: 0.0005, shaped: false, committed: committed,
      events: events,
      moving: moving, gesture: gesture, mismatch: false)
  }

  /// 予定の刻みの 1ms 前までに命令を出し終えなかったコマは描画スレッド自身の遅れ、出し終えたのに予定より半刻み以上
  /// 後に出たコマは GPU・合成の遅れ。両方なら描画スレッドの遅れだけに数える。
  func testLateFramesAreAttributedToTheRenderThreadFirst() {
    let r = recorder()
    r.drew(drawn(1, target: 1.0, committed: 0.9985))
    r.presented(frame: 1, time: 1.0)
    r.drew(drawn(2, target: 1.0, committed: 0.9995))
    r.presented(frame: 2, time: 1.0)
    r.drew(drawn(3, target: 1.0, committed: 0.99))
    r.presented(frame: 3, time: 1.006)
    r.drew(drawn(4, target: 1.0, committed: 0.9995))
    r.presented(frame: 4, time: 1.02)
    r.drew(drawn(5))
    r.presented(frame: 5, time: nil)
    XCTAssertEqual(r.totals.lateCommits, 2)
    XCTAssertEqual(r.totals.latePresents, 1)
  }

  /// 続く present の間隔が 1.5 刻みを越えたら落ちたコマ（ちょうど 1.5 刻みは落ちていない）。落ちた時間は間隔から 1 刻み
  /// を引いたもので、割合はそれを間隔の合計で割る。
  func testDropsAreIntervalsOverOneAndAHalfTicks() throws {
    let r = recorder()
    let ticks = [0, 1, 2.5, 5, 6]
    for (i, tick) in ticks.enumerated() {
      r.drew(drawn(i, events: i == 0 ? [-0.02] : []))
      r.presented(frame: i, time: tick * period)
    }
    r.flush()
    let gesture = try XCTUnwrap(r.totals.gestures.first)
    let summary = try XCTUnwrap(FrameRecorder.summary(gesture, period: period))
    XCTAssertEqual(summary.frames, 5)
    XCTAssertEqual(summary.drops, 1, "1.5 刻みは数えず 2.5 刻みだけ")
    XCTAssertEqual(summary.droppedPerSecond, 1.5 / 6 * 1000, accuracy: 1e-9)
  }

  /// 変化の無い刻みを挟んだ間隔（指を止めていた間）は数えない。次のコマにその刻みより前の指の出来事が入っていれば
  /// （main が詰まって出来事が遅れた）数える。
  func testIdleTicksCutTheSequenceUnlessEventsWereLate() throws {
    let r = recorder()
    let p = period
    r.drew(drawn(1, events: [1 - p]))
    r.presented(frame: 1, time: 1)
    r.idle(at: 1 + 0.5 * p)
    r.idle(at: 1 + 1.5 * p)
    r.drew(drawn(2, events: [1 + 20 * p]))
    r.presented(frame: 2, time: 1 + 21 * p)
    r.idle(at: 1 + 21.5 * p)
    r.drew(drawn(3, events: [1 + 21.25 * p]))
    r.presented(frame: 3, time: 1 + 25 * p)
    r.flush()
    let gesture = try XCTUnwrap(r.totals.gestures.first)
    XCTAssertEqual(gesture.presents.map(\.counts), [true, false, true])
    let summary = try XCTUnwrap(FrameRecorder.summary(gesture, period: period))
    XCTAssertEqual(summary.drops, 1, "止めていた間は落ちていない。遅れた出来事の間は落ちた")
    XCTAssertEqual(summary.droppedPerSecond, 3.0 / 4 * 1000, accuracy: 1e-9)
  }

  /// ジェスチャーの間は、位置の変わらないコマ（役割が届いて描き直しただけなど）も描いたコマとして並びに入る——刻みごとに
  /// 描いていれば、動いたコマの間が空いても落ちていない。
  func testFramesThatDoNotMoveStayInTheGestureSequence() throws {
    let r = recorder()
    for (i, moving) in [true, false, true, false, true].enumerated() {
      r.drew(drawn(i, events: moving ? [Double(i) * period - 0.01] : [], moving: moving))
      r.presented(frame: i, time: Double(i) * period)
    }
    r.flush()
    let gesture = try XCTUnwrap(r.totals.gestures.first)
    let summary = try XCTUnwrap(FrameRecorder.summary(gesture, period: period))
    XCTAssertEqual(summary.frames, 5)
    XCTAssertEqual(summary.drops, 0)
  }

  /// 出来事→present の分位（中央値・p95・最大、ms）。
  func testLatencyQuantiles() throws {
    let r = recorder()
    let latencies = (1...20).map { Double($0) / 1000 }
    for (i, latency) in latencies.enumerated() {
      r.drew(drawn(i, events: [1 - latency]))
      r.presented(frame: i, time: 1)
    }
    r.flush()
    let gesture = try XCTUnwrap(r.totals.gestures.first)
    let summary = try XCTUnwrap(FrameRecorder.summary(gesture, period: period))
    XCTAssertEqual(summary.latencyMedian, 11, accuracy: 1e-6)
    XCTAssertEqual(summary.latencyP95, 20, accuracy: 1e-6)
    XCTAssertEqual(summary.latencyMax, 20, accuracy: 1e-6)
  }

  /// 出来事も続く present も無いジェスチャーは要約を出さない。
  func testNoSummaryWithoutEventsOrIntervals() {
    let gesture = FrameRecorder.Gesture(
      id: 1, presents: [FrameRecorder.Present(time: 1, counts: true)])
    XCTAssertNil(FrameRecorder.summary(gesture, period: period))
  }

  /// ジェスチャーの番号が変われば、前のジェスチャーを締める。位置が動かず出来事も無いコマではジェスチャーを始めない。
  func testANewGestureClosesThePreviousOne() {
    let r = recorder()
    r.drew(drawn(1, moving: false))
    r.presented(frame: 1, time: 1)
    r.flush()
    XCTAssertTrue(r.totals.gestures.isEmpty, "役割が届いて描き直しただけではジェスチャーにしない")
    r.drew(drawn(2, events: [0.99], gesture: 1))
    r.presented(frame: 2, time: 1.0)
    r.drew(drawn(3, events: [1.99], gesture: 2))
    XCTAssertEqual(r.totals.gestures.map(\.id), [1])
    XCTAssertEqual(r.gesture, 2)
  }
}
