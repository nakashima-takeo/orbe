import Foundation
import XCTest

@testable import OrbeEditorCore

/// 俯瞰の純関数——行の縮図（インデント・桁数・コメント行）と幾何（窓のスライド・帯・行 ↔ y・クリック → 行）。
/// 壊れると、ミニマップの帯が行単位で跳ぶ、長い文書で末尾の行が窓に入らない、クリックが別の行へ飛ぶ。
final class OverviewTests: XCTestCase {
  // MARK: - 行の縮図

  func testRowsMeasureIndentAndTrimmedLengthAndComment() {
    let text = "let a = 1\n  // note  \n\tx\n\n   \n"
    let index = LineIndex(text: text)
    let rows = OverviewRows.rows(
      lines: 0..<index.lineCount, text: text, index: index, tabWidth: 4,
      commentRanges: [NSRange(location: 12, length: 7)])
    XCTAssertEqual(
      rows,
      [
        OverviewRow(indent: 0, length: 9, isComment: false),
        OverviewRow(indent: 2, length: 7, isComment: true),
        OverviewRow(indent: 4, length: 1, isComment: false),
        OverviewRow(indent: 0, length: 0, isComment: false),
        OverviewRow(indent: 0, length: 0, isComment: false),
        OverviewRow(indent: 0, length: 0, isComment: false),
      ])
  }

  /// 窓は途中の行から始まってよい。本文は窓の先頭行から渡し、comment 区間は本文全体のオフセット。
  func testRowsAcceptAWindowInTheMiddle() {
    let text = "a\nbb\n  ccc\n// d\n"
    let index = LineIndex(text: text)
    let base = index.start(ofRow: 2)
    let rows = OverviewRows.rows(
      lines: 2..<4, text: String(text.utf16.dropFirst(base))!, index: index, tabWidth: 4,
      commentRanges: [NSRange(location: index.start(ofRow: 3), length: 4)])
    XCTAssertEqual(
      rows,
      [
        OverviewRow(indent: 2, length: 3, isComment: false),
        OverviewRow(indent: 0, length: 4, isComment: true),
      ])
    XCTAssertEqual(
      OverviewRows.rows(lines: 3..<9, text: "", index: index, tabWidth: 4, commentRanges: []), [],
      "索引に無い行の窓は空")
  }

  // MARK: - 幾何

  /// 収まる文書は窓が 0 で、帯は先頭行 × ピッチから可視行数ぶん。先頭行の隠れ割合まで帯が連続で追う。
  func testShortDocumentDoesNotSlideAndTheBandFollowsFractions() {
    let geometry = OverviewGeometry(
      lineCount: 50, firstLine: 2.5, visibleLines: 10, pitch: 4, height: 400)
    XCTAssertEqual(geometry.windowOffset, 0)
    XCTAssertEqual(geometry.band.y, 10)
    XCTAssertEqual(geometry.band.height, 40)
    XCTAssertEqual(geometry.y(ofLine: 3), 12)
    XCTAssertEqual(geometry.windowLines, 0..<50)
    XCTAssertEqual(geometry.line(atY: 13), 3)
    XCTAssertEqual(geometry.line(atY: 399), 49, "列の外は端の行")
  }

  /// 長い文書: 先頭で窓 0・帯は上端、末尾で窓は H − h・帯は下端。間は f に単調。
  func testLongDocumentSlidesProportionally() {
    let make = { (first: CGFloat) in
      OverviewGeometry(lineCount: 1000, firstLine: first, visibleLines: 20, pitch: 4, height: 400)
    }
    XCTAssertEqual(make(0).windowOffset, 0)
    XCTAssertEqual(make(0).band.y, 0)
    let last = make(980)
    XCTAssertEqual(last.windowOffset, 4000 - 400)
    XCTAssertEqual(last.band.y + last.band.height, 400, accuracy: 0.001, "末尾で帯は下端")
    XCTAssertEqual(last.windowLines, 900..<1000)
    XCTAssertEqual(last.line(atY: 0), 900)
    var previous: CGFloat = -1
    for first in stride(from: CGFloat(0), through: 980, by: 12.5) {
      let y = make(first).band.y
      XCTAssertGreaterThanOrEqual(y, previous, "帯は先頭行に単調追従する: f=\(first)")
      previous = y
    }
    XCTAssertEqual(make(990).windowOffset, 3600, "可視範囲を超えて送っても端で止まる")
  }

  func testProportionalMarksKeepAMinimumHeightAndStayInsideTheColumn() {
    let mark = OverviewGeometry.proportional(lines: 10..<11, of: 100, height: 200, minimum: 2)
    XCTAssertEqual(mark.y, 20)
    XCTAssertEqual(mark.height, 2)
    let tail = OverviewGeometry.proportional(lines: 99..<100, of: 100, height: 100, minimum: 4)
    XCTAssertEqual(tail.y + tail.height, 100, "最小高で下端を越えない")
    XCTAssertEqual(
      OverviewGeometry.proportional(lines: 0..<1, of: 0, height: 100, minimum: 2).height, 0)
  }
}
