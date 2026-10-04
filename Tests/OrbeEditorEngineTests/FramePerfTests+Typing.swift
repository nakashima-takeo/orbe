import AppKit
import OrbeEditorCore
import XCTest
import os

@testable import OrbeEditorEngine

/// 面の打鍵とライブ変換の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。
extension FramePerfTests {
  /// 打鍵→画面に出たとみなす時刻（本文が入ったコマが出た刻み）が中央値 12.5ms・p95 17ms 以下で、1MB と 200KB で差が
  /// 無い（打鍵の間隔 100ms と 33ms）。打鍵 1 回の main の仕事（面の編集係と文書。main のスレッドの CPU 時間で、壁時計は
  /// 参考）は p99 1ms 以下で、1 万字近い長い行の行末で打っても同じ。焦点のある面は、止まっている間は点滅の刻みだけ起きる。
  func testTyping() throws {
    try measureStrokes("typing", Self.type)
    let long = try attach(String(repeating: "a", count: 9_990) + "\nnext\n")
    long.surface.updateFocus(true)
    long.surface.selectedRange = NSRange(location: 9_990, length: 0)
    reset(long.surface)
    let main = typeKeys(long.surface, count: 60, interval: 0.05, stroke: Self.type)
    print(
      "PERF-FRAMES typing long-line main CPU p50", Self.ms(Self.quantile(main.cpu, 0.5)), "p99",
      Self.ms(Self.quantile(main.cpu, 0.99)), "/ main wall (参考) p99",
      Self.ms(Self.quantile(main.wall, 0.99)))
    XCTAssertLessThanOrEqual(Self.quantile(main.cpu, 0.99), 1, "長い行の行末の打鍵 1 回の main の仕事")
  }

  /// ライブ変換の打鍵——未確定が 1 打鍵ごとに 1 字伸びて全体が置き換わり、20 字で確定する、を繰り返す。関門は打鍵と同じ
  /// （打鍵→present の中央値 12.5ms・p95 17ms、IME の呼び出し 1 回の main のスレッドの CPU 時間 p99 1ms（壁時計は参考）、
  /// 1MB と 200KB で差が無い）。ここの面は窓に載せないので、main の仕事は IME の呼び出しそのもの（面の編集係と文書）
  /// だけ——IME が呼び出しの直後に読み返す文字の矩形と点の下の字を含めた main の仕事は、窓に載せた面で
  /// `EditorTypingPerfTests` の `composition-main` が測る。プロセスで最初の変換（入力の仕組みと文字列の橋渡しの初期化）は
  /// 数えないので、測る文書を開く前に別の文書で変換する。
  func testComposition() throws {
    let warm = try attach("warm\n")
    for k in 0..<20 { Self.compose(warm.surface, k) }
    try measureStrokes("composition", Self.compose)
  }

  /// カーソル 1 万本（1MB の各行の頭）で止まっている間の 1 コマ——点滅の刻みで描くコマの CPU を記録し、1 刻みに収まる
  /// （目に見えて詰まらない）。描画は見えている行のキャレットだけを引く。
  func testManyCursorsDoNotStallTheBlink() throws {
    let opened = try attach(Self.swiftSource(bytes: 1_000_000))
    let surface = opened.surface
    let text = opened.document.text
    let cursors = (0..<CursorList.limit).map { Cursor(text.lineStart($0 * 4)) }
    surface.inputScope {
      surface.editor.select(
        CursorList(cursors[0], others: Array(cursors.dropFirst())), reveal: .none)
    }
    surface.updateFocus(true)
    waitUntilIdle(surface)
    reset(surface)
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    let cpu = totals(surface).cpu.sorted()
    XCTAssertGreaterThanOrEqual(cpu.count, 3, "前提: 点滅の刻みで描いた")
    print(
      "PERF-FRAMES 10000-cursors idle frame CPU p50", Self.ms(Self.quantile(cpu, 0.5)), "max",
      Self.ms((cpu.last ?? 0) * 1000))
    XCTAssertLessThan(cpu.last ?? 0, HeadlessDriver.period, "1 刻みに収まる")
  }

  /// 200KB・1MB の文書の中ほどで、打鍵の間隔 100ms と 33ms で `stroke` を流して関門にかける。
  private func measureStrokes(
    _ scenario: String, _ stroke: @escaping @MainActor (MetalTextSurface, Int) -> Void
  ) throws {
    var medians: [String: Double] = [:]
    for (label, bytes) in [("200KB", 200_000), ("1MB", 1_000_000)] {
      let opened = try attach(Self.swiftSource(bytes: bytes))
      opened.surface.updateFocus(true)
      let middle = opened.document.text.lineCount / 2
      opened.surface.selectedRange = NSRange(
        location: opened.document.text.lineStart(middle) + 4, length: 0)
      opened.surface.reveal(
        NSRange(location: opened.surface.caretLocation, length: 0), policy: .center)
      waitUntilIdle(opened.surface)
      for interval in [0.1, 1.0 / 30] {
        let name = "\(label) \(Int((interval * 1000).rounded()))ms"
        reset(opened.surface)
        let main = typeKeys(opened.surface, count: 60, interval: interval, stroke: stroke)
        waitUntilIdle(opened.surface)
        let typing = totals(opened.surface).typing.sorted()
        XCTAssertGreaterThanOrEqual(typing.count, 55, "\(name): 前提: 打鍵が画面に出た")
        let median = Self.quantile(typing, 0.5)
        medians[name] = median
        print(
          "PERF-FRAMES \(scenario)", name, "keystroke→present median", Self.ms(median), "p95",
          Self.ms(Self.quantile(typing, 0.95)), "max", Self.ms((typing.last ?? 0) * 1000),
          "/ main CPU p50", Self.ms(Self.quantile(main.cpu, 0.5)), "p99",
          Self.ms(Self.quantile(main.cpu, 0.99)), "/ main wall (参考) p99",
          Self.ms(Self.quantile(main.wall, 0.99)))
        XCTAssertLessThanOrEqual(median, 12.5, "\(name): 打鍵→present の中央値")
        XCTAssertLessThanOrEqual(Self.quantile(typing, 0.95), 17, "\(name): 打鍵→present の p95")
        XCTAssertLessThanOrEqual(Self.quantile(main.cpu, 0.99), 1, "\(name): 打鍵 1 回の main の仕事")
      }
      if scenario == "typing", label == "1MB" { try measureBlinkWakes(opened.surface) }
    }
    for interval in ["100ms", "33ms"] {
      let difference = abs((medians["1MB \(interval)"] ?? 0) - (medians["200KB \(interval)"] ?? 0))
      XCTAssertLessThan(difference, 2, "\(interval): 1MB と 200KB で差が無い")
    }
  }

  /// 打鍵 `k`——7 打鍵に 1 回は空白、それ以外は字。
  private static func type(_ surface: MetalTextSurface, _ k: Int) {
    surface.perform(.insert(k % 7 == 6 ? " " : "x"))
  }

  /// ライブ変換の打鍵 `k`——未確定を 1 字伸ばして全体を置き換え、20 字目で確定する。
  private static func compose(_ surface: MetalTextSurface, _ k: Int) {
    let length = k % 20 + 1
    let reading = String(repeating: "か", count: length)
    let whole = NSRange(location: NSNotFound, length: 0)
    if length == 20 {
      surface.textView.insertText(reading, replacementRange: whole)
    } else {
      surface.textView.setMarkedText(
        reading, selectedRange: NSRange(location: length, length: 0), replacementRange: whole)
    }
  }

  /// 焦点のある面は、止まっている間は点滅の刻み（1 秒に 2 回）だけ起きる。焦点が無ければ起きない。
  private func measureBlinkWakes(_ surface: MetalTextSurface) throws {
    waitUntilIdle(surface)
    let before = wakes(surface)
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    let focused = wakes(surface) - before
    surface.updateFocus(false)
    waitUntilIdle(surface)
    let idle = wakes(surface)
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    let unfocused = wakes(surface) - idle
    print("PERF-FRAMES blink wakes/2s focused", focused, "unfocused/s", unfocused)
    XCTAssertTrue((3...5).contains(focused), "焦点のある面は点滅の刻み（2 秒に 4 回）だけ起きる")
    XCTAssertEqual(unfocused, 0, "焦点の無い面は起きない")
  }

  /// 描画スレッドが面のために起きた回数——刻みの数と、起こされてその場で描いたコマの数の和（その場で描くコマは刻みの外）。
  private func wakes(_ surface: MetalTextSurface) -> Int {
    let id = surface.id
    let drawn = RenderThread.shared.performAndWait { $0.slot(id)?.recorder.drawnCount ?? 0 }
    return driver.ticks(id) + drawn
  }

  /// 打鍵を別のスレッドから実時間で main へ流す（時刻は流した時刻）。人の打鍵は表示の刻みと揃わないので、間隔に 1 刻み
  /// までの揺らぎを足す（揺らぎが無いと、打鍵が刻みに対していつも同じ位相に来て、遅れが位相で決まってしまう）。打鍵 1 回
  /// ぶんの main の仕事（秒）を、main のスレッドの CPU 時間と壁時計の時間でそれぞれ昇順に返す。
  func typeKeys(
    _ surface: MetalTextSurface, count: Int, interval: Double,
    stroke: @escaping @MainActor (MetalTextSurface, Int) -> Void
  ) -> (cpu: [Double], wall: [Double]) {
    let done = DispatchSemaphore(value: 0)
    let target = Transfer(value: surface)
    let durations = OSAllocatedUnfairLock(initialState: [(cpu: Double, wall: Double)]())
    var generator = SplitMix(seed: UInt64(count) &* 7919 &+ UInt64(interval * 1000))
    let offsets = (0..<count).map { k in
      Double(k) * interval + Double.random(in: 0..<HeadlessDriver.period, using: &generator)
    }
    let thread = Thread {
      let start = CACurrentMediaTime()
      for (k, offset) in offsets.enumerated() {
        while CACurrentMediaTime() < start + offset { usleep(200) }
        let time = CACurrentMediaTime()
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            let began = (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), CACurrentMediaTime())
            target.value.input(keystroke: time) { stroke(target.value, k) }
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began.0) / 1e9
            let wall = CACurrentMediaTime() - began.1
            durations.withLock { $0.append((cpu, wall)) }
          }
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
    let measured = durations.withLock { $0 }
    return (measured.map(\.cpu).sorted(), measured.map(\.wall).sorted())
  }

  static func ms(_ milliseconds: Double) -> String {
    String(format: "%.2fms", milliseconds)
  }
}
