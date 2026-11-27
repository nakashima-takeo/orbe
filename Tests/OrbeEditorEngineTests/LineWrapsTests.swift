import XCTest

@testable import OrbeEditorCore
@testable import OrbeEditorEngine

/// 行ごとの折り返しの木と、縦の並びの段の式。壊れると、折り返した面で行・キャレット・当たりが別の段の位置に出る、打鍵で
/// 段の数が変わった後の行の位置がずれる。
final class LineWrapsTests: XCTestCase {
  private static func wrapped(_ segments: Int) -> WrappedLine {
    let starts = (1..<segments).map { Int32($0 * 10) }
    return WrappedLine(starts: starts, indent: 0, ends: starts.map { $0 + 1 })
  }

  /// 行ごとの段の数 `counts` の折り返し。
  private static func wraps(_ counts: [Int]) -> LineWraps {
    LineWraps(
      width: 100, tabWidth: 28, version: 0, lines: counts.map { $0 > 1 ? wrapped($0) : nil })
  }

  private static func counts(_ wraps: LineWraps) -> [Int] {
    (0..<wraps.lineCount).map { wraps.wrap(ofLine: $0)?.segments ?? 1 }
  }

  func testSegmentsAndLinesRoundTrip() {
    let wraps = Self.wraps([1, 3, 1, 1, 2, 1])
    XCTAssertEqual(wraps.segmentCount, 9)
    XCTAssertEqual((0...6).map(wraps.segments(before:)), [0, 1, 4, 5, 6, 8, 9])
    XCTAssertEqual(wraps.segments(before: 8), 11, "行の数より後ろは 1 行 1 段")
    let expected: [(Int, Int)] = [
      (0, 0), (1, 0), (1, 1), (1, 2), (2, 0), (3, 0), (4, 0), (4, 1), (5, 0),
    ]
    for (segment, pair) in expected.enumerated() {
      let found = wraps.line(atSegment: segment)
      XCTAssertEqual([found.line, found.segment], [pair.0, pair.1], "段 \(segment)")
    }
    XCTAssertEqual(wraps.line(atSegment: 11).line, 8)
    XCTAssertEqual(wraps.line(atSegment: -2).line, -2)
  }

  /// 置き換えは前後の 1 段の行の続きとまとめ、行の数が変わってよい。
  func testReplaceKeepsTheTreeAndMergesPlainRuns() {
    var wraps = Self.wraps([1, 1, 1, 3, 1, 1])
    wraps.replace(1..<2, with: [nil, nil])
    XCTAssertEqual(Self.counts(wraps), [1, 1, 1, 1, 3, 1, 1])
    wraps.replace(4..<5, with: [nil])
    XCTAssertEqual(Self.counts(wraps), [1, 1, 1, 1, 1, 1, 1])
    XCTAssertEqual(wraps.tree.count, 1, "1 段の行の続きは要素 1 つ")
    wraps.replace(7..<7, with: [Self.wrapped(2)])
    XCTAssertEqual(Self.counts(wraps), [1, 1, 1, 1, 1, 1, 1, 2])
    wraps.replace(0..<8, with: [])
    XCTAssertEqual(wraps.lineCount, 0)
    var many = Self.wraps((0..<500).map { $0 % 7 == 0 ? 2 : 1 })
    for line in stride(from: 0, to: 400, by: 13) {
      many.replace(line..<line + 1, with: [Self.wrapped(3)])
    }
    let reference = (0..<500).map { line -> Int in
      line < 400 && line % 13 == 0 ? 3 : line % 7 == 0 ? 2 : 1
    }
    XCTAssertEqual(Self.counts(many), reference)
    XCTAssertEqual(many.segmentCount, reference.reduce(0, +))
  }

  /// 折り返した行の段は表示の単位の 1 段で、行の上端・段の上端・y にある段・位置が段の単位になる。
  /// 置き換えの列をまとめて当てると、区間ごとに後ろから当てたのと同じ木になる——区間が多いときの組み直しも、少ないときの
  /// 区間ごとの置き換えも。
  func testReplacingManyRangesAtOnceMatchesReplacingThemOneByOne() {
    let counts = (0..<300).map { $0 % 7 == 0 ? 3 : $0 % 11 == 0 ? 2 : 1 }
    for step in [3, 300] {
      var edits: [(lines: Range<Int>, with: [WrappedLine?])] = []
      for start in stride(from: 1, to: 290, by: step) {
        let replacement: [WrappedLine?] = start % 2 == 0 ? [nil, nil] : [Self.wrapped(2)]
        edits.append((start..<start + 2, replacement))
      }
      var together = Self.wraps(counts)
      together.replace(edits)
      var oneByOne = Self.wraps(counts)
      for edit in edits.reversed() { oneByOne.replace(edit.lines, with: edit.with) }
      XCTAssertEqual(Self.counts(together), Self.counts(oneByOne), "\(edits.count) 区間")
      XCTAssertEqual(together.tree.count, oneByOne.tree.count, "1 段の行の続きは要素 1 つ")
    }
  }

  func testRowLayoutCountsSegments() {
    var rows = RowLayout(lineHeight: 10)
    rows.setWraps(Self.wraps([1, 3, 1]))
    XCTAssertEqual(rows.y(ofLine: 2), 40)
    XCTAssertEqual(rows.y(ofSegment: 2, line: 1), 30)
    XCTAssertEqual(rows.item(atY: 25), .line(1, segment: 1))
    XCTAssertEqual(rows.position(atY: 25, lineCount: 3), RowPosition(line: 1, offset: 1))
    XCTAssertEqual(rows.unit(of: RowPosition(line: 1, offset: 9), lineCount: 3), 3, "行の段の数で止まる")
    XCTAssertEqual(rows.lastTop(lineCount: 3), 40)
    XCTAssertEqual(rows.totalHeight(lineCount: 3), 50)
    XCTAssertEqual(rows.position(atY: 999, lineCount: 3), RowPosition(line: 2, offset: 0))
  }

  /// 面自身の編集は、掛かった行を折り返しを待つ行にし、計算し直す。段の数が変われば版が進む。
  func testShiftUnwrapsTheEditedLines() throws {
    let before = TextRope("a\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nc")
    var rows = RowLayout(lineHeight: 10)
    rows.setWraps(Self.wraps([1, 3, 1]))
    let version = rows.version
    let unwrapped = try XCTUnwrap(
      rows.shift(
        [TextEdit(range: NSRange(location: 1, length: 0), replacement: "\nx")], in: before))
    XCTAssertEqual(unwrapped.lines, [0..<2])
    XCTAssertEqual(rows.wraps?.lineCount, 4)
    rows.rewrap(unwrapped, version: 1) { lines, _ in lines.map { $0 == 1 ? Self.wrapped(2) : nil } }
    XCTAssertEqual((0..<4).map(rows.segments(ofLine:)), [1, 2, 3, 1])
    XCTAssertNotEqual(rows.version, version)
  }
}
