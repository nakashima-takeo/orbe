import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import OrbeEditorEngine

/// 刻みの止め方と再開（電池を守る規則）と、刻みで描いたコマから main への知らせ、描画スレッドの時間制約。窓を出さない
/// 刻み（`HeadlessDriver`）で本物の描画スレッドを回す。壊れると、面が 1 コマ目で固まる、止まっている間や隠れた
/// タブで描き続けて CPU と電池を使う、右にまだ本文が続くのに俯瞰の右の影が出ない、混んだ機械で描画スレッドが遅れて
/// 起きたり遅いコアに載ったりしてコマが落ちる。
@MainActor
final class RenderLoopTests: EngineTestCase {
  private var driver: HeadlessDriver!

  override func setUpWithError() throws {
    try super.setUpWithError()
    driver = HeadlessDriver()
    driver.start()
    waitForPipelines()
  }

  override func tearDownWithError() throws {
    driver?.stop()
    try super.tearDownWithError()
  }

  /// 同じ幅の行（描くたびに横の範囲が伸びて描き直すことが無い）。
  private let text = (0..<200).map { String(format: "line %03d", $0) }.joined(separator: "\n")

  /// 見えている面は描いてから止まり、止まっている間は刻みが来ない。材料が変われば 1 コマだけ描いて、また止まる（スクロール
  /// の状態は変わらないので、つまみは現れない）。
  func testDrawsOnceAfterAChangeAndStopsAgain() throws {
    let opened = try open(text)
    let surface = opened.surface
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    let target = driver.bind(surface.id)
    waitUntilPaused(surface)
    let first = target.acquired
    XCTAssertGreaterThan(first, 0, "結んだら描く")
    XCTAssertTrue(staysStopped(surface, for: 0.2), "止まっている間は刻みが来ない")

    surface.setIndentation(Indentation(unit: 2, usesTabs: false))
    surface.flush()
    waitUntilPaused(surface)
    XCTAssertEqual(
      target.acquired, first + 1,
      "変わったコマだけ描く。testInvisibleSurfaceDoesNotDraw の「起こされても見えていなければ描かない」"
        + "の対で、これが待たずに成り立たなくなったら、そのテストが確かめる時点も成り立たない")
  }

  /// スクロールするとつまみが現れ、止まって消え始める時刻にだけ起きて消え、消え終わったら起きない。
  func testTheThumbFadesAfterScrollingAndThenTheLoopStops() throws {
    let opened = try open(text)
    let surface = opened.surface
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    driver.bind(surface.id)
    waitUntilPaused(surface)
    surface.scroll(
      ScrollInput(timestamp: CACurrentMediaTime(), delta: SIMD2(0, -1), precise: false))
    waitUntilPaused(surface)
    XCTAssertNotNil(blinkWake(surface), "つまみが消え始める時刻に起きるタイマー")
    waitUntil(3) { blinkWake(surface) == nil && driver.isPaused(surface.id) }
    XCTAssertNil(blinkWake(surface), "消え終わったらタイマーは無い")
    XCTAssertTrue(staysStopped(surface, for: 0.3), "消え終わった後は起きない")
  }

  /// スクロールの直後（つまみが消え始める前）に隠れた面は、消え始める時刻に起きるタイマーを置かず、刻みも来ない。
  func testHidingRightAfterScrollingDoesNotWakeForTheFade() throws {
    let opened = try open(text)
    let surface = opened.surface
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    driver.bind(surface.id)
    waitUntilPaused(surface)
    surface.scroll(
      ScrollInput(timestamp: CACurrentMediaTime(), delta: SIMD2(0, -1), precise: false))
    waitUntilPaused(surface)
    // 下の「隠れた面はタイマーを置かない」の対。同じ時点で、起きる場合を待たずに確かめる。
    XCTAssertNotNil(blinkWake(surface), "前提: つまみが消え始める時刻に起きるタイマー")
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: false)
    surface.flush()
    waitUntilPaused(surface)
    XCTAssertNil(blinkWake(surface), "隠れた面はタイマーを置かない")
    // 消え始める時刻は、スクロールの後、つまみを隠すまでの待ちが明けたとき。見張り始める前にスクロールしたので、その待ちの
    // 長さだけ見張れば、見張るあいだに過ぎる。
    XCTAssertTrue(
      staysStopped(surface, for: Self.overviewStyle().hideDelay), "消え始める時刻を過ぎても起きない")
  }

  /// 見えている幅より長い行がある文書を開いても、最初に長さを測ったことによる横の範囲の変化ではつまみを出さない。
  func testOpeningADocumentWithALongLineDoesNotShowTheThumb() throws {
    let opened = try open(String(repeating: "x", count: 400) + "\n" + text, wraps: false)
    let surface = opened.surface
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    driver.bind(surface.id)
    waitUntil(5) { surface.clipsRight }
    XCTAssertTrue(surface.clipsRight, "前提: 長さを測った")
    waitUntilPaused(surface)
    let id = surface.id
    let shown = RenderThread.shared.performAndWait { $0.slot(id)?.motion.thumb.shown }
    XCTAssertEqual(shown, false, "つまみは出ない")
    XCTAssertNil(blinkWake(surface), "消え始めるのを待って起きない")
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
      surface.flush()
      // 手で刻んで、描いてから止まるまで進める（描いたコマが画面に出るのも待つ）。
      let stopped = waitUntil(5) {
        RenderThread.shared.performAndWait { renderer in
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
    XCTAssertGreaterThanOrEqual(policy.computation, 0.002 - 1e-6, "刻みごとに 2ms の計算")
    XCTAssertEqual(
      policy.constraint, HeadlessDriver.period - 0.001, accuracy: 1e-6, "起きてから刻み − 1ms 以内")
  }

  /// 見えている絵の差し込みの画像が地図の頁に収まりきらなくても、描けるだけ描いたら刻みは止まる。
  func testZoneImagesBeyondTheAtlasStillLetTheLoopStop() throws {
    let opened = try open(text)
    let surface = opened.surface
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    // 上限に近い画像を、頁に収まる数より 1 枚多く（大きさを変えて、別々の画素にする）。
    let images = (0...(4 * ImageAtlas.maximumPages)).map { i -> ZoneElement in
      let side = CGFloat(ImageAtlas.maximumSide - 2 * i) / surface.scale
      return .image(
        ZoneImage(frame: CGRect(x: 0, y: 0, width: side, height: side), image: ThreadZone.glyph))
    }
    let zone = PictureZone { _ in ZonePicture.single(height: 300, elements: images) }
    surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 2, content: .zone(zone))]))
    driver.bind(surface.id)
    waitUntilPaused(surface)
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

  private func waitUntilPaused(
    _ surface: MetalTextSurface, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(driver.waitUntilStopped(surface), "刻みが止まる", file: file, line: line)
  }

  /// 面の刻みが止まるのを待ってから、`seconds` のあいだ止まったままで、刻みが 1 つも来ないか。止まった刻みを起こし直す
  /// 経路は、いまは点滅とつまみのタイマーだけで、その有無は止まった時点の状態で読める（`blinkWake`）。この見張りは、
  /// タイマー以外の経路で起こし直す退行を、仕組みに依らずに捕まえるために置く。「もう起こし直さない」と言える処理の終わりを
  /// 観測する口が無いので、実時間で見張る。結び付けられる本番の遅れの定数は無いので、長さは呼び手が決める（ほかに決める
  /// 理由が無ければ、刻みの数十倍の 0.2〜0.3 秒。止まった刻みが起き直していれば、そのあいだに刻みが来る）。
  private func staysStopped(_ surface: MetalTextSurface, for seconds: TimeInterval) -> Bool {
    guard driver.waitUntilStopped(surface) else { return false }
    let id = surface.id
    let ticks = driver.ticks(id)
    return holds(for: seconds) { driver.isPaused(id) && driver.ticks(id) == ticks }
  }
}
