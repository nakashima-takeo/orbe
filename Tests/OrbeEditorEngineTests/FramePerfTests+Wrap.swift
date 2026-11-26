import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 折り返す面のスクロールと打鍵の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。ほかの場面の
/// 面も、コードの構成（折り返す）で開く——ここには、折り返すと段が多くなる本文を足す。
extension FramePerfTests {
  /// 1 行が 2,000 字級の日本語の Markdown の段落が並ぶ文書のスクロール。関門は ASCII の Swift と同じ（1 コマの CPU の p99
  /// 2ms 未満、描画スレッド自身が落とすコマ 0）——折り返した段は区画の幅で短く切れるので、長い行を 1 行まるごと組まない。
  func testWrappedLongParagraphs() throws {
    _ = try measure(
      label: "wrapped-paragraphs", text: Self.paragraphs(length: 2_000, bytes: 200_000))
  }

  /// 数千字の日本語の段落の途中で打つ。関門は `testTyping` と同じ（打鍵→present の中央値 12.5ms・p95 17ms、打鍵 1 回の
  /// main の仕事 p99 1ms）——打鍵のたびに、打った行の折り返しを main が計算し直す。
  func testTypingInALongWrappedParagraph() throws {
    let opened = try attach(Self.paragraphs(length: 5_000, bytes: 200_000))
    let text = opened.document.text
    let row = text.lineCount / 2
    _ = gateStrokes(
      opened, scenario: "typing", label: "wrapped-paragraph",
      caret: text.lineStart(row) + text.contentRange(ofRow: row).length / 2, stroke: Self.type)
  }

  /// 1 行がおよそ `length` 字の日本語と英数字の段落を、`bytes` を超えるまで並べた文書（段落ごとに中身を変える）。
  static func paragraphs(length: Int, bytes: Int) -> String {
    let phrases = [
      "テキスト面は、行ごとの折り返しを縦の並びに載せる。", "The wrap width is the text area minus one cell. ",
      "続きの段は、行頭の空白の幅だけ字下げする（`wrappingIndent`）。", "句読点と閉じ括弧は段の頭に来ない。",
      "`LineWrap.wrap(_:_:)` は字ごとの幅を足して段を分ける。", "1MB の文書でも、全部の行を同期で計算する。",
    ]
    var text = ""
    var row = 0
    while text.utf8.count < bytes {
      var line = "\(row). "
      var k = row
      while line.count < length {
        line += phrases[k % phrases.count]
        k = (k * 31 + 7) % 1_000_003
      }
      text += line + "\n\n"
      row += 1
    }
    return text
  }
}
