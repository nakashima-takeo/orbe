import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest
import os

@testable import OrbeEditorEngine

/// 行の頭の印を引く計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。PR の diff の構成の面（→
/// `FramePerfTests+PullRequest`）で、印を押して下へ引き、面の下端の外で自動スクロールさせてから離す。関門は、引く 1 回の
/// main の仕事 p99 1ms・1 コマの CPU の p99 2ms 未満・描画スレッド自身が落とすコマ 0。壊れると、範囲を引く間に範囲の地が
/// ポインタに遅れ、自動スクロールのコマが落ちる。構成は `wraps` で折り返す面にもできる。
extension FramePerfTests {
  func testDraggingTheLeadingMark() throws {
    try measureLeadingMarkDrag(wraps: false)
  }

  /// 止まったインラインの PR の diff（全部の行が 1 つのハンク）で、先頭に見えている行の印を押し、1 回 3pt ずつ実機の刻みで
  /// 下へ引き、面の下端の外で 1 秒、自動スクロールの刻みを進めてから離す。引く 1 回（移動と自動スクロールの刻み）の main
  /// の仕事・1 コマの CPU・描画スレッド自身が落とすコマを関門にかける。
  func measureLeadingMarkDrag(wraps: Bool) throws {
    let old = try open(
      Self.swiftSource(bytes: 1_000_000).replacingOccurrences(of: "Item", with: "Old"))
    let source = DocumentRowSource(old.document)
    let opened = try attach(
      Self.swiftSource(bytes: 1_000_000), wraps: wraps, pointer: Self.pointerSpot)
    let surface = opened.surface
    surface.setPresentation(Self.pullRequestPresentation(columns: 2, wraps: wraps))
    surface.setRows(
      Self.pullRequestInlineRows(
        lineCount: opened.document.text.lineCount, source: source, oneHunk: true))
    surface.isEditable = false
    surface.scroll(to: RowPosition(line: opened.document.text.lineCount / 2))
    waitUntilIdle(surface)
    let window = try XCTUnwrap(surface.view.window as? PointerWindow)
    let top = surface.config.topInset + surface.config.lineHeight / 2
    let bottom = surface.size.height + 40
    var points: [CGPoint] = []
    var y = top
    while y < bottom {
      points.append(CGPoint(x: 12, y: y))
      y += 3
    }
    let outside = points.count
    points += Array(repeating: CGPoint(x: 12, y: bottom), count: Int(1 / 0.0057))
    reset(surface)
    let cpu = dragLeadingMark(surface, window, through: points, autoscrollFrom: outside)
    waitUntilIdle(surface)
    let scrolled = totals(surface)
    report("1MB pr mark drag", "drag", scrolled)
    print(
      "PERF-FRAMES 1MB pr mark drag main CPU p50", Self.ms(Self.quantile(cpu, 0.5)), "p99",
      Self.ms(Self.quantile(cpu, 0.99)), "/ events", cpu.count)
    XCTAssertLessThanOrEqual(Self.quantile(cpu, 0.99), 1, "引く 1 回の main の仕事")
  }

  /// 点の列の最初で印を押し、続く点へ実機の刻みで引き、`autoscrollFrom` 番目からは同じ点で自動スクロールの刻みを進め、最後に
  /// 離す。押下と離すのを除いた 1 回ごとの main の仕事（秒）を昇順に返す。
  func dragLeadingMark(
    _ surface: MetalTextSurface, _ window: PointerWindow, through points: [CGPoint],
    autoscrollFrom: Int
  ) -> [Double] {
    let done = DispatchSemaphore(value: 0)
    let target = Transfer(value: surface)
    let windowTarget = Transfer(value: window)
    let durations = OSAllocatedUnfairLock(initialState: [Double]())
    let thread = Thread {
      let start = CACurrentMediaTime()
      for k in 0...points.count {
        let point = points[min(k, points.count - 1)]
        while CACurrentMediaTime() < start + Double(k) * 0.0057 { usleep(200) }
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            let surface = target.value
            let window = windowTarget.value
            let windowPoint = surface.textView.convert(point, to: nil)
            window.pointer = windowPoint
            let type: NSEvent.EventType =
              k == 0 ? .leftMouseDown : k == points.count ? .leftMouseUp : .leftMouseDragged
            guard
              let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            switch type {
            case .leftMouseDown: surface.textView.mouseDown(with: event)
            case .leftMouseUp: surface.textView.mouseUp(with: event)
            default:
              if k < autoscrollFrom || !surface.textView.pointer.isAutoscrolling {
                surface.textView.mouseDragged(with: event)
              } else {
                surface.textView.pointer.frame(now: CACurrentMediaTime())
              }
            }
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1e9
            if type == .leftMouseDragged { durations.withLock { $0.append(cpu) } }
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
}
