import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 日本語の本文のスクロールと打鍵の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。本文は、
/// 日本語のコメントの多いコード、和文の後ろに本体の字体に無い記号（`※★◐` など）がある行が並ぶ文書、数千字の行を含む
/// 日本語の Markdown。コードと Markdown はこのリポジトリのファイルを、行ごとに写しの番号を足して 200KB まで並べる（同じ
/// 中身の行は組み直さないので、写しごとに中身を変える）。
extension FramePerfTests {
  /// 日本語のコメントの多いコード（1 行 100 字前後まで）。関門は ASCII の Swift と同じ。
  func testJapaneseCommentedCode() throws {
    _ = try measure(
      label: "japanese-comments",
      text: Self.copies(of: "Sources/OrbeEditorCore/Surface/ZoneTextLayout.swift", bytes: 200_000))
  }

  /// 和文の後ろに本体の字体に無い記号がある行が並ぶ文書。関門は ASCII の Swift と同じ。
  func testSymbolsAfterJapanese() throws {
    _ = try measure(
      label: "symbols-after-japanese", text: Self.symbolsAfterJapanese(bytes: 200_000))
  }

  /// 数千字の行を含む日本語の Markdown を、折り返さない面で（差分の面と、上限を越えた文書の場面）。長い行は 1 行まるごと
  /// 組むので、`testLongLines` と同じく、全部のコマの CPU の p99 は 1 刻み未満だけを関門にし、描画スレッド自身が落とす
  /// コマは記録して示すだけ。
  func testLongJapaneseMarkdown() throws {
    _ = try measure(
      label: "long-japanese-markdown",
      text: Self.copies(of: "docs/design/design-system.md", bytes: 200_000), wraps: false,
      frameLimit: HeadlessDriver.period * 1000, gatesLateCommits: false)
  }

  /// 同じ日本語の Markdown を、折り返す面で。組むのは見えている段だけなので、関門は ASCII の Swift と同じ。
  func testLongJapaneseMarkdownWrapped() throws {
    _ = try measure(
      label: "long-japanese-markdown wrapped",
      text: Self.copies(of: "docs/design/design-system.md", bytes: 200_000))
  }

  /// 和文の後ろに本体の字体に無い記号がある行の途中で打つ。関門は `testTyping` と同じ（打鍵→present の中央値 12.5ms・
  /// p95 17ms、打鍵 1 回の main の仕事 p99 1ms）。
  func testTypingAfterJapaneseSymbols() throws {
    let opened = try attach(Self.symbolsAfterJapanese(bytes: 200_000))
    _ = gateStrokes(
      opened, scenario: "typing", label: "symbols-after-japanese", stroke: Self.type)
  }

  /// このリポジトリのファイル `path` の行に、写しの番号を足して、`bytes` を超えるまで並べた本文。
  static func copies(of path: String, bytes: Int) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lines = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
      .components(separatedBy: "\n")
    var text = ""
    var copy = 0
    while text.utf8.count < bytes {
      copy += 1
      for line in lines { text += line.isEmpty ? "\n" : "\(line) \(copy)\n" }
    }
    return text
  }

  /// 和文の後ろに本体の字体に無い記号が 1 行に平均 5〜6 個ある行（60〜130 字）を、`bytes` を超えるまで並べた文書。
  static func symbolsAfterJapanese(bytes: Int) -> String {
    let phrases = [
      "注意※ 行の型の地は行の全部の段に出る。", "設定★を変えると、", "状態◐の印が替わる（切替⇄）。",
      "`RowLayout` の行の高さは段の数で決まる。", "結論⇒ 折り返しの幅は区画の幅から半角 1 字を引く。",
      "温度は 23℃ のまま、", "記号◆の後ろの字も和文の字体で出る。", "日本語の文の途中の※と★。",
    ]
    var text = ""
    var row = 0
    while text.utf8.count < bytes {
      var line = "- \(row) "
      var k = row
      while line.count < 60 + row % 5 * 10 {
        line += phrases[k % phrases.count]
        k = (k * 31 + 7) % 1_000_003
      }
      text += line + "\n"
      row += 1
    }
    return text
  }
}
