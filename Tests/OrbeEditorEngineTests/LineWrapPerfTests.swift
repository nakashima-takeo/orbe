import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 行の折り返しの時間の計測（main の CPU 時間）。`ORBE_EDITOR_PERF=1` のときだけ走る（時間はマシンで変わる）。release で
/// `scripts/perf-editor-frames.sh` が回し、`PERF-WRAP` の行を出す。関門: 1 万字の行 1 本の折り返し 0.2ms 以下、上限
/// （UTF-8 のバイト数）の前後の文書で幅を変えた 1 回の main の仕事（全部の行の折り返しを含む）16ms 以下（書式文字の密度を
/// 上限に置いた本文は 33ms 以下）、字ごとの字体と幅の表が空のときに、字の種類が 1,000 前後の日本語の Markdown の全部の行を
/// 折り返す 50ms 以下。
@MainActor
final class LineWrapPerfTests: EngineTestCase {
  private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) as CTFont

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  private func metrics(_ font: CTFont, width: CGFloat = 900) -> LineWrap.Metrics {
    let cell = LineShaper.shape(" ", font: font).width
    return LineWrap.Metrics(font: font, width: width, tabWidth: 4 * cell) { _ in 8 * cell }
  }

  /// 全部の行の折り返しを、字の量を変えた文書で測る（上限を決める値）。本文は ASCII の Swift と、日本語の Markdown（spec の
  /// 写し）。5 回測った CPU 時間の中央値。
  func testWrappingTheWholeDocument() throws {
    let metrics = metrics(font)
    let markdown = try FramePerfTests.copies(of: "docs/spec/editor/code.md", bytes: 12_000_000)
    for (label, source) in [
      ("ascii-swift", FramePerfTests.swiftSource(bytes: 4_000_000)),
      ("japanese-markdown", markdown),
    ] {
      for units in [500_000, 1_000_000, 2_000_000, 3_000_000] {
        let text = TextRope(String((source as NSString).substring(to: units)))
        _ = LineWrap.wrap(rows: 0..<text.lineCount, in: text, metrics)
        let ms = Self.median(5) { _ = LineWrap.wrap(rows: 0..<text.lineCount, in: text, metrics) }
        print(
          "PERF-WRAP whole", label, "units", units, "lines", text.lineCount, "cpu-ms p50",
          String(format: "%.2f", ms))
      }
    }
  }

  /// 1 万字の行 1 本（打鍵のたびに走る計算）。ASCII と日本語。
  func testWrappingALongLine() {
    let metrics = metrics(font)
    for (label, line) in [
      ("ascii", String(repeating: "word ", count: 2_000)),
      ("japanese", String(repeating: "日本語の文と English の語。", count: 500)),
    ] {
      let text = TextRope(line)
      _ = LineWrap.wrap(rows: 0..<1, in: text, metrics)
      let ms = Self.median(41) { _ = LineWrap.wrap(rows: 0..<1, in: text, metrics) }
      print(
        "PERF-WRAP long-line", label, "units", text.length, "cpu-ms p50", String(format: "%.3f", ms)
      )
      XCTAssertLessThanOrEqual(ms, 0.2, "\(label): 1 万字の行 1 本の折り返し")
    }
  }

  /// 字ごとの字体と幅の表が空のとき（この計測でしか使わない大きさの字体）に、日本語の Markdown の全部の行を折り返す。
  func testWrappingWithAnEmptyTable() throws {
    let fresh = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) as CTFont
    let text = TextRope(try FramePerfTests.copies(of: "docs/spec/editor/code.md", bytes: 200_000))
    let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    _ = LineWrap.wrap(rows: 0..<text.lineCount, in: text, metrics(fresh))
    let ms = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1e6
    let kinds = Set(text.substring(NSRange(location: 0, length: text.length))).count
    print("PERF-WRAP empty-table kinds", kinds, "cpu-ms", String(format: "%.2f", ms))
    XCTAssertLessThanOrEqual(ms, 50, "表が空のときの全部の行の折り返し")
  }

  /// 上限（UTF-8 のバイト数）の前後の大きさの文書で、窓の幅を変えた 1 回の main の仕事（取引の確定で全部の行を折り返し
  /// 直す）。本文は日本語の Markdown（spec の写し。字の量あたりの手間がいちばん重い）と、ASCII の Swift と、書式文字（箱で
  /// 見せる U+200E）が字の 3 つに 1 つを占める本文で、上限の半分・すぐ下・すぐ上の大きさ。すぐ上の文書は折り返さない。
  /// 関門は 16ms。書式文字の本文だけは 33ms（2 コマ）——今の作りで、上限のすぐ下が 1 コマをわずかに越える。守るのは、
  /// 箱の幅を組まずに ASCII の字の幅の和で引き、箱と ASCII だけの行で字ごとの字体と幅の表を引かないこと。
  func testResizingDocumentsAroundTheLimit() throws {
    let limit = MetalTextSurface.wrapLimit
    let scenes = [
      (
        "japanese-markdown",
        try FramePerfTests.copies(of: "docs/spec/editor/code.md", bytes: limit * 2)
      ),
      ("ascii-swift", FramePerfTests.swiftSource(bytes: limit * 2)),
      (
        "format-characters",
        String(
          repeating: String(repeating: "ab\u{200E}", count: 30) + "\n", count: limit * 2 / 150)
      ),
    ]
    for (label, source) in scenes {
      for bytes in [limit / 2, limit - 1_000, limit + 1_000] {
        let text = Self.prefix(source, bytes: bytes)
        let opened = try open(text, name: "a.txt", size: CGSize(width: 1200, height: 800))
        let surface = opened.surface
        XCTAssertEqual(surface.rows.wraps != nil, bytes <= limit, "前提: 上限までの文書だけ折り返す")
        var times: [Double] = []
        for step in 0..<11 {
          let width = CGFloat(1200 - (step % 2) * 40)
          let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
          surface.viewStateDidChange(
            size: CGSize(width: width, height: 800), scale: 2, visible: false)
          times.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1e6)
        }
        let median = times.dropFirst().sorted()[times.count / 2 - 1]
        print(
          "PERF-WRAP resize", label, "bytes", text.utf8.count, "units", text.utf16.count,
          "wraps", surface.rows.wraps != nil, "cpu-ms p50", String(format: "%.2f", median), "max",
          String(format: "%.2f", times.dropFirst().max() ?? 0))
        XCTAssertLessThanOrEqual(
          median, label == "format-characters" ? 33 : 16,
          "\(label) \(bytes) バイト: 幅を変えた 1 回の main の仕事")
      }
    }
  }

  /// `text` の先頭から、UTF-8 で `bytes` バイトを超えない最も長い部分。
  private static func prefix(_ text: String, bytes: Int) -> String {
    var end = text.utf8.index(text.utf8.startIndex, offsetBy: min(bytes, text.utf8.count))
    while end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
    return String(text[..<end])
  }

  /// `body` を `count` 回走らせた CPU 時間（ms）の中央値。
  private static func median(_ count: Int, _ body: () -> Void) -> Double {
    var samples: [Double] = []
    for _ in 0..<count {
      let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      body()
      samples.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1e6)
    }
    return samples.sorted()[count / 2]
  }
}
