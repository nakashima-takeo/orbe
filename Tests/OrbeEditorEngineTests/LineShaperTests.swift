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

  /// C0 の制御文字は U+2400 台、DEL は U+2421、U+2028・U+2029・U+0085・U+FEFF は U+FFFD。タブはそのまま（空ける）。
  func testControlCharactersAreShownAsSymbols() {
    let line = source("\u{0}\u{1b}\t\u{7f}\u{2028}\u{2029}\u{85}a\u{feff}")
    let units = LineShaper.display(line).units
    XCTAssertEqual(
      Array(units), [0x2400, 0x241B, 0x09, 0x2421, 0xFFFD, 0xFFFD, 0xFFFD, 0x61, 0xFFFD])
  }

  /// 方向を変える書式文字は `[U+202E]` の箱で見せ、字の並びを変えない（Trojan Source で見た目と実際の順が食い違わない）。
  /// 箱は 1 単位のまま中身の幅を持ち、中身の字は元の位置を持つ。
  func testDirectionalFormattingCharactersAreShownAsBoxes() {
    let formats: [UInt16] = [
      0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F,
      0x061C,
    ]
    for format in formats {
      let shaped = LineShaper.shape(
        source("a" + String(utf16CodeUnits: [format], count: 1) + "b"), font: font, tabWidth: 0)
      let label = LineShaper.shape(String(format: "[U+%04X]", format), font: font)
      let boxed = shaped.runs.flatMap { zip($0.offsets, $0.glyphs) }.filter { $0.0 == 1 }
      XCTAssertEqual(
        boxed.map(\.1), label.runs.flatMap(\.glyphs), String(format: "U+%04X は箱で見せる", format))
    }
    let line = source("ab\u{202E}cd")
    let shaped = LineShaper.shape(line, font: font, tabWidth: 0)
    let offsets = shaped.runs.flatMap(\.offsets)
    XCTAssertEqual(offsets, [0, 1] + Array(repeating: 2, count: 8) + [3, 4], "箱の中身は 8 字")
    let xs = shaped.runs.flatMap(\.xs)
    XCTAssertEqual(xs, xs.sorted(), "箱の後ろの字も左から右の順のまま")
    XCTAssertEqual(shaped.width, cell * 12, accuracy: 0.01)
    XCTAssertEqual(x(3, "ab\u{202E}cd", tab: 0), cell * 10, accuracy: 0.01, "箱は 1 単位で 8 桁")
    XCTAssertEqual(x(2, "ab\u{202E}cd", tab: 0), cell * 2, accuracy: 0.01, "箱の位置は箱の左端")
  }

  /// 行は常に左から右の段落——右から左の字で始まる行でも、行頭の字が左端に来る（VS Code と同じ）。
  func testLinesAreLeftToRightParagraphs() {
    let shaped = LineShaper.shape(source("// שלום x"), font: font, tabWidth: 0)
    let pairs = shaped.runs.flatMap { zip($0.offsets, $0.xs) }
    let first = try? XCTUnwrap(pairs.first { $0.0 == 0 })
    XCTAssertEqual(first?.1 ?? -1, 0, accuracy: 0.01, "行頭の / が左端")
    let last = pairs.max { $0.1 < $1.1 }
    XCTAssertEqual(last?.0, 8, "行末の x が右端")
  }

  private func x(_ column: Int, _ string: String, tab: CGFloat) -> CGFloat {
    let shaped = LineShaper.shape(source(string), font: font, tabWidth: tab)
    let (offsets, xs) = shaped.stops
    return CaretX.x(ofColumn: column, offsets: offsets, xs: xs, width: shaped.width)
  }

  /// タブはインデント単位の桁まで空ける（次のタブ位置へ）。
  func testTabAdvancesToTheNextIndentStop() {
    let tab = cell * 4
    XCTAssertEqual(x(1, "\tx", tab: tab), tab, accuracy: 0.01)
    XCTAssertEqual(x(3, "ab\tx", tab: tab), tab, accuracy: 0.01, "途中のタブも次の刻みまで")
  }

  /// 位置の x は、その位置以上の元の位置を持つ最初の字の x——書記素の内側は書記素の始まりの後ろの字、行末と描かない部分は
  /// 行の幅。キャレット・選択の地・クリックの当たりが同じ規則で出る。
  func testCaretXIsTheFirstGlyphAtOrAfterTheColumn() {
    let tab = cell * 4
    XCTAssertEqual(x(0, "ab", tab: tab), 0, accuracy: 0.01)
    XCTAssertEqual(x(1, "ab", tab: tab), cell, accuracy: 0.01)
    XCTAssertEqual(x(2, "ab", tab: tab), cell * 2, accuracy: 0.01, "行末は行の幅")
    XCTAssertGreaterThan(x(4, "👍🏽a", tab: tab), 0)
    XCTAssertEqual(x(2, "👍🏽a", tab: tab), x(4, "👍🏽a", tab: tab), "書記素の内側は次の字の x")
    let long = String(repeating: "a", count: 10_050)
    let shaped = LineShaper.shape(source(long), font: font, tabWidth: tab)
    XCTAssertEqual(x(10_040, long, tab: tab), shaped.width, accuracy: 0.01, "描かない部分は描いた部分の右端")
  }

  /// 1 行で描くのは 10000 単位まで（書記素の境で切る）。残りは描かず、その数を返す。行の中身は先頭しか読まない。
  func testLongLinesStopAtTheLimitOnAGraphemeBoundary() {
    let long = String(repeating: "a", count: 9_999) + "👍🏽" + String(repeating: "b", count: 500_000)
    let line = LineShaper.source(row: 0, in: TextRope(long)).source
    XCTAssertLessThan(line.head.count, 10_100, "先頭しか読まない")
    let units = LineShaper.display(line).units
    let omitted = LineShaper.display(line).omitted
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
