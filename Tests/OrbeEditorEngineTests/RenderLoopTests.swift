import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 刻みの止め方と再開（電池を守る規則）。窓を出さない刻み（`HeadlessDriver`）で本物の描画スレッドを回す。壊れると、
/// 新しい面が 1 コマ目で固まる、止まっている間や隠れたタブで描き続けて CPU と電池を使う。
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
    XCTAssertFalse(driver.isPaused(surface.id), "箱に書けば起こす")
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
