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
