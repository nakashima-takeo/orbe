import XCTest

@testable import OrbeEditorEngine

/// スクロールの規則を、合成した出来事で固定する。壊れると指に付いてこない（量が遅れる・補間される）、はじいた後に位置が
/// 跳ぶ、縦に動かしている間に横へ流れる、端で引っかかる・戻らない、最終行を最上段まで送れない、マウスのホイールの量が
/// NSScrollView と違う。
final class ScrollPhysicsTests: XCTestCase {
  /// 100 行・行高 18・本文の見えている大きさ 400×300・最も長い行 1000pt・桁 7pt。
  private func physics() -> ScrollPhysics {
    var physics = ScrollPhysics()
    physics.setLimits(
      ScrollPhysics.Limits(
        bottom: 99 * 18, lineHeight: 18, viewport: SIMD2(400, 300), longestLine: 1000, cell: 7))
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

  /// 横が主なら縦の小さな量を捨て、横だけ動く（トラックパッドで長い行を横に送れる）。
  func testHorizontalPredominantAxisMovesOnlyX() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.005, -2, dx: -20))
    p.apply(finger(1.010, -3, dx: -20))
    XCTAssertEqual(p.shown(at: 1.01), SIMD2(40, 0))
  }

  /// 主な軸の累積は 120ms で減衰する——横に大きく動かした後でも、間をおいて縦に動かせば縦が主になる。
  func testPredominantAxisSwitchesOnceTheAccumulationDecays() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.005, 0, dx: -200))
    p.apply(finger(1.605, -100, dx: -5))
    XCTAssertEqual(p.shown(at: 1.605), SIMD2(200, 100))
  }

  /// 端を越えた量は 1/20 に縮めて見せ、端の外で指を離すと x0·e^(−τ/0.08) で端へ戻る（指の速さは
  /// 持ち越さない）。続く momentum は捨てる。
  func testElasticOverscrollAndReturn() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, 200))
    XCTAssertEqual(p.shown(at: 1.01).y, -10, accuracy: 1e-9, "上端を 200 越えて 10 だけ見せる")
    p.apply(finger(1.02, 0, .ended))
    XCTAssertTrue(p.isReturning)
    XCTAssertFalse(p.apply(momentum(1.03, 40, .began)), "端の外で離した後の momentum は捨てる")
    XCTAssertEqual(p.shown(at: 1.02 + 0.08).y, -10 * exp(-1), accuracy: 1e-9)
    p.settle(at: 2.0)
    XCTAssertFalse(p.isActive, "戻りきれば止まる")
    XCTAssertEqual(p.shown(at: 2.0).y, 0)
  }

  /// momentum が端を越えたら、その時点の速さで伸びてから戻り始め（(x0 + 0.31·v·τ)·e^(−τ/0.08)）、残りの momentum は
  /// 次に指が触れるまで捨てる——はじいて端に当てても、momentum が尽きるまで端の外に留まらない。
  func testMomentumPastTheEdgeReturnsAtOnce() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, -20))
    p.apply(finger(1.02, 0, .ended))
    p.apply(momentum(1.03, 15, .began))
    p.apply(momentum(1.04, 15))
    XCTAssertTrue(p.isReturning, "端を越えた時点で戻り始める")
    XCTAssertFalse(p.apply(momentum(1.05, 15)), "残りの momentum は捨てる")
    let v = -15 / 0.01
    XCTAssertEqual(
      p.shown(at: 1.04 + 0.08).y, (-0.5 + 0.31 * v * 0.08) * exp(-1), accuracy: 1e-9,
      "越えた向きの速さで伸びてから戻る")
    p.settle(at: 2.0)
    XCTAssertEqual(p.shown(at: 2.0).y, 0)
    XCTAssertFalse(p.isActive)
    p.apply(finger(2.1, 0, .began))
    p.apply(finger(2.11, -18))
    p.apply(finger(2.12, 0, .ended))
    p.apply(momentum(2.13, -10, .began))
    XCTAssertEqual(p.shown(at: 2.13).y, 28, "指が触れた後の momentum はまた当てる")
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

  /// 端の外へ伸ばした後に指を戻す量は縮めずに当てる（縮めるのは端の外へ向かう量だけ。AppKit・WebKit と同じ）——戻す向き
  /// まで 1/20 にすると、伸ばした分の 20 倍を動かすまで本文が端に戻らない。
  func testMovingBackFromTheStretchIsUndamped() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, 200))
    XCTAssertEqual(p.shown(at: 1.01).y, -10, accuracy: 1e-9)
    p.apply(finger(1.02, -30))
    XCTAssertEqual(p.shown(at: 1.02).y, 20, accuracy: 1e-9, "端へ戻す量はそのまま当て、端を越えて本文へ入る")
    p.apply(finger(1.03, 40))
    XCTAssertEqual(p.shown(at: 1.03).y, -1, accuracy: 1e-9, "端までは 1 倍、端の外へ出た分だけ 1/20")
  }

  /// 端の外で指を離して戻っている途中に新しく指で動かせば、その時点の位置からその場で動く（戻りを待たない）。
  func testNewGestureDuringReturnMovesAtOnce() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, 200))
    p.apply(finger(1.02, 0, .ended))
    let held = p.shown(at: 1.06).y
    p.apply(finger(1.06, 0, .mayBegin))
    p.apply(finger(1.07, 0, .began))
    p.apply(finger(1.08, -30))
    XCTAssertEqual(p.shown(at: 1.08).y, held + 30, accuracy: 1e-9, "本文へ向かう指の量はそのまま入る")
    XCTAssertEqual(p.shown(at: 1.5).y, held + 30, accuracy: 1e-9, "戻りの式で上書きされない")

    var q = physics()
    q.apply(finger(1.0, 0, .began))
    q.apply(finger(1.01, 200))
    q.apply(finger(1.02, 0, .ended))
    let from = q.shown(at: 1.06).y
    q.apply(finger(1.06, 0, .began))
    q.apply(finger(1.07, 20))
    XCTAssertEqual(q.shown(at: 1.07).y, from - 1, accuracy: 1e-9, "同じ向きは今の位置から 1/20 で伸びる")
  }

  /// はじいて端に当たり戻っている途中（残りの momentum を捨てている間）でも、新しい指の出来事は捨てずにその場で当てる。
  func testNewGestureAfterMomentumBounceMovesAtOnce() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, -20))
    p.apply(finger(1.02, 0, .ended))
    p.apply(momentum(1.03, 15, .began))
    p.apply(momentum(1.04, 15))
    XCTAssertTrue(p.isReturning)
    XCTAssertFalse(p.apply(momentum(1.05, 15)))
    p.apply(momentum(1.10, 0, .ended))
    let from = p.shown(at: 1.12).y
    p.apply(finger(1.12, 0, .began))
    XCTAssertTrue(p.apply(finger(1.13, -40)))
    XCTAssertEqual(p.shown(at: 1.13).y, from + 40, accuracy: 1e-9)
    p.apply(finger(1.14, 0, .ended))
    p.apply(momentum(1.15, -10, .began))
    XCTAssertEqual(p.shown(at: 1.15).y, from + 50, accuracy: 1e-9, "新しいジェスチャの momentum は当てる")
  }

  /// 指を置いただけ（mayBegin）では捨てている momentum を解かない——置いた後に古い momentum の残りが届いても止めた位置は
  /// 動かず、動かし始めた（began）ジェスチャの momentum は当てる（WebKit と同じ）。
  func testOnlyBeganResumesMomentum() {
    var p = physics()
    p.apply(finger(1.0, 0, .began))
    p.apply(finger(1.01, 200))
    p.apply(finger(1.02, 0, .ended))
    p.apply(finger(1.06, 0, .mayBegin))
    let held = p.shown(at: 1.06).y
    XCTAssertFalse(p.apply(momentum(1.07, 40)), "置いた後に届いた古い momentum は捨てる")
    XCTAssertFalse(p.apply(momentum(1.08, 0, .ended)), "古い momentum の終わりで止めた指を離したことにしない")
    XCTAssertEqual(p.shown(at: 1.5).y, held, accuracy: 1e-9)
    p.apply(finger(1.5, 0, .began))
    p.apply(finger(1.51, -30))
    p.apply(finger(1.52, 0, .ended))
    p.apply(momentum(1.53, -10, .began))
    XCTAssertEqual(p.shown(at: 1.53).y, held + 40, accuracy: 1e-9, "動かし始めたジェスチャの momentum は当てる")
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
    limits.bottom = 9 * 18
    p.setLimits(limits)
    XCTAssertEqual(p.shown(at: 1.04).y, 9 * 18)
  }
}
