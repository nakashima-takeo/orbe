import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 刻みの止め方と再開（電池を守る規則）と、刻みで描いたコマから main への知らせ。窓を出さない刻み（`HeadlessDriver`）
/// で本物の描画スレッドを回す。壊れると、新しい面が 1 コマ目で固まる、止まっている間や隠れたタブで描き続けて CPU と
/// 電池を使う、右にまだ本文が続くのに俯瞰の右の影が出ない。
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
    driver.bind(surface.id)
    waitUntilPaused(surface)
    let first = drawn(surface)
    XCTAssertGreaterThan(first, 0, "結んだら描く")
    let ticks = driver.ticks(surface.id)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(driver.ticks(surface.id), ticks, "止まっている間は刻みが来ない")

    surface.scroll(
      ScrollInput(timestamp: CACurrentMediaTime(), delta: SIMD2(0, -1), precise: false))
    waitUntilPaused(surface)
    XCTAssertEqual(drawn(surface), first + 1, "変わったコマだけ描く")
  }

  /// 見えていない面（窓に無い・隠れたタブ）は描かずに刻みを止める。
  func testInvisibleSurfaceDoesNotDraw() throws {
    let opened = try open(text)
    let surface = opened.surface
    driver.bind(surface.id)
    waitUntilPaused(surface)
    XCTAssertEqual(drawn(surface), 0)
    surface.setIndentUnit(2)
    waitUntilPaused(surface)
    XCTAssertEqual(drawn(surface), 0, "起こされても見えていなければ描かない")
  }

  /// 止まっていた面を起こしたら、次に画面に出る刻みまでに描き終えられる限り、刻みを待たずにその場で 1 コマ描く。残りが
  /// 足りなければ刻みに任せる。
  func testWakingAStoppedSurfaceDrawsAtOnceWhenThereIsTime() throws {
    let opened = try open(text)
    let surface = opened.surface
    surface.viewStateDidChange(size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    for (lead, drawsAtOnce) in [(0.005, true), (0.001, false)] {
      let id = surface.id
      let driver = driver!
      RenderThread.shared.perform { renderer in
        renderer.bind(
          id, target: OffscreenTarget(device: renderer.device, driver: driver, holds: false),
          clock: ManualClock(lead: lead))
      }
      // 手で刻んで、描いてから止まるまで進める（描いたコマが画面に出るのも待つ）。
      var stopped = false
      for _ in 0..<50 where !stopped {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        stopped = RenderThread.shared.performAndWait { renderer in
          renderer.tick(id, target: CACurrentMediaTime() + lead)
          return renderer.slot(id)?.clock?.isPaused == true && renderer.slot(id)?.unpresented == 0
        }
      }
      XCTAssertTrue(stopped, "前提: 描いてから止まっている")
      let before = drawn(surface)
      surface.setIndentUnit(before % 2 == 0 ? 2 : 4)
      let (after, paused) = RenderThread.shared.performAndWait {
        ($0.slot(id)?.recorder.drawnCount ?? -1, $0.slot(id)?.clock?.isPaused ?? true)
      }
      XCTAssertEqual(after, drawsAtOnce ? before + 1 : before, "残り \(lead)s")
      XCTAssertFalse(paused, "刻みは再開する")
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

  private func drawn(_ surface: MetalTextSurface) -> Int {
    let id = surface.id
    return RenderThread.shared.performAndWait { $0.slot(id)?.recorder.drawnCount ?? -1 }
  }

  private func waitUntilPaused(_ surface: MetalTextSurface) {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } while !driver.isPaused(surface.id) && Date() < deadline
    XCTAssertTrue(driver.isPaused(surface.id), "刻みが止まる")
  }
}

/// 自分では刻まない刻み。次に画面に出る刻みは、いつ問われても `lead` 秒後。
private final class ManualClock: FrameClock {
  private let lead: Double
  var isPaused = false
  let period = 1.0 / 120

  init(lead: Double) {
    self.lead = lead
  }

  func nextTarget(after now: Double) -> Double { now + lead }

  func invalidate() {}
}
