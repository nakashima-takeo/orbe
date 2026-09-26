import Foundation
import XCTest

@testable import OrbeEditorCore

/// 役割の並びと、古い結果を今の版へ写すずらしの規則。壊れると打鍵の直後や裏の結果が届いたときに色・印・地が字から
/// ずれる。main の即時の更新と届いた結果の写しは同じ規則を使うので、ここで規則そのものを固める。
final class RoleRunsTests: XCTestCase {
  /// 字ごとの役割（素朴な答え）。
  private func perUnit(_ runs: RoleRuns) -> [SyntaxRole?] {
    var result = [SyntaxRole?](repeating: nil, count: runs.length)
    for span in runs.roles(in: NSRange(location: 0, length: runs.length)) {
      for offset in span.range.location..<NSMaxRange(span.range) { result[offset] = span.role }
    }
    return result
  }

  private func runs(_ spans: [HighlightSpan], length: Int) -> RoleRuns {
    var runs = RoleRuns(length: length)
    runs.replace(NSRange(location: 0, length: length), with: spans)
    return runs
  }

  private func span(_ location: Int, _ length: Int, _ role: SyntaxRole) -> HighlightSpan {
    HighlightSpan(range: NSRange(location: location, length: length), role: role)
  }

  /// 区間の役割は重ならない昇順で、区間の中に閉じ、役割の無い字を含まない。隣り合う同じ役割は 1 つの区間。
  func testRolesAreClippedToTheRangeAndCoalesced() {
    let runs = runs([span(0, 3, .keyword), span(3, 2, .keyword), span(8, 4, .string)], length: 14)
    XCTAssertEqual(
      runs.roles(in: NSRange(location: 0, length: 14)),
      [
        HighlightSpan(range: NSRange(location: 0, length: 5), role: .keyword),
        HighlightSpan(range: NSRange(location: 8, length: 4), role: .string),
      ])
    XCTAssertEqual(
      runs.roles(in: NSRange(location: 4, length: 5)),
      [
        HighlightSpan(range: NSRange(location: 4, length: 1), role: .keyword),
        HighlightSpan(range: NSRange(location: 8, length: 1), role: .string),
      ])
  }

  /// 挿入は挿入点を含む連なりを伸ばす——語の終わりに打てば前の語の色を引き継ぎ（境は前の連なり）、先頭の挿入は後ろの
  /// 連なりを伸ばす。削除は縮め、消えた連なりの両隣が同じ役割なら繋がる。
  func testEditsExtendTheRunBeforeTheInsertionAndShrinkOnDeletion() {
    var runs = runs([span(0, 3, .keyword), span(4, 3, .type)], length: 8)
    runs.apply(TextEdit(range: NSRange(location: 3, length: 0), replacement: "xy"))
    XCTAssertEqual(
      perUnit(runs),
      [.keyword, .keyword, .keyword, .keyword, .keyword, nil, .type, .type, .type, nil])
    runs.apply(TextEdit(range: NSRange(location: 0, length: 0), replacement: "z"))
    XCTAssertEqual(perUnit(runs).first, .keyword, "先頭の挿入は後ろの連なり")
    runs.apply(TextEdit(range: NSRange(location: 6, length: 1), replacement: ""))
    XCTAssertEqual(
      runs.roles(in: NSRange(location: 0, length: runs.length)).map(\.role), [.keyword, .type],
      "役割なしの 1 字を消すと前後が詰まる")
    runs.apply(TextEdit(range: NSRange(location: 0, length: runs.length), replacement: "all new"))
    XCTAssertEqual(perUnit(runs), [SyntaxRole?](repeating: nil, count: 7), "全体の置換は役割なし")
  }

  /// 乱択の編集と置き換えを、字ごとの配列の素朴な答えと同じに追う。
  func testRandomEditsMatchAPerUnitReference() {
    var generator = SeededGenerator(seed: 11)
    let roles: [SyntaxRole?] = [nil, .keyword, .string, .comment]
    var reference = [SyntaxRole?](repeating: nil, count: 50)
    var runs = RoleRuns(length: 50)
    for _ in 0..<800 {
      let location = Int.random(in: 0...reference.count, using: &generator)
      let length = Int.random(in: 0...min(12, reference.count - location), using: &generator)
      if Bool.random(using: &generator) {
        let inserted = Int.random(in: 0...6, using: &generator)
        let role: SyntaxRole?
        if location > 0 {
          role = reference[location - 1]
        } else {
          role = location + length < reference.count ? reference[location + length] : nil
        }
        reference.replaceSubrange(
          location..<(location + length), with: [SyntaxRole?](repeating: role, count: inserted))
        runs.apply(
          TextEdit(
            range: NSRange(location: location, length: length),
            replacement: String(repeating: "x", count: inserted)))
      } else {
        guard length > 0 else { continue }
        let role = roles.randomElement(using: &generator)!
        reference.replaceSubrange(
          location..<(location + length), with: [SyntaxRole?](repeating: role, count: length))
        runs.replace(
          NSRange(location: location, length: length),
          with: role.map {
            [HighlightSpan(range: NSRange(location: location, length: length), role: $0)]
          }
            ?? [])
      }
      XCTAssertEqual(perUnit(runs), reference)
    }
  }

  /// 集合のずらしは落とさない——編集に掛かる（接する）なら置換後の区間を足し、後ろは平行移動する。
  func testTrackingASetGrowsOverTheEdit() {
    let set = IndexSet(integersIn: 2..<5).union(IndexSet(integersIn: 10..<12))
    let edit = TextEdit(range: NSRange(location: 4, length: 3), replacement: "abcde")
    XCTAssertEqual(
      edit.track(set), IndexSet(integersIn: 2..<9).union(IndexSet(integersIn: 12..<14)))
    let apart = TextEdit(range: NSRange(location: 7, length: 0), replacement: "q")
    XCTAssertEqual(
      apart.track(set), IndexSet(integersIn: 2..<5).union(IndexSet(integersIn: 11..<13)),
      "離れた挿入は足さない")
  }

  /// ハンクのずらし——編集より後ろのハンクは増減した行の数だけ動き、前のハンクは動かない。
  func testHunksShiftByTheLinesTheEditAddsOrRemoves() {
    var log = EditLog()
    let hunks = [
      LineHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1),
      LineHunk(oldStart: 5, oldCount: 0, newStart: 6, newCount: 2),
      LineHunk(oldStart: 9, oldCount: 2, newStart: 10, newCount: 0),
    ]
    let insert = log.append(
      TextEdit(range: NSRange(location: 10, length: 0), replacement: "a\nb\n"),
      start: TextPoint(row: 3, column: 0), oldEnd: TextPoint(row: 3, column: 0),
      newEnd: TextPoint(row: 5, column: 0))
    XCTAssertEqual(
      insert.track(hunks),
      [
        LineHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1),
        LineHunk(oldStart: 5, oldCount: 0, newStart: 8, newCount: 2),
        LineHunk(oldStart: 9, oldCount: 2, newStart: 12, newCount: 0),
      ])
    let delete = log.append(
      TextEdit(range: NSRange(location: 10, length: 4), replacement: ""),
      start: TextPoint(row: 3, column: 0), oldEnd: TextPoint(row: 5, column: 0),
      newEnd: TextPoint(row: 3, column: 0))
    XCTAssertEqual(delete.track(insert.track(hunks)), hunks, "挿して消せば元の行")
  }

  /// 記録は結果を待っている版より後ろだけを持つ。捨てた版の結果は写せない。
  func testTheLogKeepsEditsSinceTheOldestAwaitedVersion() {
    var log = EditLog()
    for index in 0..<5 {
      _ = log.append(
        TextEdit(range: NSRange(location: index, length: 0), replacement: "x"),
        start: TextPoint(row: 0, column: index), oldEnd: TextPoint(row: 0, column: index),
        newEnd: TextPoint(row: 0, column: index + 1))
    }
    XCTAssertEqual(log.version, 5)
    XCTAssertEqual(log.edits(since: 2)?.map(\.version), [3, 4, 5])
    XCTAssertEqual(log.edits(since: 5)?.count, 0)
    log.discard(through: 3)
    XCTAssertNil(log.edits(since: 2), "捨てた版")
    XCTAssertEqual(log.edits(since: 3)?.map(\.version), [4, 5])
  }
}
