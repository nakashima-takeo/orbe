import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 差し込みの多い面の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。ミニマップを出さない
/// 1MB・200KB に、10 行ごとに差し込み（文書に無い行 2 行と、スレッドの形の区画——影と枠線の付いた枠・頭・アバター・画像・
/// 折り返す本文・押せる場所——を交互に。1MB で約 4,300）を置き、指のドラッグ・はじき・端への引っ張りを流す。区画の高さは
/// 本文の行の 5 倍ほどで、区画が画面の多くを占めるコマを含む。関門は本文だけのときと同じ（1 コマの CPU の p99 2ms 未満・描画スレッド自身が
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
      surface.editor.perform(.newline(indents: false))
    }
    print(
      "PERF-FRAMES rows 1MB newline keystroke main CPU p50", Self.ms(Self.quantile(main.cpu, 0.5)),
      "p99", Self.ms(Self.quantile(main.cpu, 0.99)), "/ main wall (参考) p99",
      Self.ms(Self.quantile(main.wall, 0.99)), "/ insertions", surface.rows.count)
    XCTAssertLessThanOrEqual(Self.quantile(main.cpu, 0.99), 1, "行の増える打鍵 1 回の main の仕事")
  }

  /// 区画の入力欄に打つ——差し込みの多い 1MB の中ほどのスレッドの返信の入力欄で、打鍵の間隔 100ms と 33ms。関門は本文の
  /// 打鍵と同じ（打鍵→present の中央値 12.5ms・p95 17ms、打鍵 1 回の main の仕事 p99 1ms）。区画の絵を問い直して材料に写す
  /// main の仕事（区画 1 つと、幅を変えたときの全部の区画）は記録して示す。
  func testTypingIntoAZoneField() throws {
    let opened = try attach(Self.swiftSource(bytes: 1_000_000))
    Self.insertRows(opened)
    let surface = opened.surface
    let field = ZoneTextField(id: "perf-reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "打つ区画。", field: field)
    thread.surface = surface
    let middle = opened.document.text.lineCount / 2 / 10 * 10 + 5
    var insertions = surface.rows.boundaries.indices.map { index -> RowInsertion in
      let line = surface.rows.boundaries[index]
      switch surface.rows.contents[index] {
      case .lines(let lines):
        return RowInsertion(line: line, content: .lines(lines.map(InsertedLine.init)))
      case .zone(let id): return RowInsertion(line: line, content: .zone(surface.zones[id]!.zone))
      }
    }
    insertions.insert(
      RowInsertion(line: middle, content: .zone(thread)),
      at: insertions.firstIndex { $0.line > middle } ?? insertions.count)
    surface.setRows(SurfaceRows(insertions: insertions))
    surface.updateFocus(true)
    surface.focus(field)
    surface.reveal(
      NSRange(location: opened.document.text.lineStart(middle), length: 0), policy: .center)
    waitUntilIdle(surface)
    for interval in [0.1, 1.0 / 30] {
      let name = "\(Int((interval * 1000).rounded()))ms"
      reset(surface)
      let main = typeKeys(surface, count: 60, interval: interval) { surface, k in
        surface.primarySite?.editor.perform(.insert(k % 7 == 6 ? " " : "x"))
      }
      waitUntilIdle(surface)
      let typing = totals(surface).typing.sorted()
      XCTAssertGreaterThanOrEqual(typing.count, 55, "\(name): 前提: 打鍵が画面に出た")
      print(
        "PERF-FRAMES zone-field 1MB", name, "keystroke→present median",
        Self.ms(Self.quantile(typing, 0.5)), "p95", Self.ms(Self.quantile(typing, 0.95)),
        "/ main CPU p50", Self.ms(Self.quantile(main.cpu, 0.5)), "p99",
        Self.ms(Self.quantile(main.cpu, 0.99)))
      XCTAssertLessThanOrEqual(Self.quantile(typing, 0.5), 12.5, "\(name): 打鍵→present の中央値")
      XCTAssertLessThanOrEqual(Self.quantile(typing, 0.95), 17, "\(name): 打鍵→present の p95")
      XCTAssertLessThanOrEqual(Self.quantile(main.cpu, 0.99), 1, "\(name): 打鍵 1 回の main の仕事")
    }
    XCTAssertEqual(field.text.length, 120, "打鍵は入力欄に入る")
    var started = CACurrentMediaTime()
    surface.redrawZone(thread)
    let one = CACurrentMediaTime() - started
    started = CACurrentMediaTime()
    surface.viewStateDidChange(size: CGSize(width: 700, height: 600), scale: 2, visible: true)
    let all = CACurrentMediaTime() - started
    print(
      "PERF-FRAMES zone picture main: one zone", Self.ms(one * 1000), "/ width change",
      surface.zones.count, "zones", Self.ms(all * 1000))
  }

  /// ミニマップを出さない構成にし、10 行ごとに文書に無い行 2 行とスレッドの形の区画を交互に差し込む。
  static func insertRows(_ opened: Opened) {
    let surface = opened.surface
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let lineCount = opened.document.text.lineCount
    let insertions = stride(from: 10, to: lineCount, by: 10).enumerated().map { k, line in
      k % 2 == 0
        ? RowInsertion(
          line: line,
          content: .lines([InsertedLine("- removed \(k) a"), InsertedLine("- removed \(k) b")]))
        : RowInsertion(
          line: line,
          content: .zone(
            ThreadZone(
              comment: "スクロールしても、この枠は本文の行の境から離れない。区画 \(k) の本文は幅で折り返す。")))
    }
    surface.setRows(SurfaceRows(insertions: insertions))
    surface.flush()
  }
}
