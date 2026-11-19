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
        for line in ZoneTextLayout.lines(
          styled(parts, codes: codes, padding: padding), width: width)
        {
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
        ZoneTextLayout.lines(styled(parts, padding: padding), width: width).contains {
          $0.width > width + 0.001
            && CTTypesetterSuggestLineBreak(bare, $0.range.location, 0) != $0.range.length
        }
      }
      XCTAssertEqual(over, [], "\(string) を折り返すと、縮められるのに幅を超える行が出る幅")
    }
  }
}
