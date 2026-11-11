import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 差し込みの多い面の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。ミニマップを出さない
/// 1MB・200KB に、10 行ごとに差し込み（文書に無い行 2 行と、スレッドの形の絵の差し込み——影と枠線の付いた
/// 枠・頭・アバター・画像・折り返す本文・押せる場所——を交互に。1MB で約 4,300）を置き、指のドラッグ・はじき・端への
/// 引っ張りを流す。絵の差し込みの高さは本文の行の 5 倍ほどで、絵の差し込みが画面の多くを占めるコマを含む。関門は
/// 本文だけのときと同じ（1 コマの CPU の p99 2ms 未満・描画スレッド自身が落とすコマ 0・main に負荷を入れても・1MB の
/// 中央値が 200KB の 2 倍以内）。行の増える打鍵 1 回の main の仕事（面の編集係と文書と、差し込みの境のずらし。main の
/// スレッドの CPU 時間）は p99 1ms 以下。壊れると、diff や PR のスレッドの多い文書でスクロールのコマが落ち、打鍵が
/// 重くなる。
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

  /// 絵の差し込みの入力欄に打つ——差し込みの多い 1MB の中ほどのスレッドの返信の入力欄で、打鍵の間隔 100ms と 33ms。
  /// 関門は本文の打鍵と同じ（打鍵→present の中央値 12.5ms・p95 17ms、打鍵 1 回の main の仕事 p99 1ms）。絵を
  /// 問い直して材料に写す main の仕事（絵の差し込み 1 つと、幅を変えたときの全部の絵の差し込み）は記録して示す。
  func testTypingIntoAZoneField() throws {
    let opened = try attach(Self.swiftSource(bytes: 1_000_000))
    let surface = opened.surface
    let field = ZoneTextField(id: "perf-reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "打つ返信。", field: field)
    thread.surface = surface
    let lineCount = opened.document.text.lineCount
    let middle = lineCount / 2 / 10 * 10 + 5
    let source = InsertedText()
    var insertions = Self.rowInsertions(lineCount: lineCount, source: source)
    insertions.insert(
      RowInsertion(line: middle, content: .zone(thread)),
      at: insertions.firstIndex { $0.line > middle } ?? insertions.count)
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    surface.setRows(SurfaceRows(insertions: insertions, source: source))
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

  /// 長い 1 段落の本文を持つスレッドを材料と当たりの表に写す main の仕事は、段落の長さに比例する——本文が 2,000 字と
  /// 8,000 字の 1 段落のスレッドで、写す時間の中央値の比が 6 倍以内（比例なら 4 倍、段落の長さの 2 乗なら 16 倍）。
  /// 壊れると、長いコメントのスレッドでホバーの出入りや幅の変化のたびに main が長く止まる。
  func testPaintingALongParagraphGrowsLinearly() throws {
    let look = ZonePainter.Look(
      appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
      space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), scale: 2)
    let sentence = "tail だけ見ると、間に別種のイベントが挟まったときに畳み損ねない？"
    let costs = [2_000, 8_000].map { length -> Double in
      let comment = String(
        String(repeating: sentence, count: length / sentence.count + 1).prefix(length))
      let picture = ThreadZone(comment: comment).picture(width: 700)
      let painter = ZonePainter()
      let times = (0..<9).map { _ -> Double in
        let started = CACurrentMediaTime()
        _ = painter.paint(picture, look) { _ in 0 }
        return CACurrentMediaTime() - started
      }
      return Self.quantile(times.sorted(), 0.5)
    }
    print(
      "PERF-FRAMES zone long paragraph paint main: 2000 chars", Self.ms(costs[0]), "/ 8000 chars",
      Self.ms(costs[1]), "/ ratio", String(format: "%.2f", costs[1] / costs[0]))
    XCTAssertLessThanOrEqual(costs[1], costs[0] * 6, "写す時間は段落の長さに比例する")
  }

  /// ミニマップを出さない構成にし、差し込みの列（→ `rowInsertions`）を置く。
  static func insertRows(_ opened: Opened) {
    let surface = opened.surface
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let source = InsertedText()
    surface.setRows(
      SurfaceRows(
        insertions: Self.rowInsertions(lineCount: opened.document.text.lineCount, source: source),
        source: source))
    surface.flush()
  }

  /// `lineCount` 行の文書に、10 行ごとに文書に無い行 2 行（字は `source` に足す）とスレッドの形の絵の差し込みを交互に
  /// 差し込む列。
  static func rowInsertions(lineCount: Int, source: InsertedText) -> [RowInsertion] {
    stride(from: 10, to: lineCount, by: 10).enumerated().map { k, line in
      k % 2 == 0
        ? RowInsertion(
          line: line, content: .lines(source.lines(["- removed \(k) a", "- removed \(k) b"])))
        : RowInsertion(
          line: line,
          content: .zone(
            ThreadZone(
              comment: "スクロールしても、この枠は本文の行の境から離れない。試し \(k) の本文は幅で折り返す。")))
    }
  }
}
