import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 刻みの止め方と再開（電池を守る規則）と、刻みで描いたコマから main への知らせ、描画スレッドの時間制約。窓を出さない
/// 刻み（`HeadlessDriver`）で本物の描画スレッドを回す。壊れると、新しい面が 1 コマ目で固まる、止まっている間や隠れた
/// タブで描き続けて CPU と電池を使う、右にまだ本文が続くのに俯瞰の右の影が出ない、混んだ機械で描画スレッドが遅れて
/// 起きたり遅いコアに載ったりしてコマが落ちる。
@MainActor
final class RenderLoopTests: EngineTestCase {
  private var driver: HeadlessDriver!

  override func setUpWithError() throws {
    try super.setUpWithError()
    driver = HeadlessDriver()
    driver.start()
  }

  override func tearDownWithError() throws {
    driver?.stop()
    try super.tearDownWithError()
  }

  /// 同じ幅の行（描くたびに横の範囲が伸びて描き直すことが無い）。
  private let text = (0..<200).map { String(format: "line %03d", $0) }.joined(separator: "\n")

  /// 見えている面は描いてから止まり、止まっている間は刻みが来ない。材料が変われば 1 コマだけ描いて、また止まる。
  func testDrawsOnceAfterAChangeAndStopsAgain() throws {
    let opened = try open(text)
    let surface = opened.surface
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    let target = driver.bind(surface.id)
    waitUntilPaused(surface)
    let first = target.acquired
    XCTAssertGreaterThan(first, 0, "結んだら描く")
    let ticks = driver.ticks(surface.id)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(driver.ticks(surface.id), ticks, "止まっている間は刻みが来ない")

    surface.scroll(
      ScrollInput(timestamp: CACurrentMediaTime(), delta: SIMD2(0, -1), precise: false))
    waitUntilPaused(surface)
    XCTAssertEqual(target.acquired, first + 1, "変わったコマだけ描く")
  }

  /// 見えていない面（窓に無い・隠れたタブ）は描かずに刻みを止める。
  func testInvisibleSurfaceDoesNotDraw() throws {
    let opened = try open(text)
    let surface = opened.surface
    let target = driver.bind(surface.id)
    waitUntilPaused(surface)
    XCTAssertEqual(target.acquired, 0)
    surface.setIndentation(Indentation(unit: 2, usesTabs: false))
    waitUntilPaused(surface)
    XCTAssertEqual(target.acquired, 0, "起こされても見えていなければ描かない")
  }

  /// 止まっていた面を起こしたら、次に画面に出る刻みまでに描き終えられる限り、刻みを待たずにその場で 1 コマ描く。残りが
  /// 足りなければ刻みに任せる。
  func testWakingAStoppedSurfaceDrawsAtOnceWhenThereIsTime() throws {
    let opened = try open(text)
    let surface = opened.surface
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    for (lead, drawsAtOnce) in [(0.005, true), (0.001, false)] {
      let id = surface.id
      let clock = ManualClock(lead: lead)
      let target = OffscreenTarget(
        device: try XCTUnwrap(RenderThread.device), driver: driver, holds: false)
      RenderThread.shared.perform { $0.bind(id, target: target, clock: clock) }
      // 手で刻んで、描いてから止まるまで進める（描いたコマが画面に出るのも待つ）。
      var stopped = false
      for _ in 0..<50 where !stopped {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        stopped = RenderThread.shared.performAndWait { renderer in
          renderer.tick(id, target: CACurrentMediaTime() + lead)
          return clock.isPaused && target.acquired == target.settled
        }
      }
      XCTAssertTrue(stopped, "前提: 描いてから止まっている")
      let before = target.acquired
      surface.setIndentation(Indentation(unit: before % 2 == 0 ? 2 : 4, usesTabs: false))
      surface.flush()
      let (after, paused) = RenderThread.shared.performAndWait { _ in
        (target.acquired, clock.isPaused)
      }
      XCTAssertEqual(after, drawsAtOnce ? before + 1 : before, "残り \(lead)s")
      XCTAssertFalse(paused, "刻みは再開する")
    }
  }

  /// 焦点のある面は、止まっている間、次に点滅が切り替わってから最初の刻みの半刻み前にだけ起きるタイマーを置く（起きたら
  /// その刻みへ描いてすぐ止まる——点滅 1 回で 1 回だけ起きる）。焦点が無い・見えていない・点滅しない（アクセシビリティの
  /// 「点滅しない挿入ポイント」）面は置かない。
  func testOnlyFocusedVisibleBlinkingSurfacesWakeForTheBlink() throws {
    let opened = try open(text)
    let surface = opened.surface
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    surface.updateFocus(true)
    driver.bind(surface.id)
    waitUntilPaused(surface)
    let fire = try XCTUnwrap(blinkWake(surface), "焦点のある面はタイマーを置く")
    let period = HeadlessDriver.period
    let target = fire + period / 2
    XCTAssertEqual(
      target / period, (target / period).rounded(), accuracy: 0.05, "刻みの半刻み前に起きる")
    let caret = surface.drawn.caret
    XCTAssertNotEqual(
      caret.caretVisible(at: target), caret.caretVisible(at: target - period),
      "起きて描く刻みは、点滅が切り替わってから最初の刻み")

    surface.setCaretBlinks(false)
    waitUntilPaused(surface)
    XCTAssertNil(blinkWake(surface), "点滅しなければ置かない")
    XCTAssertTrue(surface.drawn.caret.caretVisible(at: target), "描き続ける")
    surface.setCaretBlinks(true)
    waitUntilPaused(surface)
    XCTAssertNotNil(blinkWake(surface))

    surface.updateFocus(false)
    waitUntilPaused(surface)
    XCTAssertNil(blinkWake(surface), "焦点が無ければ置かない")
    surface.updateFocus(true)
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: false)
    waitUntilPaused(surface)
    XCTAssertNil(blinkWake(surface), "見えていなければ置かない")
  }

  /// 点滅のタイマーが起きる時刻（`CACurrentMediaTime` の時計。置いていなければ nil）。
  private func blinkWake(_ surface: MetalTextSurface) -> Double? {
    let id = surface.id
    return RenderThread.shared.performAndWait { renderer in
      renderer.slot(id)?.blinkTimer.map {
        CFRunLoopTimerGetNextFireDate($0) - CFAbsoluteTimeGetCurrent() + CACurrentMediaTime()
      }
    }
  }

  /// 刻みで描いたコマが組んだ行で横の範囲を伸ばせば、main の操作を待たずに見えている範囲を知らせ直す（本文が右に
  /// まだ続く）。
  func testAFrameThatWidensTheRangeTellsTheViewport() throws {
    let opened = try open(String(repeating: "x", count: 300) + "\n")
    let surface = opened.surface
    XCTAssertFalse(surface.viewport.clipsRight, "前提: 行を組むまでは横の範囲に入らない")
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    driver.bind(surface.id)
    let deadline = Date().addingTimeInterval(5)
    while !surface.viewport.clipsRight, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(surface.viewport.clipsRight)
  }

  /// 描いた面の刻みに合わせて、描画スレッドは時間制約つきのスレッドになる——刻みごとに 1 コマの計算を、画面に出る予定の
  /// 刻みの余裕の前までに。
  func testTheRenderThreadRunsUnderTheFramesTimeConstraint() throws {
    let surface = try open(text).surface
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    driver.bind(surface.id)
    waitUntilPaused(surface)
    let policy = try XCTUnwrap(
      RenderThread.shared.performAndWait { _ in Self.timeConstraint() }, "時間制約つき")
    XCTAssertEqual(policy.period, HeadlessDriver.period, accuracy: 1e-6)
    // 計算は、核が制約の半分まで引き上げて持つ。
    XCTAssertGreaterThanOrEqual(policy.computation, RenderThread.frameComputation - 1e-6)
    XCTAssertEqual(
      policy.constraint, HeadlessDriver.period - FrameRecorder.commitMargin, accuracy: 1e-6)
  }

  /// スレッドの時間制約（秒）。
  private struct TimeConstraint {
    var period: Double
    var computation: Double
    var constraint: Double
  }

  /// 呼んだスレッドの時間制約。時間制約つきでなければ nil。
  private nonisolated static func timeConstraint() -> TimeConstraint? {
    var policy = thread_time_constraint_policy_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    var isDefault: boolean_t = 0
    let result = withUnsafeMutablePointer(to: &policy) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_policy_get(
          mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, &count,
          &isDefault)
      }
    }
    guard result == KERN_SUCCESS, isDefault == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    func seconds(_ ticks: UInt32) -> Double {
      Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
    return TimeConstraint(
      period: seconds(policy.period), computation: seconds(policy.computation),
      constraint: seconds(policy.constraint))
  }

  private func waitUntilPaused(_ surface: MetalTextSurface) {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } while !driver.isPaused(surface.id) && Date() < deadline
    XCTAssertTrue(driver.isPaused(surface.id), "刻みが止まる")
  }
}

/// 自分では刻まない刻み。次に画面に出る刻みは、いつ問われても `lead` 秒後。止める・再開するは描画スレッドだけが書く。
private final class ManualClock: FrameClock, @unchecked Sendable {
  private let lead: Double
  var isPaused = false
  let period = 1.0 / 120

  init(lead: Double) {
    self.lead = lead
  }

  func nextTarget(after now: Double) -> Double { now + lead }

  func invalidate() {}
}
