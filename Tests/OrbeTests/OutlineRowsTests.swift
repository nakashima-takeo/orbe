import Foundation
import XCTest

@testable import Orbe
@testable import OrbeEditorCore

/// アウトラインの見えている行とシンボルの対応——畳んだ部分木と絞り込みを映した行を、行の列を作らずに引く。
///
/// 壊れると何が起きるか。畳んだり絞り込んだりした後に、行が別のシンボルを描く・押した行と違うシンボルへ飛ぶ・カーソル
/// 追従が違う行を光らせる。
final class OutlineRowsTests: OrbeTestCase {
  /// 乱数で作った木（先行順）。
  private func randomOutline(_ generator: inout SeededGenerator, count: Int)
    -> DocumentOutline
  {
    var items: [OutlineExtraction.Item] = []
    var cursor = 0
    func add(depth: Int, budget: inout Int) {
      while budget > 0, Int.random(in: 0..<4, using: &generator) != 0 {
        budget -= 1
        let start = cursor
        cursor += 1
        let index = items.count
        items.append(
          OutlineExtraction.Item(
            range: NSRange(location: start, length: 0),
            nameRange: NSRange(location: start, length: 0),
            name: "s\(index)", kind: .function, node: UInt(index + 1)))
        if depth < 5 { add(depth: depth + 1, budget: &budget) }
        cursor += 1
        items[index].range.length = cursor - start
      }
    }
    var budget = count
    while budget > 0 { add(depth: 0, budget: &budget) }
    return OutlineExtraction.nest(items, version: 0)
  }

  /// 先行順を頭から辿って、畳んだシンボルの子孫と、残らないシンボルを飛ばした列（答え合わせの素朴な作り方）。
  private func naiveRows(
    _ outline: DocumentOutline, visible: Set<Int>?, collapsed: (Int) -> Bool
  ) -> [Int] {
    var rows: [Int] = []
    var index = 0
    let symbols = outline.symbols
    while index < symbols.count {
      guard visible?.contains(index) ?? true else {
        index += 1
        continue
      }
      rows.append(index)
      let hasVisibleChildren =
        visible.map { set in (index + 1..<symbols[index].subtreeEnd).contains(where: set.contains) }
        ?? outline.hasChildren(index)
      index = hasVisibleChildren && collapsed(index) ? symbols[index].subtreeEnd : index + 1
    }
    return rows
  }

  private func check(
    _ rows: OutlineRows, _ expected: [Int], symbols: Int, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(rows.count, expected.count, file: file, line: line)
    XCTAssertEqual((0..<rows.count).map(rows.symbol(at:)), expected, file: file, line: line)
    let positions = Dictionary(uniqueKeysWithValues: expected.enumerated().map { ($1, $0) })
    for symbol in 0..<symbols {
      XCTAssertEqual(
        rows.row(of: symbol), positions[symbol], "シンボル \(symbol)", file: file, line: line)
    }
  }

  /// 畳んだシンボル（入れ子で畳んだものも）と絞り込みの有無のどの組み合わせでも、素朴に辿った列と同じ行になり、行 ↔ シンボル
  /// が互いに逆になる。
  func testRowsMatchANaiveWalkUnderFoldingAndFiltering() {
    var generator = SeededGenerator(seed: 11)
    for _ in 0..<40 {
      let outline = randomOutline(&generator, count: 60)
      let count = outline.symbols.count
      let collapsed = Set((0..<count).filter { _ in Int.random(in: 0..<4, using: &generator) == 0 })
      let visibleSymbols = Set(
        (0..<count).filter { _ in Int.random(in: 0..<2, using: &generator) == 0 }
      ).union(0..<min(1, count))
      var ancestors = visibleSymbols
      for symbol in visibleSymbols {
        var parent = outline.symbols[symbol].parent
        while let current = parent {
          ancestors.insert(current)
          parent = outline.symbols[current].parent
        }
      }
      let filter = OutlineFilterResult(
        pattern: "x", token: outline.token, visible: ancestors.sorted(), matched: [], matches: [:])

      check(
        OutlineRows(outline: outline, filter: nil, folding: .collapsed(collapsed.sorted())),
        naiveRows(outline, visible: nil, collapsed: collapsed.contains), symbols: count)
      check(
        OutlineRows(outline: outline, filter: filter, folding: .collapsed(collapsed.sorted())),
        naiveRows(outline, visible: ancestors, collapsed: collapsed.contains), symbols: count)
      check(
        OutlineRows(outline: outline, filter: nil, folding: .allExcept(collapsed)),
        naiveRows(outline, visible: nil, collapsed: { !collapsed.contains($0) }), symbols: count)
      check(
        OutlineRows(outline: outline, filter: filter, folding: .allExcept(collapsed)),
        naiveRows(outline, visible: ancestors, collapsed: { !collapsed.contains($0) }),
        symbols: count)
    }
  }
}

/// 再現できる乱数（テストの乱択を毎回同じにする。OrbeEditorCoreTests の同名のものと同じ）。
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}
