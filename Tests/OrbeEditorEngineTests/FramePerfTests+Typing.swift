import AppKit
import OrbeEditorCore
import XCTest
import os

@testable import OrbeEditorEngine

/// 新しい面の打鍵の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。
extension FramePerfTests {
  /// 打鍵→画面に出たとみなす時刻（本文が入ったコマが出た刻み）が中央値 12.5ms・p95 17ms 以下で、1MB と 200KB で差が
  /// 無い（打鍵の間隔 100ms と 33ms）。打鍵 1 回の main の仕事（面の編集係と文書）は p99 1ms 以下で、1 万字近い長い行の
  /// 行末で打っても同じ。焦点のある面は、止まっている間は点滅の刻みだけ起きる。
  func testTyping() throws {
    var medians: [String: Double] = [:]
    for (label, bytes) in [("200KB", 200_000), ("1MB", 1_000_000)] {
      let opened = try attach(Self.swiftSource(bytes: bytes))
      opened.surface.updateFocus(true)
      let middle = opened.document.text.lineCount / 2
      opened.surface.selectedRange = NSRange(
        location: opened.document.text.lineStart(middle) + 4, length: 0)
      opened.surface.scrollToCenter(opened.surface.caretLocation)
      waitUntilIdle(opened.surface)
      for interval in [0.1, 1.0 / 30] {
        let name = "\(label) \(Int((interval * 1000).rounded()))ms"
        reset(opened.surface)
        let main = typeKeys(opened.surface, count: 60, interval: interval)
        waitUntilIdle(opened.surface)
        let typing = totals(opened.surface).typing.sorted()
        XCTAssertGreaterThanOrEqual(typing.count, 55, "\(name): 前提: 打鍵が画面に出た")
        let median = Self.quantile(typing, 0.5)
        medians[name] = median
        print(
          "PERF-FRAMES typing", name, "keystroke→present median", Self.ms(median), "p95",
          Self.ms(Self.quantile(typing, 0.95)), "max", Self.ms((typing.last ?? 0) * 1000), "/ main p50",
          Self.ms(Self.quantile(main, 0.5)), "p99", Self.ms(Self.quantile(main, 0.99)))
        XCTAssertLessThanOrEqual(median, 12.5, "\(name): 打鍵→present の中央値")
        XCTAssertLessThanOrEqual(Self.quantile(typing, 0.95), 17, "\(name): 打鍵→present の p95")
        XCTAssertLessThanOrEqual(Self.quantile(main, 0.99), 1, "\(name): 打鍵 1 回の main の仕事")
      }
      if label == "1MB" { try measureBlinkWakes(opened.surface) }
    }
    for interval in ["100ms", "33ms"] {
      let difference = abs((medians["1MB \(interval)"] ?? 0) - (medians["200KB \(interval)"] ?? 0))
      XCTAssertLessThan(difference, 2, "\(interval): 1MB と 200KB で差が無い")
    }
    let long = try attach(String(repeating: "a", count: 9_990) + "\nnext\n")
    long.surface.updateFocus(true)
    long.surface.selectedRange = NSRange(location: 9_990, length: 0)
    reset(long.surface)
    let main = typeKeys(long.surface, count: 60, interval: 0.05)
    print(
      "PERF-FRAMES typing long-line main p50", Self.ms(Self.quantile(main, 0.5)), "p99",
      Self.ms(Self.quantile(main, 0.99)))
    XCTAssertLessThanOrEqual(Self.quantile(main, 0.99), 1, "長い行の行末の打鍵 1 回の main の仕事")
  }

  /// 焦点のある面は、止まっている間は点滅の刻み（1 秒に 2 回）だけ起きる。焦点が無ければ起きない。
  private func measureBlinkWakes(_ surface: MetalTextSurface) throws {
    waitUntilIdle(surface)
    let before = driver.ticks(surface.id)
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    let focused = driver.ticks(surface.id) - before
    surface.updateFocus(false)
    waitUntilIdle(surface)
    let idle = driver.ticks(surface.id)
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    let unfocused = driver.ticks(surface.id) - idle
    print("PERF-FRAMES blink wakes/2s focused", focused, "unfocused/s", unfocused)
    XCTAssertLessThanOrEqual(focused, 5, "焦点のある面は点滅の刻みだけ起きる")
    XCTAssertEqual(unfocused, 0, "焦点の無い面は起きない")
  }

  /// 打鍵を別のスレッドから実時間で main へ流す（時刻は流した時刻）。人の打鍵は表示の刻みと揃わないので、間隔に 1 刻み
  /// までの揺らぎを足す（揺らぎが無いと、打鍵が刻みに対していつも同じ位相に来て、遅れが位相で決まってしまう）。打鍵 1 回
  /// ぶんの main の仕事（秒）を返す。
  private func typeKeys(_ surface: MetalTextSurface, count: Int, interval: Double) -> [Double] {
    let done = DispatchSemaphore(value: 0)
    let target = Transfer(value: surface)
    let durations = OSAllocatedUnfairLock(initialState: [Double]())
    var generator = SplitMix(seed: UInt64(count) &* 7919 &+ UInt64(interval * 1000))
    let offsets = (0..<count).map { k in
      Double(k) * interval + Double.random(in: 0..<HeadlessDriver.period, using: &generator)
    }
    let thread = Thread {
      let start = CACurrentMediaTime()
      for (k, offset) in offsets.enumerated() {
        while CACurrentMediaTime() < start + offset { usleep(200) }
        let stroke = CACurrentMediaTime()
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            let began = CACurrentMediaTime()
            target.value.keystroke = stroke
            target.value.perform(.insert(k % 7 == 6 ? " " : "x"))
            target.value.keystroke = nil
            let spent = CACurrentMediaTime() - began
            durations.withLock { $0.append(spent) }
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
    return durations.withLock { $0 }.sorted()
  }

  private static func ms(_ milliseconds: Double) -> String {
    String(format: "%.2fms", milliseconds)
  }}
