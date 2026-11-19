import AppKit
import XCTest

@testable import OrbeEditorCore

/// 長い段落（区切って割る位置を探す段落と、Core Text が既定で簡略に組む約 10,000 字を超える段落）の組み方——割る位置は
/// 段落を丸ごと探したときと同じで、段落の向きは長さに依らない。壊れると、長いコメントの本文の折り返しが区切りの位置や
/// 段落の長さで変わる（絵文字の連なりが割れる・タイ語が 1 字ずつ割れる・右から左の段落が左から右で組まれる）。
extension ZoneTextLayoutTests {
  /// 区切って探した割る位置は、段落を区切らずに探した位置と同じ——コード・和文・アラビア文字・右から左の段落・タイ語・
  /// ラオ語・ZWJ でつないだ絵文字・段落の頭で開いて閉じない isolate と埋め込みと上書き・割れない長い語のどれでも。
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
    ]
    for input in inputs {
      var parts: [(String, ZoneTextStyle)] = [(input.head, plain)]
      var count = input.head.utf16.count
      while count < 12_000 {
        for part in input.unit {
          parts.append(
            (part.0, part.1 ? ZoneTextStyle(font: mono, color: .red, padding: 4) : plain))
          count += part.0.utf16.count
        }
      }
      let text = ZoneStyledText(parts)
      for width in [120.0, 600] {
        XCTAssertEqual(
          ZoneTextLayout.typeset(text, width: width).lines.map(\.range),
          ZoneTextLayout.typeset(text, width: width, window: 1 << 20).lines.map(\.range),
          "\(input.name) 幅 \(width)")
      }
    }
  }

  /// 約 10,000 字を超える段落でも、段落の向きは最初の向きを持つ字で決まる——ヘブライ文字で始まる段落の行は、右から左の
  /// 段落の行として組まれる（行の頭の字が行の右端に来る）。
  func testALongParagraphKeepsTheDirectionOfItsFirstStrongCharacter() {
    let source = "א " + String(repeating: "word ", count: 2_200)
    let typeset = ZoneTextLayout.typeset(ZoneStyledText([(source, plain)]), width: 300)
    let first = typeset.lines[0]
    XCTAssertGreaterThan(source.utf16.count, 11_000, "前提: Core Text が既定で簡略に組む長さ")
    XCTAssertGreaterThan(first.x(of: first.range.location), first.width / 2, "行の頭の字は右端の側")
  }

  private var plain: ZoneTextStyle { ZoneTextStyle(font: font, color: .white) }
}

/// 長い段落の入力——段落の頭の字 `head` の後に、字の連なり（コードか）の組 `unit` を繰り返す。
private struct LongParagraph {
  let name: String
  let unit: [(String, Bool)]
  let head: String

  init(_ name: String, _ unit: [(String, Bool)], head: String = "") {
    self.name = name
    self.unit = unit
    self.head = head
  }
}
