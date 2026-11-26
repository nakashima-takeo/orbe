import AppKit
import XCTest

@testable import OrbeEditorEngine

/// 行の組版（`LineShaper.shape`）の時間の計測。本文は次の 4 つ。(1) ASCII の字だけの Swift。(2) 和文と英数字が混ざる
/// 日本語の Markdown。(3) (2) のどの行にも、和文の字の後ろに本体の字体に無い記号（`※`）を 1 つ足した文。(4) 和文の字の
/// 後ろに本体の字体に無い記号（`※★◐` など）が平均 8〜9 字ごとに来る文。本文を 1 度ずつ組んだ後（初めて出た字を表に覚え、
/// 代替フォントを読み込ませる）、交互に 15 回組み、本文ごとの CPU 時間（ms）の中央値を出す。`ORBE_EDITOR_PERF=1` の
/// ときだけ走る（時間はマシンで変わる）。release で回し、`PERF-SHAPE` の行を出す。関門は持たず、値を変更の前後で比べる。
@MainActor
final class LineShaperPerfTests: XCTestCase {
  private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) as CTFont

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  func testShapingTime() {
    let scenes: [(label: String, lines: [LineShaper.Source])] = [
      ("ascii-swift", Self.lines(FramePerfTests.swiftSource(bytes: 200_000))),
      ("japanese-markdown", Self.lines(Self.japaneseMarkdown(lines: 900))),
      ("symbol-once-after-japanese", Self.lines(Self.symbolOnceAfterJapanese(lines: 900))),
      ("symbols-after-japanese", Self.lines(Self.symbolsAfterJapanese(lines: 900))),
    ]
    let tab = LineShaper.shape(LineShaper.source(" "), font: font, tabWidth: 0).width * 4
    var times = scenes.map { _ in [Double]() }
    for round in 0..<16 {
      for (index, scene) in scenes.enumerated() {
        let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for line in scene.lines { _ = LineShaper.shape(line, font: font, tabWidth: tab) }
        let ms = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1e6
        if round > 0 { times[index].append(ms) }
      }
    }
    for (scene, samples) in zip(scenes, times) {
      let units = scene.lines.reduce(0) { $0 + $1.length }
      print(
        "PERF-SHAPE", scene.label, "lines", scene.lines.count, "units", units, "cpu-ms p50",
        String(format: "%.2f", samples.sorted()[samples.count / 2]))
    }
  }

  private static func lines(_ text: String) -> [LineShaper.Source] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map {
      LineShaper.source(String($0))
    }
  }

  /// 和文と英数字・コードの字が混ざる、`lines` 行の日本語の Markdown（本体の字体に無い記号を、和文の字の後ろに置かない）。
  static func japaneseMarkdown(lines: Int) -> String {
    let words = [
      "テキスト面は", "`RowLayout` の", "行の高さを", "縦の並びに載せ、", "描画スレッドが", "引き取った版の",
      "並びで描く。", "文書の行", "`r` の上端は", "差し込みの高さの合計", "（行高 18pt）", "になる。",
      "Core Text は", "代替フォントを", "選んで組む", "「段」と「付き」", "を持つ。", "1MB の文書で",
      "6ms かかる", "ことを確かめた。", "`LineShaper.shape(source, font:)`", "は純関数で、",
    ]
    return (0..<lines).map { row in
      var line = row % 7 == 0 ? "## 見出し \(row)" : "- "
      var k = row
      while line.utf16.count < 40 + row % 5 * 30 {
        line += words[k % words.count]
        k = (k * 31 + 7) % 1_000_003
      }
      return line
    }.joined(separator: "\n")
  }

  /// `japaneseMarkdown(lines:)` が作る文のどの行にも、和文の字の後ろに `※` を 1 つ足した文。
  static func symbolOnceAfterJapanese(lines: Int) -> String {
    japaneseMarkdown(lines: lines).split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0 + "（注意※を参照）" }.joined(separator: "\n")
  }

  /// どの行も、和文の字の後ろに本体の字体に無い記号が平均 8〜9 字ごとに来る `lines` 行の文。
  static func symbolsAfterJapanese(lines: Int) -> String {
    let words = [
      "注意※", "設定★", "状態◐", "切替⇄", "記号◆", "結論⇒", "温度℃", "行の型の地を敷く。",
      "`code` を含む", "和文の後ろに", "記号が来る。", "（全角の括弧）",
    ]
    return (0..<lines).map { row in
      var line = "- "
      var k = row
      while line.utf16.count < 40 + row % 5 * 30 {
        line += words[k % words.count]
        k = (k * 31 + 7) % 1_000_003
      }
      return line
    }.joined(separator: "\n")
  }
}
