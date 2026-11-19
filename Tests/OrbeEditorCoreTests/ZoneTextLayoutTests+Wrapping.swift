import AppKit
import CoreText
import XCTest

@testable import OrbeEditorCore

/// 余白のある見え方の段落を割る位置と行の幅——割る位置は余白を付けないときに割れる位置だけで、行は幅に収まる。壊れると、
/// 「`String`s」のコードの外の語の続きや禁則の字の前で割れたり、余白のせいで行が絵の差し込みの幅をはみ出したりする。
extension ZoneTextLayoutTests {
  /// 行を割る位置は、余白を付けないときに割れる位置だけ——どの行の境も、その行の頭から余白なしで組むと、どれかの幅で割れる
  /// 位置。コードの外に語が続く文（「`String`s」「`nil`able」「`foo`-based」「re`build`」）・和文の直後のコード・「」。の
  /// 禁則・乱択で混ぜた文のどれでも、ほかの位置では割らない。
  func testLinesBreakOnlyWhereTheTextWithoutPaddingBreaks() {
    var cases: [([String], [Int])] = [
      (["あいうえお", "code", "かきくけこ"], [1]), (["これは", "a", "と", "b", "と", "c", "です。"], [1, 3, 5]),
      (["あいうえお「", "code", "」。かきく"], [1]), (["see the ", "code", " and then more words"], [1]),
      (["aaaa bbbb cccc dddd ", "String", "s are values"], [1]),
      (["several ", "Int", "s and ", "nil", "able values here"], [1, 3]),
      (["use the ", "foo", "-based one"], [1]), (["now re", "build", " it again"], [1]),
    ]
    var random = SplitMix(seed: 3)
    let words = ["see", " ", "the", "-", "あいう", "。", "「", "」", "אבג", "x"]
    for _ in 0..<200 {
      let parts = (0..<(3 + random.next(8))).map { _ in
        words[random.next(words.count)] + words[random.next(words.count)]
      }
      cases.append((parts, parts.indices.filter { _ in random.next(3) == 0 }))
    }
    var wrong: [String] = []
    for (index, (parts, codes)) in cases.enumerated() {
      let string = parts.joined()
      let units = Array(string.utf16)
      let bare = bareTypesetter(parts, codes: codes)
      for width in stride(from: CGFloat(20), through: 260, by: index < 8 ? 1.5 : 30) {
        for line in ZoneTextLayout.typeset(
          styled(parts, codes: codes, padding: padding), width: width
        ).lines {
          let end = NSMaxRange(line.range)
          guard end < units.count, units[end] != 0x0A else { continue }
          if !breaks(bare, count: units.count, from: line.range.location, at: end) {
            wrong.append("\(string) を幅 \(width) で割った行 \(line.range)")
          }
        }
      }
    }
    XCTAssertEqual(wrong.prefix(5), [])
  }

  /// 折り返した行は渡した幅に収まる——和文と、右から左の字のインラインコードが同じ行にあっても。幅を超えるのは、余白なしで
  /// 幅 0 に組んだときの最小の塊（字 1 つなど）だけの行（割れない塊と余白が幅に入らない）。
  func testWrappedLinesFitTheWidthUnlessTheyHoldOneUnbreakablePiece() {
    for parts in [
      ["see the ", "קוד ארוך", " and more words here"],
      ["הריצו את ", "git commit -m", " ואז את זה"],
      ["これは", "קוד ארוך", "の例です。続きの文もある"], ["和文の後に ", "שלום עולם", " と続く和文の段落"],
      ["abc ", "longcodeword", " tail"], ["あいうえお「", "code", "」。かきく"],
    ] {
      let string = parts.joined()
      let bare = bareTypesetter(parts, codes: [1])
      let over = stride(from: CGFloat(5), through: 200, by: 0.5).filter { width in
        ZoneTextLayout.typeset(styled(parts, padding: padding), width: width).lines.contains {
          $0.width > width + 0.001
            && CTTypesetterSuggestLineBreak(bare, $0.range.location, 0) != $0.range.length
        }
      }
      XCTAssertEqual(over, [], "\(string) を折り返すと、縮められるのに幅を超える行が出る幅")
    }
  }

  /// 右から左の語を途中で割った行の、分け目の前の字の置き場所の現状——Core Text は段落を 1 回組んだグリフの並びから行を
  /// 切り出すので、分け目をまたぐ字の組み合わせの詰め（字体の kern）が残り、分け目の前の字がその量だけ寄る（余白の有無と
  /// 絵の差し込みに依らない。`docs/spec/editor/code.md` の「テキストエンジンの境界」）。この行では、ر が次の行へ送った ح
  /// との詰めの分（SF の 12pt で 0.41pt）コードの地にかぶる。寄らないことの検証を `XCTExpectFailure`（期待する失敗）で
  /// 包む——Core Text が分け目をまたぐ詰めを残さなくなればこの期待が外れてテストが落ち、spec の現状とこの期待の書き直しを
  /// 知らせる。
  func testTheGlyphBeforeABreakInARightToLeftWordKeepsTheKerningAcrossTheBreak() throws {
    let parts = ["see the", "קוד", "مرحبا بكم"]
    let codeEnd = parts[0].utf16.count + parts[1].utf16.count
    let lines = ZoneTextLayout.typeset(styled(parts, padding: padding), width: 60).lines
    let line = try XCTUnwrap(
      lines.first { NSMaxRange($0.range) > codeEnd && NSMaxRange($0.range) < codeEnd + 5 },
      "前提: コードの後ろのアラビア語の語「مرحبا」を途中で割った行がある")
    let ground = try XCTUnwrap(line.spans(of: 1).first, "前提: 行にコードの地がある")
    let word = try XCTUnwrap(glyphs(of: 2, in: line), "前提: 行に分け目の前のアラビア語の字がある")
    let overlap = min(ground.upperBound, word.upperBound) - max(ground.lowerBound, word.lowerBound)
    XCTExpectFailure(
      "現状: 分け目をまたぐ字体の詰めが残り、分け目の前の字が詰めの分だけ寄る（code.md の「テキストエンジンの境界」）"
    ) {
      XCTAssertLessThanOrEqual(overlap, 0.01, "分け目の前の字はコードの地にかぶらない")
    }
  }

  /// 区切って組む長い段落でも、行は隙間なく続いて段落を覆い、どの行も幅に収まり、区切りの境で語の途中を割らない（語の
  /// 途中で割れるのは、幅に入らない語だけ）。壊れると、長いコメントの本文の字が欠けたり、区切りの位置で行が不自然に割れる。
  func testALongParagraphIsTypesetInPartsWithoutGapsOrExtraBreaks() {
    let word = "word "
    let source = String(repeating: word, count: 3_000) + "end"
    let style = ZoneTextStyle(font: NSFont.systemFont(ofSize: 12), color: .labelColor)
    let typeset = ZoneTextLayout.typeset(ZoneStyledText([(source, style)]), width: 200)
    var next = 0
    for line in typeset.lines {
      XCTAssertEqual(line.range.location, next, "行は隙間なく続く")
      XCTAssertLessThanOrEqual(line.width, 200)
      XCTAssertEqual(line.range.location % word.utf16.count, 0, "語の頭から始まる")
      next = NSMaxRange(line.range)
    }
    XCTAssertEqual(next, source.utf16.count, "段落を覆う")
  }
}
