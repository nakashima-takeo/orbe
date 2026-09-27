import Foundation
import XCTest

@testable import OrbeEditorCore

/// 取り出したシンボルの入れ子・鍵・位置の問いの規則。
///
/// 壊れると何が起きるか。アウトラインの親子が崩れる（メソッドが型の外に並ぶ、CSS の 2 つ目のセレクタが 1 つ目の子になる）。
/// 取り直すたびに畳んだ行が開く。キャレットのあるシンボルと違う行が光る。編集の後に飛び先が名前からずれる。
final class OutlineNestTests: XCTestCase {
  private func item(
    _ name: String, _ start: Int, _ end: Int, kind: OutlineKind = .function, node: UInt? = nil
  ) -> OutlineExtraction.Item {
    OutlineExtraction.Item(
      range: NSRange(location: start, length: end - start),
      nameRange: NSRange(location: start, length: 1), name: name, kind: kind,
      node: node ?? UInt(start * 10_000 + end))
  }

  private func shape(_ outline: DocumentOutline) -> [String] {
    outline.symbols.map { String(repeating: "  ", count: $0.depth) + $0.name }
  }

  /// 範囲の包含で入れ子にし、位置順（開始の昇順・終わりの降順）の先行順に並べる。部分木の終わりと親が先行順で揃う。
  func testItemsNestByContainmentInPreorder() {
    let outline = OutlineExtraction.nest(
      [item("b", 12, 20), item("A", 0, 30), item("a", 2, 10), item("B", 40, 50)], version: 3)
    XCTAssertEqual(shape(outline), ["A", "  a", "  b", "B"])
    XCTAssertEqual(outline.symbols.map(\.parent), [nil, 0, 0, nil])
    XCTAssertEqual(outline.symbols.map(\.subtreeEnd), [3, 2, 3, 4])
    XCTAssertTrue(outline.hasChildren(0))
    XCTAssertFalse(outline.hasChildren(1))
  }

  /// 同じ節から出たシンボル（CSS のカンマで並んだセレクタ）は、範囲が同じでも兄弟。別の節が同じ範囲なら子。
  func testSymbolsFromTheSameNodeAreSiblings() {
    let outline = OutlineExtraction.nest(
      [
        item("h1", 0, 10, kind: .selector, node: 7), item("h2", 0, 10, kind: .selector, node: 7),
        item("inner", 0, 10, node: 8),
      ], version: 0)
    XCTAssertEqual(shape(outline), ["h1", "h2", "  inner"])
  }

  /// 鍵は祖先の名前と種類の道筋で、位置を含まない（前に何かが増えても同じ鍵）。同じ道筋が並べば出現順の番号で分ける。
  func testKeysFollowTheNamePathAndNumberRepeats() {
    let before = OutlineExtraction.nest(
      [item("A", 0, 30, kind: .class), item("f", 2, 10), item("f", 12, 20)], version: 0)
    let after = OutlineExtraction.nest(
      [
        item("Z", 0, 5, kind: .class), item("A", 10, 40, kind: .class), item("f", 12, 20),
        item("f", 22, 30),
      ], version: 0)
    XCTAssertEqual(Set(before.symbols.map(\.key)).count, 3, "同じ名前の兄弟も鍵は別")
    for index in before.symbols.indices {
      XCTAssertEqual(after.index(of: before.symbols[index].key), index + 1)
    }
    XCTAssertNil(before.index(of: after.symbols[0].key))
    let otherKind = OutlineExtraction.nest([item("A", 0, 30, kind: .struct)], version: 0)
    XCTAssertNil(before.index(of: otherKind.symbols[0].key), "種類が違えば別のシンボル")
  }

  /// 位置を含む最も深いシンボル。範囲の終わりの位置も含む。同じ範囲の兄弟なら先頭のもの。どれにも入らなければ nil。
  func testTheDeepestSymbolContainingAnOffset() {
    let outline = OutlineExtraction.nest(
      [
        item("A", 0, 30), item("a", 2, 10), item("b", 12, 20), item("s1", 40, 50, node: 9),
        item("s2", 40, 50, node: 9),
      ], version: 0)
    XCTAssertEqual(outline.deepest(containing: 5), 1)
    XCTAssertEqual(outline.deepest(containing: 10), 1, "終わりの位置も含む")
    XCTAssertEqual(outline.deepest(containing: 11), 0, "子の間は親")
    XCTAssertEqual(outline.deepest(containing: 25), 0)
    XCTAssertNil(outline.deepest(containing: 35))
    XCTAssertEqual(outline.deepest(containing: 45), 3, "同じ範囲の兄弟は先頭")
  }
}

/// 位置を版の間で写す純関数。
///
/// 壊れると何が起きるか。取り直す前のアウトラインで、飛び先が名前の途中や隣の行にずれる。関数の本体を 1 字直しただけで、
/// その関数がカーソル追従で見つからなくなる。
final class OutlinePositionTests: XCTestCase {
  private func edit(_ location: Int, _ length: Int, _ replacement: String) -> TextEdit {
    TextEdit(range: NSRange(location: location, length: length), replacement: replacement)
  }

  /// 前へ: 編集より前はそのまま、後ろは平行移動、置き換えた区間の中（両端を含む）は寄せる側へ。
  func testMappingForwardShiftsAndClampsIntoTheBias() {
    let insert = edit(10, 0, "xyz")
    XCTAssertEqual(insert.map(9, bias: .after), 9)
    XCTAssertEqual(insert.map(10, bias: .before), 10, "挿入の位置の終わりは前に残る")
    XCTAssertEqual(insert.map(10, bias: .after), 13, "挿入の位置の頭は後ろへ")
    XCTAssertEqual(insert.map(11, bias: .after), 14)
    let replace = edit(10, 5, "ab")
    XCTAssertEqual(replace.map(12, bias: .before), 10)
    XCTAssertEqual(replace.map(12, bias: .after), 12)
    XCTAssertEqual(replace.map(20, bias: .after), 17)
  }

  /// 後ろへ: 置き換えた字の中の位置は編集の頭へ、後ろは平行移動して戻る。
  func testMappingBackReturnsInsertedPositionsToTheirHead() {
    let insert = edit(10, 0, "xyz")
    XCTAssertEqual(insert.unmap(9), 9)
    XCTAssertEqual(insert.unmap(11), 10)
    XCTAssertEqual(insert.unmap(13), 10)
    XCTAssertEqual(insert.unmap(14), 11)
  }

  /// 記録は何回ぶんの編集でも順に（戻すときは逆順に）写し、捨てた版からは写せない。
  func testTheLogMapsAcrossSeveralEditsAndNotFromDiscardedVersions() {
    var log = EditLog()
    let origin = TextPoint(row: 0, column: 0)
    _ = log.append(edit(0, 0, "ab"), start: origin, oldEnd: origin, newEnd: origin)
    _ = log.append(edit(10, 3, ""), start: origin, oldEnd: origin, newEnd: origin)
    XCTAssertEqual(log.map(20, from: 0, bias: .after), 19)
    XCTAssertEqual(log.unmap(19, to: 0), 20)
    XCTAssertEqual(log.map(5, from: 1, bias: .after), 5)
    log.discard(through: 1)
    XCTAssertNil(log.map(20, from: 0, bias: .after))
    XCTAssertEqual(log.map(12, from: 1, bias: .after), 10)
  }
}
