import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 行の見せ方の規則。壊れると CRLF の行末に記号が出る、タブの幅が今の面とずれる、制御文字が見えない（または行が
/// 崩れる）、minified の 1 行が 1 コマの手間を行の長さに比例させる。
final class LineShaperTests: XCTestCase {
  private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) as CTFont

  private func source(_ string: String) -> LineShaper.Source {
    LineShaper.source(row: 0, in: TextRope(string)).source
  }

  private var cell: CGFloat {
    LineShaper.shape(source(" "), font: font, tabWidth: 0).width
  }

  /// 行は `\n` で割り、行末の `\r` は描かない（途中の `\r` は記号で見せる）。
  func testTrailingCarriageReturnIsNotDrawn() {
    let text = TextRope("ab\r\ncd\r\n")
    XCTAssertEqual(LineShaper.source(row: 0, in: text).source.length, 2)
    XCTAssertEqual(LineShaper.display(LineShaper.source(row: 1, in: text).source).units.count, 2)
    XCTAssertEqual(
      Array(LineShaper.display(source("a\rb")).units), [0x61, 0x240D, 0x62], "途中の CR は ␍")
  }

  /// C0 の制御文字は U+2400 台、DEL は U+2421、U+2028・U+2029・U+0085 は U+FFFD。タブはそのまま（空ける）。
  func testControlCharactersAreShownAsSymbols() {
    let units = LineShaper.display(source("\u{0}\u{1b}\t\u{7f}\u{2028}\u{2029}\u{85}")).units
    XCTAssertEqual(Array(units), [0x2400, 0x241B, 0x09, 0x2421, 0xFFFD, 0xFFFD, 0xFFFD])
  }

  /// タブはインデント単位の桁まで空ける（次のタブ位置へ）。
  func testTabAdvancesToTheNextIndentStop() {
    let tab = cell * 4
    let x = LineShaper.measure(source("\tx"), font: font, tabWidth: tab).x(ofOffset: 1)
    XCTAssertEqual(x, tab, accuracy: 0.01)
    let after = LineShaper.measure(source("ab\tx"), font: font, tabWidth: tab).x(ofOffset: 3)
    XCTAssertEqual(after, tab, accuracy: 0.01, "途中のタブも次の刻みまで")
  }

  /// 1 行で描くのは 10000 単位まで（書記素の境で切る）。残りは描かず、その数を返す。行の中身は先頭しか読まない。
  func testLongLinesStopAtTheLimitOnAGraphemeBoundary() {
    let long = String(repeating: "a", count: 9_999) + "👍🏽" + String(repeating: "b", count: 500_000)
    let line = LineShaper.source(row: 0, in: TextRope(long)).source
    XCTAssertLessThan(line.head.count, 10_100, "先頭しか読まない")
    let (units, omitted) = LineShaper.display(line)
    XCTAssertEqual(units.count, 9_999, "絵文字の書記素を割らずに手前で切る")
    XCTAssertEqual(omitted, long.utf16.count - 9_999)
    let shaped = LineShaper.shape(line, font: font, tabWidth: cell * 4)
    XCTAssertEqual(shaped.omitted, omitted)
  }

  /// 組んだ字は元の行の位置を持つ（色を役割から引くため）。
  func testGlyphsCarryTheirOffsets() {
    let shaped = LineShaper.shape(source("let 日本"), font: font, tabWidth: cell * 4)
    let offsets = shaped.runs.flatMap(\.offsets)
    XCTAssertEqual(offsets, [0, 1, 2, 3, 4, 5])
  }
}
