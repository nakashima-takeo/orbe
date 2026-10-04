import Foundation
import XCTest

@testable import OrbeEditorCore

/// 位置の掃引（`EditSweep`）。正解は、束の編集を後ろから 1 つずつ当てる計算（掃引の前の規則）。壊れると、カーソルの多い
/// 打鍵の後で検索の地・出現・プロジェクト検索の区間・変わった役割が字からずれる、カーソルが置換の中に落ちる。
final class EditSweepTests: XCTestCase {
  /// 区間の列を編集 1 つで写す（落とす規則の正解）。
  private static func trackOne(_ edit: TextEdit, _ ranges: [NSRange]) -> [NSRange] {
    ranges.compactMap { item in
      if NSMaxRange(item) <= edit.range.location { return item }
      if item.location >= NSMaxRange(edit.range) {
        return NSRange(location: item.location + edit.change, length: item.length)
      }
      return nil
    }
  }

  /// 集合を編集 1 つで写す（広げる規則の正解）。
  private static func trackOne(_ edit: TextEdit, _ set: IndexSet) -> IndexSet {
    let range = edit.range
    let end = NSMaxRange(range)
    let touches = set.intersects(integersIn: max(0, range.location - 1)..<(end + 1))
    var result = set
    result.remove(integersIn: range.location..<end)
    result.shift(startingAt: end, by: edit.change)
    if touches, edit.replacementLength > 0 {
      result.insert(integersIn: range.location..<(range.location + edit.replacementLength))
    }
    return result
  }

  /// 位置を編集 1 つで写す（置換の中は置換の終わり、始まりは動かない）。
  private static func mapOne(_ edit: TextEdit, _ offset: Int) -> Int {
    if offset <= edit.range.location { return offset }
    if offset < NSMaxRange(edit.range) { return edit.range.location + edit.replacementLength }
    return offset + edit.change
  }

  /// 長さ `length` の本文に当てる、重ならない昇順の編集（接する・同じ位置の挿入と置換を含む）。
  private static func randomEdits(length: Int, _ generator: inout SeededGenerator) -> [TextEdit] {
    var edits: [TextEdit] = []
    var cursor = 0
    while cursor <= length, edits.count < 8 {
      let start = cursor + Int.random(in: 0...2, using: &generator)
      guard start <= length else { break }
      var removed = Int.random(in: 0...min(3, length - start), using: &generator)
      if let last = edits.last, last.range.length == 0, last.range.location == start, removed == 0 {
        guard start < length else { break }
        removed = 1
      }
      let inserted = Int.random(in: 0...3, using: &generator)
      guard removed > 0 || inserted > 0 else {
        cursor = start + 1
        continue
      }
      edits.append(
        TextEdit(
          range: NSRange(location: start, length: removed),
          replacement: String(repeating: "x", count: inserted)))
      cursor = start + removed
    }
    return edits
  }

  private static func randomRanges(length: Int, _ generator: inout SeededGenerator) -> [NSRange] {
    var ranges: [NSRange] = []
    var cursor = 0
    while cursor <= length {
      let start = cursor + Int.random(in: 0...3, using: &generator)
      guard start <= length else { break }
      let span = Int.random(in: 0...min(3, length - start), using: &generator)
      ranges.append(NSRange(location: start, length: span))
      cursor = start + max(1, span)
    }
    return ranges
  }

  /// 区間の列・集合・位置を、束で 1 回で写した結果が、後ろから 1 つずつ当てた結果と同じ。
  func testSweepEqualsApplyingEditsOneByOneFromTheBack() {
    var generator = SeededGenerator(seed: 0x5157)
    for _ in 0..<2000 {
      let length = Int.random(in: 0...30, using: &generator)
      let edits = Self.randomEdits(length: length, &generator)
      let sweep = EditSweep(edits)
      let ranges = Self.randomRanges(length: length, &generator)
      let expectedRanges = edits.reversed().reduce(ranges) { Self.trackOne($1, $0) }
      XCTAssertEqual(sweep.track(ranges), expectedRanges, "\(edits) \(ranges)")
      var set = IndexSet()
      for range in Self.randomRanges(length: length, &generator) where range.length > 0 {
        set.insert(integersIn: range.location..<NSMaxRange(range))
      }
      let expectedSet = edits.reversed().reduce(set) { Self.trackOne($1, $0) }
      XCTAssertEqual(sweep.track(set), expectedSet, "\(edits) \(Array(set))")
      let offsets = (0..<6).map { _ in Int.random(in: 0...length, using: &generator) }
      let expectedOffsets = offsets.map { offset in
        edits.reversed().reduce(offset) { Self.mapOne($1, $0) }
      }
      XCTAssertEqual(sweep.map(offsets), expectedOffsets, "\(edits) \(offsets)")
    }
  }

  /// 当てた順の編集の列（文書が束を後ろから当てた順、束がいくつも続く）を束に分けて掃引した結果が、1 つずつ当てた結果と同じ。
  func testBatchesOfAppliedEditsEqualApplyingOneByOne() {
    var generator = SeededGenerator(seed: 0xba7c)
    for _ in 0..<1000 {
      var length = Int.random(in: 0...30, using: &generator)
      var applied: [TextEdit] = []
      for _ in 0..<Int.random(in: 1...4, using: &generator) {
        let edits = Self.randomEdits(length: length, &generator)
        applied += edits.reversed()
        length += edits.reduce(0) { $0 + $1.change }
      }
      let ranges = Self.randomRanges(length: 30, &generator)
      let expected = applied.reduce(ranges) { Self.trackOne($1, $0) }
      let swept = EditSweep.batches(applied: applied).reduce(ranges) { $1.track($0) }
      XCTAssertEqual(swept, expected, "\(applied) \(ranges)")
    }
  }

  /// 手間は編集の数と区間の数の和に比例する——1 万の編集で 1 万の区間を写しても、1 つずつの計算（1 億回）にならない。
  func testSweepIsLinear() {
    let edits = (0..<10_000).map {
      TextEdit(range: NSRange(location: $0 * 100, length: 0), replacement: "x")
    }
    let ranges = (0..<10_000).map { NSRange(location: $0 * 100 + 50, length: 3) }
    let began = Date()
    let tracked = EditSweep(edits).track(ranges)
    XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
    XCTAssertEqual(tracked.last, NSRange(location: 999_950 + 10_000, length: 3))
  }

  /// 接する削除が連なる束（接する 1 字の選択を全部消す ⌫）でも、位置の掃引は編集の数と位置の数の和に比例する。
  func testSweepOfAdjoiningDeletionsIsLinear() {
    let edits = (0..<10_000).map {
      TextEdit(range: NSRange(location: $0, length: 1), replacement: "")
    }
    let began = Date()
    let mapped = EditSweep(edits).map(Array(0...10_000))
    XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
    XCTAssertEqual(Set(mapped), [0], "どの位置も消した区間の始まりへ寄る")
  }
}
