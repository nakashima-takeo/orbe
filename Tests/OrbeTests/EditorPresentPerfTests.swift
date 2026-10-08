import AppKit
import OrbeEditorCore
import XCTest
import os

@testable import Orbe
@testable import OrbeEditorEngine

/// 画面に出す計測（朝の場で回し、その結果を正とする。関門にはしない）。`ORBE_EDITOR_PRESENT=1` のときだけ走り、
/// `scripts/perf-editor-present.sh` が xctrace（Animation Hitches）の下で起こす。窓は画面に出すがアプリは activate
/// しない。
///
/// 1MB の文書に合成した指の出来事を実機の刻み（約 5.7ms）で流す。待つ間はアプリの出来事を配る（→ `runShownWindow`。
/// 配らないと窓が見えている知らせが届かず、面は描かない）。出来事→present と落ちたコマは面の記録係が OS のログ
/// （カテゴリ `editor-frames`）へジェスチャーごとに出す。合成の出来事を流している区間を os_signpost の interval
/// `scrolling` で trace に記録し、スクリプトはその区間の hitches だけを区間の長さで割る。
@MainActor
final class EditorPresentPerfTests: OrbeTestCase {
  private static let signposter = OSSignposter(
    subsystem: "dev.orbe.perf", category: "editor-present")

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PRESENT"] == "1",
      "ORBE_EDITOR_PRESENT=1 で走る")
    // 窓を画面に出せる形にする（Dock に出ず、activate もしない）。
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  func testScrolling() throws {
    let (window, document) = try show()
    defer { window.orderOut(nil) }
    drag(document.surface.view, seconds: 3, speed: 2400)
    runShownWindow(for: 1)
    for _ in 0..<3 {
      flick(document.surface.view, peak: 6000)
      runShownWindow(for: 2.5)
    }
  }

  /// 1200×800 の窓を画面に出し（activate しない）、1MB の Swift の文書を開く。
  private func show() throws -> (NSWindow, EditorDocument) {
    let host = try editorWindow()
    host.window.orderFrontRegardless()
    let document = try host.tab.editor.open(
      try caseFile("big.swift", EditorTypingPerfTests.swiftSource(bytes: 1_000_000)), as: .pinned)
    host.pane.layoutSubtreeIfNeeded()
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
    runShownWindow(for: 1)
    let surface = try XCTUnwrap(document.surface as? MetalTextSurface)
    XCTAssertTrue(surface.material.read().visible, "前提: 窓が見えていると面が知っている")
    return (host.window, document)
  }

  /// 指を一定の速さ（pt/秒、下へ）で動かし続ける。
  private func drag(_ view: NSView, seconds: Double, speed: Double) {
    let step = 0.0057
    var events = [Planned(at: 0, phase: 1, dy: 0)]
    for k in 1...Int(seconds / step) {
      events.append(Planned(at: Double(k) * step, phase: 2, dy: -speed * step))
    }
    events.append(Planned(at: seconds + step, phase: 4, dy: 0))
    feed(view, events)
  }

  /// はじく: 80ms で速さを上げて離し、OS の momentum の出来事（1 回ごとに 0.95 倍で落ちる列）が続く。
  private func flick(_ view: NSView, peak: Double) {
    let step = 0.0057
    var events = [Planned(at: 0, phase: 1, dy: 0)]
    let ramp = Int(0.08 / step)
    for k in 1...ramp {
      events.append(
        Planned(at: Double(k) * step, phase: 2, dy: -peak * Double(k) / Double(ramp) * step))
    }
    var t = Double(ramp + 1) * step
    events.append(Planned(at: t, phase: 4, dy: 0))
    var d = -peak * step
    events.append(Planned(at: t, momentum: 1, dy: d))
    while abs(d) > 0.5 {
      t += step
      d *= 0.95
      events.append(Planned(at: t, momentum: 2, dy: d))
    }
    events.append(Planned(at: t + step, momentum: 3, dy: 0))
    feed(view, events)
  }

  /// 合成するスクロールの出来事（`phase`・`momentum` は CGEvent の段の値）。
  private struct Planned {
    var at: Double
    var phase: Int64 = 0
    var momentum: Int64 = 0
    var dy: Double
  }

  /// 出来事を別のスレッドから実時間で main の面の入口へ流す。時刻は流した時刻。流している間をスクロールの区間とする。
  private func feed(_ view: NSView, _ events: [Planned]) {
    let scrolling = Self.signposter.beginInterval("scrolling")
    defer { Self.signposter.endInterval("scrolling", scrolling) }
    let done = DispatchSemaphore(value: 0)
    let target = UncheckedView(view: view)
    let thread = Thread {
      let start = CACurrentMediaTime()
      for planned in events {
        while CACurrentMediaTime() < start + planned.at { usleep(200) }
        guard
          let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(planned.dy),
            wheel2: 0, wheel3: 0)
        else { continue }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: planned.phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: planned.momentum)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: planned.dy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: planned.dy)
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let wrapped = UncheckedEvent(event: event)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            if let event = NSEvent(cgEvent: wrapped.event) { target.view.scrollWheel(with: event) }
          }
        }
      }
      done.signal()
    }
    thread.qualityOfService = .userInteractive
    thread.start()
    while done.wait(timeout: .now()) == .timedOut { runShownWindow(for: 0.002) }
  }
}

private struct UncheckedView: @unchecked Sendable {
  let view: NSView
}

private struct UncheckedEvent: @unchecked Sendable {
  let event: CGEvent
}
