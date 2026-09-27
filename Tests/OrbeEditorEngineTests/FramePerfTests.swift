import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面のコマの計測（実装の関門）。窓を出さず、画面外に実際の表示の刻み（120Hz）で描き、GPU が描き終えた刻みを
/// 「出たコマ」とみなす。合成した指の出来事を実機の刻み（約 5.7ms）で main の面の入口へ流す。シナリオは一定の速さの
/// ドラッグ、momentum 付きのはじき、端への引っ張り（離すと描画スレッドだけが進める戻り）で、文書は 1MB・200KB の Swift と、
/// 10000 字を越える行が並ぶ文書。`ORBE_EDITOR_PERF=1` のときだけ走る（時間はマシンで変わる）。release で
/// `scripts/perf-editor-frames.sh` が回し、`PERF-FRAMES` の行を出す。
///
/// 関門: 描画スレッドの 1 コマの CPU が p99 2ms 未満、描画スレッド自身が落とすコマ（画面に出る予定の刻みの 1ms 前までに
/// 命令を出し終えられなかったコマ）が 0（main に負荷を入れても）、1MB の 1 コマの CPU の中央値が 200KB の 2 倍以内、
/// もう 1 枚の面が画面に出なくなっても刻みごとに描き続ける、止まっている間の起床が 0。長い行の文書は、行を組版しなかった
/// コマの CPU が p99 2ms 未満、初めて見える行を組むコマも含めて 1 刻み未満で、描画スレッド自身が落とすコマは記録して
/// 示すだけ（初めて見える行を組む手間は行の長さに比例する割り切りで、長い行を数行まとめて組むコマは刻みに間に合わない
/// ことがある）。前のコマの GPU・合成の遅れで飛ばした・遅れて出たコマ（マシンの混みで起きる）と、指の出来事→画面の遅れ・
/// 画面の間隔から見た落ちたコマ（端からの戻りの間も）は記録して示す（main の停止分だけ増えるのは設計上の性質。窓の無い
/// 計測では GPU の混みで揺れる）。
@MainActor
final class FramePerfTests: EngineTestCase {
  private var driver: HeadlessDriver!
  private var load: Timer?

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
    driver = HeadlessDriver()
    driver.start()
  }

  override func tearDownWithError() throws {
    load?.invalidate()
    driver?.stop()
    try super.tearDownWithError()
  }

  /// 1MB と 200KB で差が無い（1 コマの CPU の中央値の比で見る）。
  func testDocumentSizeDoesNotChangeTheFrameCost() throws {
    let small = try measure(label: "200KB", text: Self.swiftSource(bytes: 200_000))
    let large = try measure(label: "1MB", text: Self.swiftSource(bytes: 1_000_000))
    print("PERF-FRAMES 1MB/200KB cpu p50", String(format: "%.2f", large / small))
    XCTAssertLessThanOrEqual(large, small * 2, "1MB の 1 コマの CPU の中央値は 200KB の 2 倍以内")
  }

  /// 10000 字を越える行が並ぶ文書（minified の JSON・source map のような）。
  func testLongLines() throws {
    _ = try measure(
      label: "long-lines", text: Self.longLines(count: 300, length: 12_000),
      frameLimit: HeadlessDriver.period * 1000, gatesLateCommits: false)
  }

  /// 面を 2 枚同時に描き、片方の「画面に出た」を止めても、もう片方はドラッグの間の刻みごとに描き続ける（描画スレッドが
  /// 詰まった面のために待たない）。
  func testOneStuckSurfaceDoesNotStallAnother() throws {
    let text = Self.swiftSource(bytes: 200_000)
    let a = try attach(text)
    let b = try attach(text, holdsPresents: true)
    reset(a.surface)
    runDrag([a.surface, b.surface], seconds: 2, speed: 2400)
    let totals = self.totals(a.surface)
    let stuck = self.totals(b.surface)
    let expected = Int(2 / HeadlessDriver.period)
    print(
      "PERF-FRAMES two-surfaces frames \(totals.cpu.count)/\(expected) late-commits \(totals.lateCommits)"
        + " skipped \(totals.skipped) late-presents \(totals.latePresents) stuck-skipped \(stuck.skipped)"
    )
    XCTAssertGreaterThan(stuck.skipped, 0, "前提: 詰まった面はコマを飛ばしている")
    XCTAssertGreaterThanOrEqual(
      totals.cpu.count, expected * 95 / 100, "詰まっていない面は刻みごとに描き続ける")
    XCTAssertEqual(totals.lateCommits, 0, "描画スレッドは刻みに間に合う")
  }

  /// ドラッグとはじき、端への引っ張りを、main への負荷の有り無しで回して関門にかける。`frameLimit` は全部のコマの CPU の
  /// p99 の上限（ms。行を組版しなかったコマは常に 2ms）、`gatesLateCommits` は描画スレッド自身が落とすコマ 0 を関門に
  /// するか。負荷なしのドラッグとはじきの 1 コマの CPU の中央値（ms）を返す。
  private func measure(
    label: String, text: String, frameLimit: Double = 2, gatesLateCommits: Bool = true
  ) throws -> Double {
    let opened = try attach(text)
    let surface = opened.surface
    print("PERF-FRAMES", label, "lines", opened.document.text.lineCount)
    var median = 0.0
    for loaded in [false, true] {
      let name = loaded ? "main-load" : "no-load"
      if loaded { startLoad() }
      reset(surface)
      runDrag([surface], seconds: 3, speed: 2400)
      runFlick(surface, peak: 6000)
      waitUntilIdle(surface)
      let scrolled = totals(surface)
      report(label, name, scrolled, frameLimit: frameLimit, gatesLateCommits: gatesLateCommits)
      if !loaded { median = Self.quantile(scrolled.cpu.sorted(), 0.5) }
      surface.scroll(toTop: 0, hiddenFraction: 0)
      waitUntilIdle(surface)
      reset(surface)
      runPull(surface)
      waitUntilIdle(surface)
      report(
        label, "\(name) pull", totals(surface), frameLimit: frameLimit,
        gatesLateCommits: gatesLateCommits)
      load?.invalidate()
      load = nil
    }
    let ticks = driver.ticks(surface.id)
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    let wakes = driver.ticks(surface.id) - ticks
    print("PERF-FRAMES", label, "idle-wakes/s", wakes)
    XCTAssertEqual(wakes, 0, "止まっている間は描画スレッドを起こさない")
    return median
  }

  private func attach(_ text: String, holdsPresents: Bool = false) throws -> Opened {
    let opened = try open(text, size: CGSize(width: 800, height: 600), waitForColors: true)
    opened.surface.viewStateDidChange(
      size: CGSize(width: 800, height: 600), scale: 2, visible: true)
    driver.bind(opened.surface.id, holdsPresents: holdsPresents)
    let id = opened.surface.id
    RenderThread.shared.performAndWait { $0.slot(id)?.recorder.keepsTotals = true }
    waitUntilIdle(opened.surface)
    return opened
  }

  private func reset(_ surface: MetalTextSurface) {
    let id = surface.id
    RenderThread.shared.performAndWait { renderer in
      renderer.slot(id)?.recorder.flush()
      renderer.slot(id)?.recorder.resetTotals()
    }
  }

  private func totals(_ surface: MetalTextSurface) -> FrameRecorder.Totals {
    let id = surface.id
    return RenderThread.shared.performAndWait { renderer in
      renderer.slot(id)?.recorder.flush()
      return renderer.slot(id)?.recorder.totals ?? FrameRecorder.Totals()
    }
  }

  /// main で 33ms ごとに 25ms 回り続ける（構文解析などの重さを模す）。
  private func startLoad() {
    let timer = Timer(timeInterval: 0.033, repeats: true) { _ in
      let end = CACurrentMediaTime() + 0.025
      while CACurrentMediaTime() < end {}
    }
    RunLoop.main.add(timer, forMode: .common)
    load = timer
  }

  /// 合成する指の出来事 1 つ（`at` は流し始めからの秒）。
  private struct Planned: Sendable {
    var at: Double
    var phase: ScrollInput.Phase = .none
    var momentum: ScrollInput.Phase = .none
    var dy: Double = 0
  }

  /// 指を一定の速さ（pt/秒、下へ）で動かし続ける。出来事は別のスレッドが実機の刻みで main へ流す。
  private func runDrag(_ surfaces: [MetalTextSurface], seconds: Double, speed: Double) {
    let step = 0.0057
    var inputs = [Planned(at: 0, phase: .began)]
    for k in 1...Int(seconds / step) {
      inputs.append(Planned(at: Double(k) * step, phase: .changed, dy: -speed * step))
    }
    inputs.append(Planned(at: seconds + step, phase: .ended))
    feed(surfaces, inputs)
  }

  /// はじく: 80ms で速さを上げて離し、OS の momentum の出来事（1 回ごとに 0.95 倍で落ちる列）が続く。
  private func runFlick(_ surface: MetalTextSurface, peak: Double) {
    let step = 0.0057
    var inputs = [Planned(at: 0, phase: .began)]
    let ramp = Int(0.08 / step)
    for k in 1...ramp {
      inputs.append(
        Planned(
          at: Double(k) * step, phase: .changed, dy: -peak * Double(k) / Double(ramp) * step))
    }
    var t = Double(ramp + 1) * step
    inputs.append(Planned(at: t, phase: .ended))
    var d = -peak * step
    inputs.append(Planned(at: t, momentum: .began, dy: d))
    while abs(d) > 0.5 {
      t += step
      d *= 0.95
      inputs.append(Planned(at: t, momentum: .changed, dy: d))
    }
    inputs.append(Planned(at: t + step, momentum: .ended))
    feed([surface], inputs)
  }

  /// 先頭で指を下へ動かし続けて端の外へ引っ張り（見せるのは 1/20）、離す。戻りは描画スレッドだけが進める。
  private func runPull(_ surface: MetalTextSurface) {
    let step = 0.0057
    var inputs = [Planned(at: 0, phase: .began)]
    for k in 1...Int(0.4 / step) {
      inputs.append(Planned(at: Double(k) * step, phase: .changed, dy: 1500 * step))
    }
    inputs.append(Planned(at: 0.4 + step, phase: .ended))
    feed([surface], inputs)
  }

  /// 出来事を別のスレッドから実時間で main へ流し、流し終えるまで main を回す。時刻は流した時刻（実機の出来事の時刻に
  /// 相当）。
  private func feed(_ surfaces: [MetalTextSurface], _ inputs: [Planned]) {
    let done = DispatchSemaphore(value: 0)
    let targets = surfaces.map { Transfer(value: $0) }
    let thread = Thread {
      let start = CACurrentMediaTime()
      for input in inputs {
        while CACurrentMediaTime() < start + input.at { usleep(200) }
        let event = ScrollInput(
          timestamp: CACurrentMediaTime(), delta: SIMD2(0, input.dy), precise: true,
          phase: input.phase, momentum: input.momentum)
        DispatchQueue.main.async {
          MainActor.assumeIsolated { for target in targets { target.value.scroll(event) } }
        }
      }
      done.signal()
    }
    thread.qualityOfService = .userInteractive
    thread.start()
    while done.wait(timeout: .now()) == .timedOut {
      RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  }

  /// 描画スレッドが刻みを止めるまで main を回す。
  private func waitUntilIdle(_ surface: MetalTextSurface) {
    let deadline = Date().addingTimeInterval(10)
    while !driver.isPaused(surface.id), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
  }

  /// 昇順の秒の列の分位（ms）。
  private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
    sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] * 1000
  }

  private func report(
    _ label: String, _ name: String, _ totals: FrameRecorder.Totals, frameLimit: Double = 2,
    gatesLateCommits: Bool = true
  ) {
    let cpu = totals.cpu.sorted()
    let steady = totals.steadyCPU.sorted()
    let summaries = totals.gestures.compactMap { gesture in
      FrameRecorder.summary(gesture, period: HeadlessDriver.period).map { (gesture, $0) }
    }
    print(
      "PERF-FRAMES", label, name, "frames", cpu.count, "cpu p50",
      String(format: "%.2f", Self.quantile(cpu, 0.5)), "p99",
      String(format: "%.2f", Self.quantile(cpu, 0.99)), "max",
      String(format: "%.2f", (cpu.last ?? 0) * 1000), "steady p99",
      String(format: "%.2f", Self.quantile(steady, 0.99)), "late-commits", totals.lateCommits,
      "/ skipped \(totals.skipped) late-presents \(totals.latePresents)（前のコマの GPU・合成の遅れ）")
    for (index, (gesture, summary)) in summaries.enumerated() {
      let first = (gesture.latencies.first ?? 0) * 1000
      print(
        "PERF-FRAMES", label, name, "gesture", index + 1, summary.description,
        String(format: "/ first event→present %.1fms", first))
    }
    XCTAssertLessThan(
      Self.quantile(steady, 0.99), 2, "\(label) \(name): 行を組まないコマの CPU の p99 は 2ms 未満")
    XCTAssertLessThan(
      Self.quantile(cpu, 0.99), frameLimit,
      "\(label) \(name): 1 コマの CPU の p99 は \(frameLimit)ms 未満")
    if gatesLateCommits {
      XCTAssertEqual(totals.lateCommits, 0, "\(label) \(name): 描画スレッド自身は落とさない")
    }
  }

  /// `bytes` を超えるまで同じ形の宣言を連ねた Swift の本文（1MB で 4.3 万行）。
  static func swiftSource(bytes: Int) -> String {
    let unit = """
      struct Item {
        let name: String
        var offset: Int = 0  // counter
        func render(into buffer: inout [String]) {
          buffer.append("\\(name): \\(offset)")
        }
      }

      """
    var text = ""
    var k = 0
    while text.utf8.count < bytes {
      k += 1
      text += unit.replacingOccurrences(of: "Item", with: "Item\(k)")
    }
    return text
  }

  /// `length` 字を越える 1 行の宣言を `count` 行並べた Swift の本文（役割が数字ごとに変わる）。
  static func longLines(count: Int, length: Int) -> String {
    (0..<count).map { row in
      var line = "let row\(row) = ["
      var k = 0
      while line.utf16.count < length {
        line += "\"item\(k)\", \(k * 7), "
        k += 1
      }
      return line + "]\n"
    }.joined()
  }
}
