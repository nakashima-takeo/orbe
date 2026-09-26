import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面のコマの計測（実装の関門）。窓を出さず、画面外に実際の表示の刻み（120Hz）で描き、GPU が描き終えた刻みを
/// 「出たコマ」とみなす。合成した指の出来事を実機の刻み（約 5.7ms）で main の面の入口へ流す。`ORBE_EDITOR_PERF=1` の
/// ときだけ走る（時間はマシンで変わる）。release で `scripts/perf-editor-frames.sh` が回し、`PERF-FRAMES` の行を出す。
///
/// 関門: 描画スレッドの 1 コマの CPU が p99 2ms 未満、描画スレッド自身が落とすコマ（描くものがあるのに上限で飛ばした・
/// 予定の刻みに間に合わなかった）が 0（main に負荷を入れても、もう 1 枚の面の画面が詰まっても）、止まっている間の起床が 0。
/// 指の出来事→画面の遅れと、画面の間隔から見た落ちたコマは記録して示す（main の停止分だけ増えるのは設計上の性質）。
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

  func test1MB() throws { try measure(label: "1MB", bytes: 1_000_000) }

  func test200KB() throws { try measure(label: "200KB", bytes: 200_000) }

  /// 面を 2 枚同時に描き、片方の「画面に出た」を止めても、もう片方は 1 コマも落とさない。
  func testOneStuckSurfaceDoesNotStallAnother() throws {
    let text = Self.swiftSource(bytes: 200_000)
    let a = try attach(text)
    let b = try attach(text, holdsPresents: true)
    runDrag([a.surface, b.surface], seconds: 2, speed: 2400)
    let totals = self.totals(a.surface)
    let stuck = self.totals(b.surface)
    print(
      "PERF-FRAMES two-surfaces skipped \(totals.skipped) late \(totals.late) stuck-skipped \(stuck.skipped)"
    )
    XCTAssertGreaterThan(stuck.skipped, 0, "前提: 詰まった面はコマを飛ばしている")
    XCTAssertEqual(totals.skipped + totals.late, 0, "詰まっていない面は落とさない")
  }

  private func measure(label: String, bytes: Int) throws {
    let opened = try attach(Self.swiftSource(bytes: bytes))
    print("PERF-FRAMES", label, "lines", opened.document.text.lineCount)
    for loaded in [false, true] {
      if loaded { startLoad() }
      reset(opened.surface)
      runDrag([opened.surface], seconds: 3, speed: 2400)
      runFlick(opened.surface, peak: 6000)
      waitUntilIdle(opened.surface)
      load?.invalidate()
      load = nil
      report(label, loaded ? "main-load" : "no-load", totals(opened.surface))
    }
    let ticks = driver.ticks(opened.surface.id)
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    let wakes = driver.ticks(opened.surface.id) - ticks
    print("PERF-FRAMES", label, "idle-wakes/s", wakes)
    XCTAssertEqual(wakes, 0, "止まっている間は描画スレッドを起こさない")
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

  private func report(_ label: String, _ name: String, _ totals: FrameRecorder.Totals) {
    let cpu = totals.cpu.sorted()
    func quantile(_ q: Double) -> Double {
      cpu.isEmpty ? 0 : cpu[min(cpu.count - 1, Int(Double(cpu.count) * q))] * 1000
    }
    let summaries = totals.gestures.compactMap {
      FrameRecorder.summary($0, period: HeadlessDriver.period)
    }
    print(
      "PERF-FRAMES", label, name, "frames", cpu.count, "cpu p50",
      String(format: "%.2f", quantile(0.5)), "p99", String(format: "%.2f", quantile(0.99)),
      "max", String(format: "%.2f", (cpu.last ?? 0) * 1000), "self-dropped",
      totals.skipped + totals.late, "(skipped \(totals.skipped) late \(totals.late))")
    for (index, summary) in summaries.enumerated() {
      print("PERF-FRAMES", label, name, "gesture", index + 1, summary.description)
    }
    XCTAssertLessThan(quantile(0.99), 2, "\(label) \(name): 1 コマの CPU の p99 は 2ms 未満")
    XCTAssertEqual(totals.skipped + totals.late, 0, "\(label) \(name): 描画スレッド自身は落とさない")
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
}
