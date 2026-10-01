import AppKit
import OrbeEditorCore
import XCTest
import os

@testable import OrbeEditorEngine

/// 装備・強調・俯瞰が見えている新しい面の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。
/// 検索の一致 19999 件・語の出現・選択文字列の出現・現在の一致を置き、インデント線と空白の点とミニマップとスクロールバーの
/// 印が見えている 1MB・200KB で、指のドラッグ・はじき・端への引っ張り、ミニマップの帯の端から端へのドラッグ、縦の
/// つまみのドラッグを流す。関門は本文だけのときと同じ（1 コマの CPU の p99 2ms 未満・描画スレッド自身が落とすコマ 0・
/// main に負荷を入れても）。検索の一致を出したままの打鍵と、main が混んだ状態での Orbe からの呼び出し→描画も測る。
extension FramePerfTests {
  func testOverviewScenes() throws {
    let small = try measure(
      label: "200KB overview", text: Self.swiftSource(bytes: 200_000), prepare: Self.decorate)
    let large = try measure(
      label: "1MB overview", text: Self.swiftSource(bytes: 1_000_000), prepare: Self.decorate)
    print("PERF-FRAMES overview 1MB/200KB cpu p50", String(format: "%.2f", large / small))
    XCTAssertLessThanOrEqual(large, small * 2, "1MB の 1 コマの CPU の中央値は 200KB の 2 倍以内")
    for (label, bytes) in [("200KB", 200_000), ("1MB", 1_000_000)] {
      try measureOverviewDrags(label, Self.swiftSource(bytes: bytes))
    }
  }

  /// 10000 字を越える行が並ぶ文書に、一致が多数ある（行ごとに 1000 件近く）。
  func testLongLinesWithManyMatches() throws {
    _ = try measure(
      label: "long-lines overview", text: Self.longLines(count: 300, length: 12_000),
      frameLimit: HeadlessDriver.period * 1000, gatesLateCommits: false
    ) { Self.decorate($0, needle: "item") }
  }

  /// 強調の地を置く——検索の一致（`needle` の出現を上限 19999 件まで）、語の出現（「buffer」）、選択文字列の出現と現在の
  /// 一致（中ほど）。
  static func decorate(_ opened: Opened) {
    decorate(opened, needle: "in")
  }

  static func decorate(_ opened: Opened, needle: String) {
    let text = opened.document.text.substring(
      NSRange(location: 0, length: opened.document.text.length))
    let matches = ranges(of: needle, in: text, limit: 19_999)
    precondition(!matches.isEmpty, "前提: 一致がある")
    let surface = opened.surface
    surface.setHighlights(matches, for: .findMatch)
    surface.setHighlights([matches[matches.count / 2]], for: .currentFindMatch)
    surface.setHighlights(ranges(of: "buffer", in: text, limit: 19_999), for: .wordOccurrence)
    surface.setHighlights(
      Array(ranges(of: "name", in: text, limit: 19_999).prefix(500)), for: .selectionOccurrence)
    surface.flush()
    print("PERF-FRAMES overview matches", matches.count)
  }

  /// `needle` の出現（重ならない昇順、上限 `limit`）。
  static func ranges(of needle: String, in text: String, limit: Int) -> [NSRange] {
    let string = text as NSString
    var result: [NSRange] = []
    var from = 0
    while result.count < limit {
      let found = string.range(
        of: needle, range: NSRange(location: from, length: string.length - from))
      guard found.location != NSNotFound else { break }
      result.append(found)
      from = NSMaxRange(found)
    }
    return result
  }

  /// ミニマップの帯を上端から下端まで・縦のつまみを上端から下端まで、2 秒かけてドラッグする（合成のマウスの出来事を
  /// 約 5.7ms ごと）。main への負荷の有り無しで回す。
  private func measureOverviewDrags(_ label: String, _ text: String) throws {
    let opened = try attach(text)
    Self.decorate(opened)
    waitUntilIdle(opened.surface)
    let surface = opened.surface
    for loaded in [false, true] {
      let name = loaded ? "main-load" : "no-load"
      if loaded { startLoad() }
      surface.scroll(toFirstLine: 0)
      waitUntilIdle(surface)
      let layout = surface.surfaceLayout
      let placement = try XCTUnwrap(surface.placementBox.read())
      let slider = CGPoint(
        x: layout.minimap.midX, y: placement.sliderTop + placement.sliderHeight / 2)
      reset(surface)
      drag(surface, from: slider, to: CGPoint(x: slider.x, y: layout.minimap.maxY), seconds: 2)
      waitUntilIdle(surface)
      report(label, "\(name) minimap-drag", totals(surface))
      surface.scroll(toFirstLine: 0)
      waitUntilIdle(surface)
      let thumb = CGPoint(x: layout.verticalScrollbar.midX, y: 10)
      reset(surface)
      drag(
        surface, from: thumb, to: CGPoint(x: thumb.x, y: layout.verticalScrollbar.maxY),
        seconds: 2)
      waitUntilIdle(surface)
      report(label, "\(name) thumb-drag", totals(surface))
      load?.invalidate()
      load = nil
    }
  }

  /// 押して `from` から `to` まで `seconds` 秒かけて動かし、離す。出来事は別のスレッドが実機の刻みで main の面の入口へ流す。
  private func drag(_ surface: MetalTextSurface, from: CGPoint, to: CGPoint, seconds: Double) {
    let step = 0.0057
    let count = Int(seconds / step)
    var plan = [MouseStep(at: 0, type: .leftMouseDown, point: from)]
    for k in 1...count {
      let t = Double(k) / Double(count)
      plan.append(
        MouseStep(
          at: Double(k) * step, type: .leftMouseDragged,
          point: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
    }
    plan.append(MouseStep(at: Double(count + 1) * step, type: .leftMouseUp, point: to))
    let done = DispatchSemaphore(value: 0)
    let target = Transfer(value: surface)
    let events = Transfer(value: plan)
    let thread = Thread {
      let start = CACurrentMediaTime()
      for item in events.value {
        while CACurrentMediaTime() < start + item.at { usleep(200) }
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            let view = target.value.textView
            guard
              let event = NSEvent.mouseEvent(
                with: item.type, location: view.convert(item.point, to: nil), modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)
            else { return }
            switch item.type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
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
  }

  /// 検索の一致 19999 件を出したまま打つ——打鍵のたびに一致を編集でずらして押し直す（EditorSearch と同じく打鍵の処理の
  /// 中で）。打鍵→present は打鍵だけのときと同じ関門。スクロールバーの印は打鍵ごとに写し直さない（ずらして使い回す）。検索語を
  /// 変えて印を写し直すコマの CPU は記録して示す。
  func testTypingWithManyMatches() throws {
    for (label, bytes) in [("200KB", 200_000), ("1MB", 1_000_000)] {
      let opened = try attach(Self.swiftSource(bytes: bytes))
      Self.decorate(opened)
      let surface = opened.surface
      surface.updateFocus(true)
      let middle = opened.document.text.lineCount / 2
      surface.selectedRange = NSRange(
        location: opened.document.text.lineStart(middle) + 4, length: 0)
      surface.reveal(NSRange(location: surface.caretLocation, length: 0), policy: .center)
      waitUntilIdle(surface)
      let matches = MatchBox(surface.drawn.highlights.find)
      reset(surface)
      let main = typeKeys(surface, count: 60, interval: 0.1) { surface, k in
        let caret = surface.caretLocation
        surface.perform(.insert(k % 7 == 6 ? " " : "x"))
        matches.ranges = TextEdit(range: NSRange(location: caret, length: 0), replacement: "x")
          .track(matches.ranges)
        surface.setHighlights(matches.ranges, for: .findMatch)
      }
      waitUntilIdle(surface)
      let typing = totals(surface).typing.sorted()
      let id = surface.id
      let remapped = RenderThread.shared.performAndWait {
        $0.slot(id)?.rulerRows.remappedInFrame ?? -1
      }
      print(
        "PERF-FRAMES typing-with-matches", label, "keystroke→present median",
        Self.ms(Self.quantile(typing, 0.5)), "p95", Self.ms(Self.quantile(typing, 0.95)),
        "/ main CPU p99", Self.ms(Self.quantile(main.cpu, 0.99)), "/ remapped in last frame",
        remapped)
      XCTAssertGreaterThanOrEqual(typing.count, 55, "\(label): 前提: 打鍵が画面に出た")
      XCTAssertLessThanOrEqual(Self.quantile(typing, 0.5), 12.5, "\(label): 打鍵→present の中央値")
      XCTAssertLessThanOrEqual(Self.quantile(typing, 0.95), 17, "\(label): 打鍵→present の p95")
      reset(surface)
      let text = opened.document.text.substring(
        NSRange(location: 0, length: opened.document.text.length))
      surface.setHighlights(Self.ranges(of: "en", in: text, limit: 19_999), for: .findMatch)
      surface.flush()
      waitUntilIdle(surface)
      let cpu = totals(surface).cpu.sorted()
      print(
        "PERF-FRAMES needle-change", label, "frames", cpu.count, "cpu max",
        Self.ms((cpu.last ?? 0) * 1000))
    }
  }

  /// main の queue に仕事（5ms ずつ）を入れ続けた状態で、Orbe から始まる呼び出し（検索の次へ——選択を置いて中央に見せる）が
  /// 周の終わりを待ち続けずに描かれる。呼び出し→そのコマを描き終えた時刻を記録して示す。
  func testCallsFromOrbeAreDrawnWhileMainIsBusy() throws {
    let opened = try attach(Self.swiftSource(bytes: 1_000_000))
    Self.decorate(opened)
    let surface = opened.surface
    waitUntilIdle(surface)
    let busy = OSAllocatedUnfairLock(initialState: true)
    func keepBusy() {
      DispatchQueue.main.async {
        let end = CACurrentMediaTime() + 0.005
        while CACurrentMediaTime() < end {}
        if busy.withLock({ $0 }) { keepBusy() }
      }
    }
    keepBusy()
    let matches = surface.drawn.highlights.find
    var latencies: [Double] = []
    for k in 0..<30 {
      let match = matches[(k * 613) % matches.count]
      let called = CACurrentMediaTime()
      surface.selectedRange = match
      surface.reveal(NSRange(location: match.location, length: 0), policy: .center)
      surface.setHighlights([match], for: .currentFindMatch)
      let deadline = Date().addingTimeInterval(2)
      var drawn = false
      while !drawn, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        let id = surface.id
        let revision = surface.material.revision
        drawn =
          surface.pending.isEmpty
          && RenderThread.shared.performAndWait { ($0.slot(id)?.drawnMaterial ?? 0) >= revision }
      }
      XCTAssertTrue(drawn, "呼び出し \(k) が描かれる")
      latencies.append(CACurrentMediaTime() - called)
    }
    busy.withLock { $0 = false }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let sorted = latencies.sorted()
    print(
      "PERF-FRAMES orbe-call-under-busy-main call→drawn median",
      Self.ms(Self.quantile(sorted, 0.5)), "p95", Self.ms(Self.quantile(sorted, 0.95)), "max",
      Self.ms((sorted.last ?? 0) * 1000))
  }
}

/// 合成するマウスの出来事 1 つ（`at` は流し始めからの秒、点は面の view の座標）。
private struct MouseStep {
  let at: Double
  let type: NSEvent.EventType
  let point: CGPoint
}

/// 打鍵の間にずらし続ける一致の列（打鍵の closure が書き換える）。
@MainActor
private final class MatchBox {
  var ranges: [NSRange]
  init(_ ranges: [NSRange]) { self.ranges = ranges }
}
