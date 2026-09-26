import Foundation
import XCTest

@testable import OrbeEditorCore

/// 要約付きの B 木を、ロープより大きく深い木（高さ 3〜4）で乱択に動かし、整数の配列の素朴な答えと比べる。壊れると
/// 1MB 級の文書（塊が千を超え、木が深い）でだけ本文や役割がずれ、保存した内容が面の本文と違う。
final class SummaryTreeTests: XCTestCase {
  /// 1 要素を 1 と数え、値の和も持つ要約。
  private struct Totals: TreeSummary {
    var count: Int
    var sum: Int

    static let zero = Totals(count: 0, sum: 0)

    static func + (lhs: Totals, rhs: Totals) -> Totals {
      Totals(count: lhs.count + rhs.count, sum: lhs.sum + rhs.sum)
    }
  }

  private struct Item: TreeElement {
    let value: Int
    var summary: Totals { Totals(count: 1, sum: value) }
  }

  /// 大きな削除と挿入（高さの違う部分木を繋ぐ経路・節が割れて根が伸びる経路を通る）を繰り返し、要素・位置の探索・前の和・
  /// 前向きの読みを配列と照合する。途中で取った写しは、その後の変更で変わらない。
  func testRandomReplacementsOnADeepTreeMatchAnArray() {
    var generator = SeededGenerator(seed: 23)
    var reference = Array(0..<30_000)
    var tree = SummaryTree(reference.map(Item.init))
    var next = reference.count
    var snapshots: [(tree: SummaryTree<Item>, values: [Int])] = []
    for step in 0..<1_500 {
      let lower = Int.random(in: 0...reference.count, using: &generator)
      let removed = Int.random(in: 0...min(3_000, reference.count - lower), using: &generator)
      let inserted = Int.random(
        in: 0...(reference.count > 60_000 ? 1_000 : 5_000), using: &generator)
      let values = Array(next..<(next + inserted))
      next += inserted
      reference.replaceSubrange(lower..<(lower + removed), with: values)
      tree.replaceSubrange(lower..<(lower + removed), with: values.map(Item.init))
      XCTAssertEqual(tree.count, reference.count)
      if step % 100 == 0 { snapshots.append((tree, reference)) }
      if step % 150 == 149 { assertMatches(tree, reference, &generator) }
    }
    for snapshot in snapshots {
      XCTAssertEqual(snapshot.tree.elements(from: 0).map(\.value), snapshot.values, "写しは変わらない")
    }
  }

  private func assertMatches(
    _ tree: SummaryTree<Item>, _ reference: [Int], _ generator: inout SeededGenerator,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(tree.elements(from: 0).map(\.value), reference, file: file, line: line)
    XCTAssertEqual(tree.summary.count, reference.count, file: file, line: line)
    XCTAssertEqual(tree.summary.sum, reference.reduce(0, +), file: file, line: line)
    var sums = [0]
    for value in reference { sums.append(sums[sums.count - 1] + value) }
    for _ in 0..<50 {
      let index = Int.random(in: 0..<reference.count, using: &generator)
      XCTAssertEqual(tree[index].value, reference[index], "要素 \(index)", file: file, line: line)
      XCTAssertEqual(
        tree.prefix(upTo: index).sum, sums[index], "前の和 \(index)", file: file, line: line)
      XCTAssertEqual(
        Array(tree.elements(from: index).prefix(20).map(\.value)),
        Array(reference[index..<min(reference.count, index + 20)]), file: file, line: line)
      let position = Int.random(in: 0..<sums[sums.count - 1], using: &generator)
      let expected = sums.lastIndex { $0 <= position }!
      let found = tree.locate(position, by: \.sum)
      XCTAssertEqual(found.index, expected, "和 \(position) を含む要素", file: file, line: line)
      XCTAssertEqual(found.before.sum, sums[expected], file: file, line: line)
    }
  }
}
