import AppKit
import Metal
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// スクロールを共にする 2 面（並列の diff）——どちらの面の指も両面を同じ位置へ動かし、同じ刻みに同じ位置を描き、範囲は
/// 大きい方で、見せる操作にも両面が従い、同じ周に置いた並びのずらしは 1 回だけ。壊れると、並列の左右が食い違ってずれた
/// 行を見比べる、短い側の端で長い側が止まる、diff を取り直すたびに片側だけ跳ねる。
@MainActor
final class SurfaceSharedScrollTests: EngineTestCase {
  private let size = CGSize(width: 400, height: 300)

  /// 行数の違う 2 面（左が長い）を結んだもの。
  func pair(left: Int = 200, right: Int = 120) throws -> (Opened, Opened) {
    let a = try open(rows(left), size: size)
    let b = try open(rows(right, width: 60), size: size)
    for opened in [a, b] {
      opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    }
    a.surface.shareScroll(with: b.surface)
    return (a, b)
  }

  func finger(
    _ surface: MetalTextSurface, _ t: Double, _ dy: Double, _ phase: ScrollInput.Phase
  ) {
    surface.scroll(ScrollInput(timestamp: t, delta: SIMD2(0, dy), precise: true, phase: phase))
  }

  /// どちらの面で指を動かしても、両面の位置は同じ。
  func testAFingerOnEitherSurfaceMovesBoth() throws {
    let (a, b) = try pair()
    finger(b.surface, 1, 0, .began)
    finger(b.surface, 1.01, -300, .changed)
    XCTAssertEqual(b.surface.scrollPosition.y, 300)
    XCTAssertEqual(a.surface.scrollPosition, b.surface.scrollPosition)
    finger(a.surface, 1.02, 100, .changed)
    XCTAssertEqual(a.surface.scrollPosition.y, 200)
    XCTAssertEqual(b.surface.scrollPosition, a.surface.scrollPosition)
    XCTAssertEqual(
      b.surface.viewport.firstVisible, b.document.text.lineStart(Int(200 / 18)),
      "動かしていない面の見えている範囲も知らせ直す")
  }

  /// 縦の範囲は長い方の面の端まで——短い面も長い面の最後の行まで送れ、End も長い面の End と同じ所へ行く。横の範囲は長い
  /// 行の面の端まで。
  func testTheRangeIsTheLargerOfTheTwo() throws {
    let (a, b) = try pair()
    _ = a.surface.snapshot()
    _ = b.surface.snapshot()
    let longest = a.surface.rows.lastTop(lineCount: a.document.text.lineCount)
    XCTAssertEqual(b.surface.scrollState().limits.maximum.y, longest)
    a.surface.scrollToDocumentEdge(end: true)
    a.surface.flush()
    let end = a.surface.scrollPosition
    a.surface.scrollToDocumentEdge(end: false)
    a.surface.flush()
    b.surface.scrollToDocumentEdge(end: true)
    b.surface.flush()
    XCTAssertEqual(b.surface.scrollPosition, end, "短い面の End は長い面の End")
    b.surface.scroll(toFirstLine: 1e9)
    b.surface.flush()
    XCTAssertEqual(a.surface.scrollPosition.y, longest, "短い面から長い面の最後まで送れる")
    let wide = b.surface.scrollState().limits.maximum.x
    XCTAssertGreaterThan(wide, 0, "前提: 右の面の行は見えている幅より長い")
    XCTAssertEqual(a.surface.scrollState().limits.maximum.x, wide, "短い行の面も右へ送れる")
  }

  /// 刻みの位置は最初に読んだ面が封じる——同じ刻みの間に届いた指の出来事は、もう一方の面のその刻みには出ず、次の刻みに
  /// 出る。
  func testBothSurfacesDrawTheSamePositionOnATick() throws {
    let (a, b) = try pair()
    let period = 1.0 / 60
    let tick = 100 * period
    let revisions = (a.surface.drawn.revision, b.surface.drawn.revision)
    let first = a.surface.scroll.frame(at: tick, period: period, material: revisions.0)
    finger(a.surface, 1, 0, .began)
    finger(a.surface, 1.01, -120, .changed)
    let second = b.surface.scroll.frame(at: tick, period: period, material: revisions.1)
    XCTAssertEqual(second.position, first.position, "同じ刻みは同じ位置")
    let next = b.surface.scroll.frame(at: tick + period, period: period, material: revisions.1)
    XCTAssertEqual(next.position.y, 120, "次の刻みで出る")
    XCTAssertEqual(
      a.surface.scroll.frame(at: tick + period, period: period, material: revisions.0).position,
      next.position)
  }

  /// 区間を見せると両面がその位置へ動く。
  func testRevealMovesBoth() throws {
    let (a, b) = try pair()
    let text = a.document.text
    a.surface.reveal(NSRange(location: text.lineStart(150), length: 0), policy: .center)
    a.surface.flush()
    XCTAssertGreaterThan(a.surface.scrollPosition.y, 0)
    XCTAssertEqual(b.surface.scrollPosition, a.surface.scrollPosition)
  }

  /// 同じ周に両面の差し込みを置き直しても、見えている先頭の行を保つずらしは 1 回だけ（両面が揃ったまま跳ねない）。
  func testRowsReplacedInTheSameCycleShiftOnce() throws {
    let (a, b) = try pair()
    a.surface.scroll(toFirstLine: 50)
    a.surface.flush()
    let before = a.surface.scrollPosition.y
    let lines = (0..<3).map { InsertedLine("pad \($0)") }
    for surface in [a.surface, b.surface] {
      surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .lines(lines))]))
    }
    a.surface.flush()
    XCTAssertEqual(a.surface.scrollPosition.y, before + 3 * 18)
    XCTAssertEqual(b.surface.scrollPosition, a.surface.scrollPosition)
    XCTAssertEqual(a.surface.viewport.firstVisible, a.document.text.lineStart(50))
  }

  /// 面が閉じれば外れ、残った面の範囲は自分の本文だけで決まる。
  func testClosingOneSurfaceDetachesIt() throws {
    let a = try open(rows(30), size: size)
    a.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    do {
      let b = try open(rows(300), size: size)
      b.surface.setPresentation(SurfacePresentation(showsMinimap: false))
      a.surface.shareScroll(with: b.surface)
      a.surface.flush()
      XCTAssertGreaterThan(
        a.surface.scrollState().limits.maximum.y, a.surface.rows.lastTop(lineCount: 31),
        "前提: 長い面の範囲を共にしている")
    }
    pump(until: { a.surface.partner == nil }, "相手が閉じれば外れる")
    XCTAssertEqual(
      a.surface.scrollState().limits.maximum.y,
      max(0, a.surface.rows.lastTop(lineCount: a.document.text.lineCount)))
  }

  /// 相手が閉じた面は、別の面とどちら向きにも結び直せる——範囲は新しい相手と 2 面の大きい方（閉じた面の寄与は残らない）で、
  /// 先に結んだ面は結び直す操作を呼んだ面だけ。
  func testASurfaceLeftAloneSharesAgain() throws {
    func surface(_ lines: Int) throws -> Opened {
      let opened = try open(rows(lines), size: size)
      opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
      return opened
    }
    func end(_ opened: Opened) -> Double {
      opened.surface.rows.lastTop(lineCount: opened.document.text.lineCount)
    }
    let a = try surface(30)
    do {
      let b = try surface(300)
      a.surface.shareScroll(with: b.surface)
    }
    pump(until: { a.surface.partner == nil }, "前提: 相手が閉じれば外れる")
    do {
      let c = try surface(100)
      a.surface.shareScroll(with: c.surface)
      a.surface.flush()
      XCTAssertEqual(c.surface.scrollState().limits.maximum.y, end(c), "閉じた面の範囲は残らない")
      c.surface.setRows(
        SurfaceRows(insertions: [
          RowInsertion(line: 50, content: .lines((0..<40).map { InsertedLine("pad \($0)") }))
        ]))
      c.surface.flush()
      XCTAssertEqual(a.surface.scrollState().limits.maximum.y, end(c), "新しい相手の範囲に従う")
    }
    pump(until: { a.surface.partner == nil }, "前提: 相手が閉じれば外れる")
    let d = try surface(100)
    d.surface.shareScroll(with: a.surface)
    let order = { (opened: Opened) in opened.surface.scrollGroup.map(ObjectIdentifier.init) }
    XCTAssertEqual(order(a), [ObjectIdentifier(d.surface), ObjectIdentifier(a.surface)])
    XCTAssertEqual(order(d), order(a), "先に結んだ面は 1 つだけ")
  }

  /// 一方の面が閉じれば、刻みを止めていた残った面も起き、狭まった自分の範囲に収めた位置を描く。
  func testClosingOneSurfaceRedrawsTheOther() throws {
    let a = try open(rows(30), size: size)
    a.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let period = HeadlessDriver.period
    var t = (CACurrentMediaTime() / period).rounded(.up) * period
    let clock: ManualClock
    do {
      let b = try open(rows(300), size: size)
      b.surface.setPresentation(SurfacePresentation(showsMinimap: false))
      a.surface.shareScroll(with: b.surface)
      clock = bindManually((a, b)).0
      a.surface.scroll(toFirstLine: 250)
      a.surface.flush()
      for _ in 0..<10 where !clock.isPaused {
        tick(a.surface, t)
        t += period
      }
      XCTAssertEqual(drawn(a.surface)?.y, 250 * 18, "前提: 長い面の範囲で描いた")
      XCTAssertTrue(clock.isPaused, "前提: 描くものが無く刻みを止めている")
    }
    pump(until: { a.surface.partner == nil }, "前提: 相手が閉じれば外れる")
    RenderThread.shared.performAndWait { _ in 0 }
    XCTAssertFalse(clock.isPaused, "残った面の刻みを再開する")
    tick(a.surface, t)
    let end = a.surface.rows.lastTop(lineCount: a.document.text.lineCount)
    XCTAssertEqual(drawn(a.surface)?.y, end, "自分の範囲に収めた位置を描く")
  }

  /// 刻みの位置を封じた後に main が位置を置き直せば、封じた値は古くなる——同じ刻みを後で描く面は、置き直した後の材料には
  /// 新しい位置を、置く前の材料には置く前の位置を描く。
  func testPlacingAfterASealedTickIsDrawnOnThatTick() throws {
    let (a, b) = try pair()
    let period = 1.0 / 60
    let tick = 100 * period
    let versions = (a.surface.material.revision, b.surface.material.revision)
    let sealed = a.surface.scroll.frame(at: tick, period: period, material: versions.0)
    ScrollBox.commit([
      (a.surface.scroll, ScrollBox.Commit(material: versions.0 + 1, position: SIMD2(0, 90))),
      (b.surface.scroll, ScrollBox.Commit(material: versions.1 + 1)),
    ])
    let old = b.surface.scroll.frame(at: tick, period: period, material: versions.1)
    XCTAssertEqual(old.position, sealed.position, "置く前の材料には置く前の位置")
    let fresh = b.surface.scroll.frame(at: tick, period: period, material: versions.1 + 1)
    XCTAssertEqual(fresh.position.y, 90, "置き直した後の材料には新しい位置")
  }

  /// 同じ周に一方の面が置いた位置は、その面の読み取りにはその場で、相手の面の読み取りには出したときに揃う。同じ周に両面が
  /// 位置を置けば、後に置いた方を当てる。
  func testPositionsPlacedInOneCycle() throws {
    let (a, b) = try pair()
    a.surface.scroll(toFirstLine: 10)
    XCTAssertEqual(a.surface.scrollPosition.y, 10 * 18)
    XCTAssertEqual(b.surface.scrollPosition.y, 0, "相手の面にはまだ出ていない")
    a.surface.flush()
    XCTAssertEqual(b.surface.scrollPosition.y, 10 * 18, "出せば揃う")
    b.surface.scroll(toFirstLine: 20)
    a.surface.scroll(toFirstLine: 30)
    a.surface.flush()
    XCTAssertEqual(b.surface.scrollPosition.y, 30 * 18, "後に置いた方")
    a.surface.scroll(toFirstLine: 40)
    b.surface.scroll(toFirstLine: 50)
    a.surface.flush()
    XCTAssertEqual(a.surface.scrollPosition.y, 50 * 18, "後に置いた方")
    XCTAssertEqual(b.surface.scrollPosition, a.surface.scrollPosition)
  }
}

/// 描画スレッドの 1 コマの順を決めて流す場——2 面の刻みを手で打ち、どちらの面が先に描くかを決める。
@MainActor
extension SurfaceSharedScrollTests {
  /// 刻みを手で打つ時計（止める・再開するは描画スレッドが書き、刻みの順はテストが決める。次の刻みはいつも今なので、起こされて
  /// その場で描くことはしない）。
  private final class ManualClock: FrameClock {
    var isPaused = false
    var period: Double { HeadlessDriver.period }
    func nextTarget(after now: Double) -> Double { now }
    func invalidate() {}
  }

  /// 画面外の 1 枚へ描き、画面に出た知らせを出さない（上限に当たらないよう、出ていないコマの上限を大きくする）。
  private final class SinkTarget: FrameTarget, @unchecked Sendable {
    private let texture: MTLTexture

    init() {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 800, height: 600, mipmapped: false)
      descriptor.usage = .renderTarget
      descriptor.storageMode = .private
      texture = RenderThread.device!.makeTexture(descriptor: descriptor)!
    }

    var limit: Int { 1_000 }

    func acquire() -> AcquiredFrame? {
      AcquiredFrame(texture: texture) { _, _ in }
    }
  }

  private func tick(_ surface: MetalTextSurface, _ target: Double) {
    let id = surface.id
    RenderThread.shared.performAndWait { renderer in
      renderer.tick(id, target: target)
      return 0
    }
    // GPU に出した命令の列が終わるのを待つ（上限 3 に当たって飛ばさない）。
    RenderThread.shared.performAndWait { _ in 0 }
    Thread.sleep(forTimeInterval: 0.01)
  }

  private func drawn(_ surface: MetalTextSurface) -> SIMD2<Double>? {
    let id = surface.id
    return RenderThread.shared.performAndWait { $0.slot(id)?.drawnPosition }
  }

  /// 2 面を画面外の描き先と手で打つ時計に結ぶ。
  @discardableResult
  private func bindManually(_ pair: (Opened, Opened)) -> (ManualClock, ManualClock) {
    let clocks = (ManualClock(), ManualClock())
    for (opened, clock) in [(pair.0, clocks.0), (pair.1, clocks.1)] {
      opened.surface.viewStateDidChange(size: size, scale: 2, visible: true)
      let id = opened.surface.id
      let target = SinkTarget()
      RenderThread.shared.perform { $0.bind(id, target: target, clock: clock) }
    }
    _ = RenderThread.shared.performAndWait { $0.gate.wait() != nil }
    pair.0.surface.flush()
    pair.1.surface.flush()
    return clocks
  }

  /// マウスのホイール（段の無い出来事）が刻みの途中に届き、その刻みを先に描いた面と後で描く面に分かれても、後の面は次の
  /// 刻みで追いつき、両面は同じ位置で止まる（後の面がその刻みの封じた位置を描いたまま、描いたつもりで止まらない）。
  func testAWheelBetweenTheTwoSurfacesOfATickStillMovesBoth() throws {
    let (a, b) = try pair()
    bindManually((a, b))
    let period = HeadlessDriver.period
    var t = (CACurrentMediaTime() / period).rounded(.up) * period
    for surface in [a.surface, b.surface] { tick(surface, t) }
    t += period
    tick(b.surface, t)
    a.surface.scroll(
      ScrollInput(timestamp: CACurrentMediaTime(), delta: SIMD2(0, -3), precise: false))
    tick(a.surface, t)
    for _ in 0..<3 {
      t += period
      for surface in [b.surface, a.surface] { tick(surface, t) }
    }
    XCTAssertEqual(drawn(b.surface)?.y, 30, "先に描いた面はホイールの量だけ動く")
    XCTAssertEqual(drawn(a.surface), drawn(b.surface), "後に描いた面も次の刻みで追いつく")
  }

  /// キャレットへの横の寄せ（描画スレッドが行を組んで決める位置）は、刻みを止めていた相手の面も起こす——相手が古い横の位置
  /// のまま止まらない。
  func testAHorizontalRevealWakesThePausedPartner() throws {
    let (a, b) = try pair()
    let clocks = bindManually((a, b))
    let period = HeadlessDriver.period
    var t = (CACurrentMediaTime() / period).rounded(.up) * period
    let text = b.document.text
    b.surface.reveal(NSRange(location: text.lineStart(1) - 1, length: 0), policy: .center)
    b.surface.flush()
    for _ in 0..<10 where !clocks.0.isPaused {
      tick(a.surface, t)
      t += period
    }
    XCTAssertTrue(clocks.0.isPaused, "前提: 相手の面は描くものが無く刻みを止めている")
    tick(b.surface, t)
    XCTAssertGreaterThan(try XCTUnwrap(drawn(b.surface)).x, 0, "前提: 寄せた面は横に動く")
    XCTAssertFalse(clocks.0.isPaused, "相手の面の刻みを再開する")
  }
}

extension SurfaceSharedScrollTests {
  /// 刻みの予定時刻が刻みの長さの格子から半刻みずれている画面（表示の位相は画面ごとに違う）でも、続く 2 つの刻みを同じ
  /// 刻みとして封じない——前の刻みの位置を次の刻みに描き続けない。
  func testConsecutiveTicksAtHalfPhaseAreSealedApart() throws {
    let (a, _) = try pair()
    let period = 1.0 / 120
    let n = (CACurrentMediaTime() / period).rounded(.down) + 100
    let revision = a.surface.drawn.revision
    let first = a.surface.scroll.frame(at: (n + 0.51) * period, period: period, material: revision)
    finger(a.surface, 1, 0, .began)
    finger(a.surface, 1.01, -90, .changed)
    let next = a.surface.scroll.frame(at: (n + 1.49) * period, period: period, material: revision)
    XCTAssertEqual(first.position.y, 0)
    XCTAssertEqual(next.position.y, 90, "次の刻みは新しい位置を描く")
  }
}
