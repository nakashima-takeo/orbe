import XCTest

@testable import OrbeEditorEngine

/// スクロールの規則を、合成した出来事で固定する。壊れると指に付いてこない（量が遅れる・補間される）、はじいた後に位置が
/// 跳ぶ、縦に動かしている間に横へ流れる、端で引っかかる・戻らない、最終行を最上段まで送れない、マウスのホイールの量が
/// 今の面と違う。
final class ScrollPhysicsTests: XCTestCase {
  /// 100 行・行高 18・本文の見えている大きさ 400×300・最も長い行 1000pt・桁 7pt。
  private func physics(elastic: Bool = true) -> ScrollPhysics {
    var physics = ScrollPhysics(elastic: elastic)
    physics.setLimits(
      ScrollPhysics.Limits(
        lineCount: 100, lineHeight: 18, viewport: SIMD2(400, 300), longestLine: 1000, cell: 7))
    return physics
  }

  private func finger(
    _ t: Double, _ dy: Double, dx: Double = 0, _ phase: ScrollInput.Phase = .changed
  ) -> ScrollInput {
    ScrollInput(timestamp: t, delta: SIMD2(dx, dy), precise: true, phase: phase)
  }

  private func momentum(_ t: Double, _ dy: Double, _ phase: ScrollInput.Phase = .changed)
    -> ScrollInput
  {
    ScrollInput(timestamp: t, delta: SIMD2(0, dy), precise: true, momentum: phase)
  }

  /// 指の量はその場で位置に入る（補間・予測なし。見える位置は出来事の時刻にも描く時刻にも依らない）。
  func testFingerDeltaAppliesImmediately() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.005, -30))
    XCTAssertEqual(p.shown(at: 1.005).y, 30)
    XCTAssertEqual(p.shown(at: 1.2).y, 30, "時間が経っても補間・予測で動かない")
    p.apply(finger(1.011, -12.5))
    XCTAssertEqual(p.shown(at: 1.011).y, 42.5)
  }

  /// OS の momentum の出来事も同じ経路で量を当て、自前の慣性は持たない（momentum が止まれば止まる）。
  func testMomentumEventsApplyTheSameWay() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, -20))
    p.apply(finger(1.02, 0, .ended))
    XCTAssertFalse(p.isActive, "指を離しても端の内側なら自前の慣性で動かない")
    p.apply(momentum(1.03, -15, .began))
    p.apply(momentum(1.04, -10))
    XCTAssertEqual(p.shown(at: 1.04).y, 45)
    p.apply(momentum(1.05, 0, .ended))
    XCTAssertEqual(p.shown(at: 2.0).y, 45)
  }

  /// 縦は最終行が最上段に来るまで、横は最も長い行の右端から 5 桁先まで。
  func testRangeReachesLastLineAtTopAndFiveColumnsPastLongestLine() {
    let p = physics()
    XCTAssertEqual(p.maximum.y, 99 * 18)
    XCTAssertEqual(p.maximum.x, 1000 + 5 * 7 - 400)
  }

  /// 動く軸は累積の大きい方だけ——縦に動かしている間の小さな横の量は捨てる。
  func testOnlyThePredominantAxisMoves() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.005, -20, dx: -3))
    p.apply(finger(1.010, -20, dx: -6))
    XCTAssertEqual(p.shown(at: 1.01).x, 0, "縦が主なら横へ流れない")
    XCTAssertEqual(p.shown(at: 1.01).y, 40)
  }

  /// 弾性が有効なら、端を越えた量は 1/20 に縮めて見せ、離すと x0·e^(−τ/0.08) で端へ戻る。
  func testElasticOverscrollAndReturn() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, 200))
    XCTAssertEqual(p.shown(at: 1.01).y, -10, accuracy: 1e-9, "上端を 200 越えて 10 だけ見せる")
    p.apply(finger(1.02, 0, .ended))
    XCTAssertTrue(p.isReturning)
    XCTAssertEqual(p.shown(at: 1.02 + 0.08).y, -10 * exp(-1), accuracy: 1e-9)
    p.settle(at: 2.0)
    XCTAssertFalse(p.isActive, "戻りきれば止まる")
    XCTAssertEqual(p.shown(at: 2.0).y, 0)
  }

  /// 戻りの途中に指が触れたら、そこで止まる。離せば続きから戻る。
  func testTouchDuringReturnHolds() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, 200))
    p.apply(finger(1.02, 0, .ended))
    let held = p.shown(at: 1.06).y
    p.apply(finger(1.06, 0, .mayBegin))
    XCTAssertEqual(p.shown(at: 1.5).y, held, accuracy: 1e-9)
    p.apply(finger(1.5, 0, .cancelled))
    XCTAssertTrue(p.isReturning)
  }

  /// 弾性が無効なら端で止まり、越えた量は溜めない（向きを変えればすぐ動く）。
  func testWithoutElasticityStopsAtTheEdge() {
    var p = physics(elastic: false)
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, 200))
    XCTAssertEqual(p.shown(at: 1.01).y, 0)
    p.apply(finger(1.02, -18))
    XCTAssertEqual(p.shown(at: 1.02).y, 18)
    p.apply(finger(1.03, 0, .ended))
    XCTAssertFalse(p.isReturning)
  }

  /// マウスのホイールの 1 目盛り（量 1）は 10pt——今の面（NSScrollView の行送り）と同じ。
  func testWheelNotchMatchesTheCurrentSurface() {
    var p = physics()
    p.apply(ScrollInput(timestamp: 1, delta: SIMD2(0, -1), precise: false))
    XCTAssertEqual(p.shown(at: 1).y, 10)
    p.apply(ScrollInput(timestamp: 1.1, delta: SIMD2(0, -3), precise: false))
    XCTAssertEqual(p.shown(at: 1.1).y, 40)
  }

  /// main の操作はその場で位置を置き（範囲に収める）、戻りを打ち切る。本文が縮めば範囲に収める。
  func testPlaceClampsAndCancelsReturn() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, 200))
    p.apply(finger(1.02, 0, .ended))
    p.place(SIMD2(0, 5000))
    XCTAssertFalse(p.isActive)
    XCTAssertEqual(p.shown(at: 1.03).y, 99 * 18)
    var limits = p.limits
    limits.lineCount = 10
    p.setLimits(limits)
    XCTAssertEqual(p.shown(at: 1.04).y, 9 * 18)
  }
}
