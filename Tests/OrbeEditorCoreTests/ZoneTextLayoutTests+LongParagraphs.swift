import AppKit
import XCTest

@testable import OrbeEditorCore

/// 長い段落（区切って組む段落と、Core Text が既定で簡略に組む約 10,000 字を超える段落）の組み方——行は段落を丸ごと
/// 組んだときと同じで、段落の向きは長さに依らない。壊れると、長いコメントの本文の折り返しや並びが区切りの位置や段落の長さで
/// 変わる（絵文字の連なりが割れる・タイ語が 1 字ずつ割れる・右から左の段落が左から右で組まれる・長いコードの向きが変わる）。
extension ZoneTextLayoutTests {
  /// 区切って組んだ長い段落の行（範囲・幅・グリフの x）は、段落を区切らずに丸ごと組んだ行と同じ——コード・和文・アラビア文字・
  /// ヘブライ文字の文・右から左の段落・区切りをまたぐ長いコード・タイ語・ラオ語・ZWJ でつないだ絵文字・段落の頭で開いて
  /// 閉じない isolate と埋め込みと上書き・割れない長い語・中立の字が区切りより長く続く段落・行の頭より前のヘブライ文字が
  /// 数字の向きを決める段落のどれでも。
  func testLongParagraphsBreakWhereTheWholeParagraphBreaks() {
    let inputs: [LongParagraph] = [
      LongParagraph("latin+code", [("word and more ", false), ("code", true), (" ", false)]),
      LongParagraph("japanese+code", [("日本語の文を書いて折り返す", false), ("x1", true), ("。", false)]),
      LongParagraph("arabic+latin", [("مرحبا بالعالم 0 hello ", false)]),
      LongParagraph("hebrew+code", [("שלום עולם 1 ", false), ("ab1", true), (" world ", false)]),
      LongParagraph("thai", [("ภาษาไทยไม่มีช่องว่าง", false)]),
      LongParagraph("lao", [("ພາສາລາວບໍ່ມີຍະຫວ່າງ", false)]),
      LongParagraph("emoji", [("👩‍👩‍👧‍👦 ", false), ("🏳️‍🌈", true)]),
      LongParagraph("open isolate", [("שלום 1 abc ", false)], head: "\u{2067}"),
      LongParagraph("open embedding", [("word 12 مرحبا 3.5 。", false)], head: "\u{202B}"),
      LongParagraph("override", [("abc 123 。( x ) ", false)], head: "\u{202E}"),
      LongParagraph("one long token", [("x", false)]),
      LongParagraph("hebrew text", [("שלום עולם זה משפט ארוך ", false)]),
      LongParagraph("arabic text", [("مرحبا بالعالم هذه جملة طويلة ", false)]),
      LongParagraph("alef", [("א ", false)]),
      LongParagraph(
        "long code in rtl",
        [("שלום ", false), ("א " + String(repeating: "ab ", count: 2_000), true)]),
      LongParagraph("neutral then hebrew", [("1 ", false)], head: "", tail: "שלום"),
      LongParagraph(
        "digits after hebrew", [("שלום ", false), ((0..<100).map { "\($0) " }.joined(), false)],
        head: "a "),
    ]
    let lines = { (typeset: ZoneTypeset) in
      typeset.lines.map { "\($0.range) \($0.width) \($0.runs.map(\.xs))" }
    }
    for input in inputs {
      let text = input.text(length: 12_000, plain: plain, code: code)
      for width in [120.0, 600] {
        XCTAssertEqual(
          lines(ZoneTextLayout.typeset(text, width: width)),
          lines(ZoneTextLayout.typeset(text, width: width, window: 1 << 20)),
          "\(input.name) 幅 \(width)")
      }
    }
  }

  /// 約 10,000 字を超える段落でも、段落の向きは最初の向きを持つ字で決まる——ヘブライ文字で始まる段落と、中立の字が区切り
  /// より長く続いた後にヘブライ文字が来る段落の行は、右から左の段落の行として組まれ（行の頭の字が行の右端に来る）、区切り
  /// より長い isolate の中のヘブライ文字の後にラテン文字が来る段落は左から右の段落として、区切りより長い isolate の中の
  /// ラテン文字の後にヘブライ文字が来る段落は右から左の段落として組まれる（isolate の中の字は段落の向きを決めない）。
  func testALongParagraphKeepsTheDirectionOfItsFirstStrongCharacter() {
    let cases: [(String, Bool)] = [
      ("א " + String(repeating: "word ", count: 2_200), true),
      (String(repeating: "1 ", count: 5_500) + "שלום", true),
      ("\u{2067}" + String(repeating: "שלום ", count: 2_200) + "\u{2069} word", false),
      ("\u{2067}" + String(repeating: "word ", count: 2_200) + "\u{2069} שלום", true),
    ]
    for (source, rightToLeft) in cases {
      let typeset = ZoneTextLayout.typeset(ZoneStyledText([(source, plain)]), width: 300)
      let first = typeset.lines[0]
      XCTAssertGreaterThan(source.utf16.count, 10_240, "前提: Core Text が既定で簡略に組む長さ")
      XCTAssertEqual(
        first.x(of: first.range.location) > first.width / 2, rightToLeft,
        "行の頭の字が右端の側にあるか: \(source.prefix(8))")
    }
  }

  /// 区切りより長い割れない塊（右から左の字に結合記号を続けた 1 字）は、区切りを広げずに区切りの終わりで割る——行は 2 行
  /// 以上になり、行の範囲が文を隙間なく覆う。
  func testAClusterLongerThanTheWindowIsCutAtTheWindow() {
    let source = "א" + String(repeating: "\u{05B0}", count: 20_000)
    let lines = ZoneTextLayout.typeset(ZoneStyledText([(source, plain)]), width: 300).lines
    XCTAssertGreaterThanOrEqual(lines.count, 2)
    var next = 0
    for line in lines {
      XCTAssertEqual(line.range.location, next, "行の範囲は前の行の終わりから")
      next = NSMaxRange(line.range)
    }
    XCTAssertEqual(next, source.utf16.count, "行の範囲は文の終わりまで")
  }

  /// 区切って組む長い段落で、行を組む文の頭（行の頭の 512 字前）がコードの中の結合記号に当たっても、コードの境にある字の
  /// 塊は割れない——余白の有無でグリフの数が変わらない。壊れると、その区切りで組む行のどこかで、本文の `e` とコードの頭の
  /// 結合記号が別々のグリフに描かれる。
  func testAHeadInsideACodeClusterDoesNotSplitClusters() {
    var split: [Int] = []
    // 段落の頭の a の数で区切りの位置をずらす（24 と 27 で、行を組む文の頭がコードの中の結合記号に当たる）。
    for shift in 22..<28 {
      var parts = [String(repeating: "a", count: shift) + " "]
      var codes: [Int] = []
      for k in 0..<500 {
        let filler = String(repeating: "y", count: (k * (shift + 1)) % 9)
        parts.append(k % 3 == 0 ? "word\(filler) \(k) e" : "tx \(k) e")
        codes.append(parts.count)
        parts.append("\u{0301}\u{0323}\u{0308}cd\(k)" + (k % 2 == 0 ? "e" : ""))
        parts.append(k % 2 == 0 ? "\u{0301}\u{0323}\u{0308} " : " ")
      }
      let glyphs = [0, 4].map { padding in
        ZoneTextLayout.typeset(styled(parts, codes: codes, padding: padding), width: 300).lines
          .reduce(0) { $0 + glyphCount($1) }
      }
      if glyphs[0] != glyphs[1] { split.append(shift) }
    }
    XCTAssertEqual(split, [], "字の塊を割った、段落の頭の a の数")
  }

  private var plain: ZoneTextStyle { ZoneTextStyle(font: font, color: .white) }
  private var code: ZoneTextStyle { ZoneTextStyle(font: mono, color: .red, padding: 4) }
}

/// 長い段落の入力——段落の頭の字 `head` の後に、字の連なり（コードか）の組 `unit` を繰り返し、`tail` で終える。
private struct LongParagraph {
  let name: String
  let unit: [(String, Bool)]
  let head: String
  let tail: String

  init(_ name: String, _ unit: [(String, Bool)], head: String = "", tail: String = "") {
    self.name = name
    self.unit = unit
    self.head = head
    self.tail = tail
  }

  /// `length` 字ほどの段落。
  func text(length: Int, plain: ZoneTextStyle, code: ZoneTextStyle) -> ZoneStyledText {
    var parts: [(String, ZoneTextStyle)] = [(head, plain)]
    var count = head.utf16.count
    while count < length {
      for part in unit {
        parts.append((part.0, part.1 ? code : plain))
        count += part.0.utf16.count
      }
    }
    return ZoneStyledText(parts + [(tail, plain)])
  }
}
