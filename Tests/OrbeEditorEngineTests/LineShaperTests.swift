import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 行の見せ方の規則。壊れると CRLF の行末に記号が出る、タブの幅がインデントの単位とずれる、制御文字が見えない（または行が
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

  /// 描きうる先頭より長い行も、長さは行末の `\r` と改行を除いた中身で、読むのは描きうる先頭だけ（最後の行の行末の `\r` も
  /// 除く）。
  func testLongLineLengthExcludesTheTrailingCarriageReturn() {
    let long = String(repeating: "x", count: LineShaper.headLimit + 5)
    let text = TextRope(long + "\r\n" + long + "\n" + long + "\r")
    for row in 0..<3 {
      let line = LineShaper.source(row: row, in: text).source
      XCTAssertEqual(line.length, LineShaper.headLimit + 5, "行 \(row) の長さ")
      XCTAssertEqual(line.head.count, LineShaper.headLimit, "行 \(row) の読む先頭")
    }
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
    LineShaper.shape(source(string), font: font, tabWidth: tab).carets.x(column)
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

  /// 位置と x の対応は、組んだ行の双方向の対応と同じ——右から左の字を含む行でも、位置のキャレットの x が Core Text
  /// （`CTLineGetOffsetForStringIndex` の主）と一致する。壊れると、ヘブライ語・アラビア語の行でキャレット・選択の地が字と
  /// ずれる。
  func testCaretMapFollowsCoreTextInBidirectionalLines() {
    var direction = CTWritingDirection.leftToRight
    let paragraph = withUnsafeBytes(of: &direction) { bytes in
      let settings = [
        CTParagraphStyleSetting(
          spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
          value: bytes.baseAddress!)
      ]
      return CTParagraphStyleCreate(settings, settings.count)
    }
    let samples = [
      "ab שלום cd", "שלום עולם", "ab مرحبا cd", "مرحبا", "abc 123 אבג 456 def", "x😀y", "e\u{301}f",
    ]
    for string in samples {
      let attributed = NSAttributedString(
        string: string,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
      let line = CTLineCreateWithAttributedString(attributed)
      let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      let map = CaretMap(line, width: width)
      for offset in 0...(string as NSString).length {
        let primary = CTLineGetOffsetForStringIndex(line, offset, nil)
        XCTAssertEqual(map.x(offset), primary, accuracy: 0.01, "\(string) の位置 \(offset)")
      }
    }
  }

  /// 等幅のフォントの ASCII の字とタブだけの行は位置と x の対応をグリフの位置から作り、その答えは Core Text に縁を数えさせたものと同じ
  /// ——主と副の x と、区間の見た目の区間（打ち切った行の描かない部分も）。ASCII でない字を含む行は Core Text に数えさせる。
  func testASCIILinesBuildTheCaretMapFromGlyphsWithTheSameAnswer() {
    let tab = cell * 4
    let samples = [
      "", "a", "let x = [1, 2]  // note ", "\tif x {\t\ty }", "    indented", "a  b   c\t",
      String(repeating: "\"item\", 7, ", count: 900), String(repeating: "a", count: 10_050),
    ]
    for string in samples {
      let shaped = LineShaper.shape(source(string), font: font, tabWidth: tab)
      XCTAssertTrue(shaped.simple, "前提: 単純な行 \(string.prefix(20))")
      let fast = shaped.carets
      let reference = CaretMap(shaped.line, width: shaped.width)
      XCTAssertEqual(fast.count, reference.count)
      for offset in 0...fast.count {
        XCTAssertEqual(fast.x(offset), reference.x(offset), "\(string.prefix(20)) の位置 \(offset)")
      }
      for (from, to) in [(0, fast.count), (1, 3), (2, 2), (fast.count / 2, fast.count)] {
        XCTAssertEqual(
          fast.segments(from: from, to: to), reference.segments(from: from, to: to),
          "\(string.prefix(20)) の \(from)..<\(to)")
      }
    }
    for string in ["é", "a😀", "ab שלום"] {
      XCTAssertFalse(
        LineShaper.shape(source(string), font: font, tabWidth: tab).simple, "\(string.prefix(8))")
    }
    let proportional = NSFont.systemFont(ofSize: 12) as CTFont
    XCTAssertFalse(
      LineShaper.shape(source("let x = 1"), font: proportional, tabWidth: tab).simple,
      "等幅でないフォントは Core Text に数えさせる")
  }

  /// 右から左の字を挟む選択は、見た目の区間ごとに分かれる——`ab שלום cd` の ש ל（位置 3〜5）は右から左の並びの右側、
  /// 並び全体は 1 つの区間、左から右の字だけなら 1 つの区間。
  func testSelectionSegmentsSplitAroundRightToLeftRuns() {
    let map = LineShaper.shape(source("ab שלום cd"), font: font, tabWidth: 0).carets
    XCTAssertGreaterThan(map.x(4), map.x(5), "右から左の並びの中は位置が進むと左へ")
    let hebrew = map.segments(from: 3, to: 5)
    XCTAssertEqual(hebrew.count, 1)
    XCTAssertEqual(hebrew.first?.lowerBound ?? -1, map.x(5), accuracy: 0.01)
    XCTAssertGreaterThan(hebrew.first?.upperBound ?? 0, map.x(4))
    let crossing = map.segments(from: 1, to: 5)
    XCTAssertEqual(crossing.count, 2, "b と空白、ש ל は離れた 2 つの区間")
    XCTAssertEqual(map.segments(from: 0, to: 2).count, 1)
    XCTAssertEqual(map.segments(from: 0, to: 10).count, 1, "行全体は 1 つ")
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
    let thai = String(repeating: "a", count: 9_999) + "กำ" + String(repeating: "b", count: 100)
    let thaiLine = LineShaper.source(row: 0, in: TextRope(thai)).source
    XCTAssertEqual(LineShaper.display(thaiLine).units.count, 9_999, "タイ語の SARA AM も書記素ごと")
  }

  /// 組んだ字は元の行の位置を持つ（色を役割から引くため）。
  func testGlyphsCarryTheirOffsets() {
    let shaped = LineShaper.shape(source("let 日本"), font: font, tabWidth: cell * 4)
    let offsets = shaped.runs.flatMap(\.offsets)
    XCTAssertEqual(offsets, [0, 1, 2, 3, 4, 5])
  }
}
