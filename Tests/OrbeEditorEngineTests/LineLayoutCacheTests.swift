import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 描画スレッドの行の組版のキャッシュの量。壊れると、描画スレッドの覚える量が行の数や長さに比例して黙って膨らむ。
@MainActor
final class LineLayoutCacheTests: XCTestCase {
  private let config = SurfaceConfig(style: EngineTestCase.style(), omittedLabel: { "+\($0)" })
  private let fonts = FontRegistry()

  private func source(_ string: String) -> LineShaper.Source {
    LineShaper.source(row: 0, in: TextRope(string)).source
  }

  @discardableResult
  private func lay(_ cache: LineLayoutCache, _ string: String) -> LaidOutLine {
    cache.line(source(string), tabColumns: 4, config: config, fonts: fonts)
  }

  /// 行の数の上限を越えたら、古く使われたものから半分を捨てる。直前に使った行は残る。
  func testCountStaysWithinCapacityAndKeepsRecentLines() {
    let cache = LineLayoutCache()
    for i in 0..<LineLayoutCache.capacity - 1 { lay(cache, "line \(i)") }
    lay(cache, "line 0")
    lay(cache, "line \(LineLayoutCache.capacity - 1)")
    XCTAssertEqual(cache.count, LineLayoutCache.capacity)
    lay(cache, "overflow")
    XCTAssertLessThanOrEqual(cache.count, LineLayoutCache.capacity / 2 + 1)
    let kept = cache.count
    lay(cache, "line 0")
    XCTAssertEqual(cache.count, kept, "直前に使った行は残っている")
    lay(cache, "line 1")
    XCTAssertEqual(cache.count, kept + 1, "古く使われた行は捨てた")
    for i in 0..<LineLayoutCache.capacity * 2 { lay(cache, "more \(i)") }
    XCTAssertLessThanOrEqual(cache.count, LineLayoutCache.capacity)
  }

  /// 長い行ばかりでも、持つ単位の数は上限を越えない。
  func testWeightStaysWithinBudgetForLongLines() {
    let cache = LineLayoutCache()
    let long = String(repeating: "a", count: 9_990)
    for i in 0..<150 { lay(cache, long + "\(i)") }
    XCTAssertLessThanOrEqual(cache.weight, LineLayoutCache.weightBudget)
    XCTAssertGreaterThan(cache.count, 10)
  }
}
