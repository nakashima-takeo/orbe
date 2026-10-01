import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 描画スレッドの行の組版のキャッシュと、字の色の引き当て。壊れると、描画スレッドの覚える量が行の数や長さに比例して
/// 黙って膨らむ、編集の後に古い行の組版で描く、右から左の字を含む行で構文色が抜ける。
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

  /// 編集は変わった行を捨て、後ろの行をずらす。全部の行が変わった編集は全部捨てる。
  func testRowEditsDropChangedRowsAndShiftTheRest() {
    let rows = Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, "r\($0)") })
    let edit = RowEdit(rows: 3..<5, inserted: 4, version: 1)
    let shifted = LineLayoutCache.shifted(rows, by: edit)
    XCTAssertEqual(shifted, [0: "r0", 1: "r1", 2: "r2", 7: "r5", 8: "r6", 9: "r7"])
    XCTAssertTrue(LineLayoutCache.shifted(rows, by: .all(version: 2)).isEmpty)
  }

  /// 本文の編集から変わった行を出す——置き換えた区間の始まりから終わりの行までが、置き換えの中身の行になる。
  func testRowEditFromATextEdit() {
    let text = TextRope("a\nb\nc\n")
    let edit = RowEdit(
      TextEdit(range: NSRange(location: 2, length: 2), replacement: "x\ny\nz\n"), in: text,
      version: 5)
    var expected = RowEdit(rows: 1..<3, inserted: 4, version: 5)
    expected.text = RowEdit.TextChange(range: NSRange(location: 2, length: 2), replacementLength: 6)
    XCTAssertEqual(edit, expected, "区間と置き換えの長さも持つ")
    let typed = RowEdit(
      TextEdit(range: NSRange(location: 2, length: 0), replacement: "q"), in: text, version: 6)
    expected = RowEdit(rows: 1..<2, inserted: 1, version: 6)
    expected.text = RowEdit.TextChange(range: NSRange(location: 2, length: 0), replacementLength: 1)
    XCTAssertEqual(typed, expected, "行の中の打鍵はその行だけ")
  }

  /// 空行の塊の上下の外の非空行の段は、行ごとに `LineShaper.source` と `LineDecor` の判定で歩いた答えと同じ（CR だけ・
  /// タブ・描きうる先頭に収まらない空白だけの行を含む）。同じ版では覚えた塊から引く。
  func testBlankBlocksAgreeWithWalkingRowByRow() {
    let long = String(repeating: " ", count: LineShaper.headLimit + 1)
    let edge = String(repeating: " ", count: LineShaper.headLimit)
    let pieces = [
      "", "  ", "\t", " \r", "\r", "x", "  y", "\t\tz", "    w", long, edge, edge + "\r",
    ]
    var generator = SystemRandomNumberGenerator()
    for trial in 0..<60 {
      let count = Int.random(in: 1...20, using: &generator)
      let lines = (0..<count).map { _ in pieces.randomElement(using: &generator)! }
      let text = TextRope(lines.joined(separator: "\n") + (Bool.random() ? "\n" : ""))
      let shown = lines.map { $0.count > 8 ? "空白×\($0.count)" : $0 }
      let blocks = BlankBlocks()
      let decor = (0..<text.lineCount).map {
        LineDecor(LineShaper.source(row: $0, in: text).source, unit: 2)
      }
      for row in 0..<text.lineCount where decor[row].blank {
        let above = (0..<row).last { !decor[$0].blank }.map { decor[$0].boundaries.count }
        let below = (row + 1..<text.lineCount).first { !decor[$0].blank }
          .map { decor[$0].boundaries.count }
        let around = blocks.around(row, in: text, version: trial, unit: 2)
        XCTAssertEqual(around.above, above, "\(shown) の行 \(row) の上")
        XCTAssertEqual(around.below, below, "\(shown) の行 \(row) の下")
      }
    }
  }
}
