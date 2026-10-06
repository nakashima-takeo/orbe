import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 差し込みの多い面の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。ミニマップを出さない
/// 1MB・200KB に、10 行ごとに差し込み（文書に無い行 2 行と、高さ 40pt の区画を交互に。1MB で約 4,300）を置き、指の
/// ドラッグ・はじき・端への引っ張りを流す。関門は本文だけのときと同じ（1 コマの CPU の p99 2ms 未満・描画スレッド自身が
/// 落とすコマ 0・main に負荷を入れても・1MB の中央値が 200KB の 2 倍以内）。行の増える打鍵 1 回の main の仕事（面の編集係と
/// 文書と、差し込みの境のずらし。main のスレッドの CPU 時間）は p99 1ms 以下。壊れると、diff や PR のスレッドの多い文書で
/// スクロールのコマが落ち、打鍵が重くなる。
extension FramePerfTests {
  func testManyRows() throws {
    let small = try measure(
      label: "200KB rows", text: Self.swiftSource(bytes: 200_000), prepare: Self.insertRows)
    let large = try measure(
      label: "1MB rows", text: Self.swiftSource(bytes: 1_000_000), prepare: Self.insertRows)
    print("PERF-FRAMES rows 1MB/200KB cpu p50", String(format: "%.2f", large / small))
    XCTAssertLessThanOrEqual(large, small * 2, "1MB の 1 コマの CPU の中央値は 200KB の 2 倍以内")

    let opened = try attach(Self.swiftSource(bytes: 1_000_000))
    Self.insertRows(opened)
    let surface = opened.surface
    surface.updateFocus(true)
    let middle = opened.document.text.lineCount / 2
    surface.selectedRange = NSRange(location: opened.document.text.lineStart(middle), length: 0)
    surface.reveal(NSRange(location: surface.caretLocation, length: 0), policy: .center)
    waitUntilIdle(surface)
    let main = typeKeys(surface, count: 60, interval: 0.05) { surface, _ in
      surface.perform(.newline(indents: false))
    }
    print(
      "PERF-FRAMES rows 1MB newline keystroke main CPU p50", Self.ms(Self.quantile(main.cpu, 0.5)),
      "p99", Self.ms(Self.quantile(main.cpu, 0.99)), "/ main wall (参考) p99",
      Self.ms(Self.quantile(main.wall, 0.99)), "/ insertions", surface.rows.count)
    XCTAssertLessThanOrEqual(Self.quantile(main.cpu, 0.99), 1, "行の増える打鍵 1 回の main の仕事")
  }

  /// ミニマップを出さない構成にし、10 行ごとに文書に無い行 2 行と区画（高さ 40pt）を交互に差し込む。
  static func insertRows(_ opened: Opened) {
    let surface = opened.surface
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let lineCount = opened.document.text.lineCount
    let insertions = stride(from: 10, to: lineCount, by: 10).enumerated().map { k, line in
      k % 2 == 0
        ? RowInsertion(
          line: line,
          content: .lines([InsertedLine("- removed \(k) a"), InsertedLine("- removed \(k) b")]))
        : RowInsertion(line: line, content: .zone(PerfZone()))
    }
    surface.setRows(SurfaceRows(insertions: insertions))
    surface.flush()
  }
}

/// 高さ 40pt の区画の view。
private final class PerfZone: NSView {
  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 40) }
}
