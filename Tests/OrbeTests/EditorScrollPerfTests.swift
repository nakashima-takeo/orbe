import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エディターのスクロールと打鍵の計測。`ORBE_EDITOR_PERF=1` のときだけ走る——時間はマシンと環境で変わるので通常の
/// テストでは見ない。release・実アプリ相当の小さな環境で `scripts/perf-editor.sh` が回し、目標（→
/// docs/testing/test-architecture.md）と並べる。結果は `PERF` で始まる行に出す。
@MainActor
final class EditorScrollPerfTests: OrbeTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  func test1MB() throws { try run(label: "1MB", bytes: 1_000_000) }

  func test200KB() throws { try run(label: "200KB", bytes: 200_000) }

  /// 打鍵 1 回で文書と Orbe 側が main でする仕事——編集の通知を受けてから、文書と配り先（俯瞰・検索・出現）の処理が
  /// 戻るまで——を、大きさを変えた文書（64KB / 1MB / 8MB）で並べる。git 管理下（baseline あり）の回も測る。テキスト
  /// エンジン自身の仕事（TextKit の layout と描画）は含まない（それは `typing`）。
  func testTypingMainTimeAcrossSizes() throws {
    for (label, bytes) in [("64KB", 64_000), ("1MB", 1_000_000), ("8MB", 8_000_000)] {
      let text = Self.swiftSource(bytes: bytes)
      for tracked in [false, true] {
        let opened = try open(text)
        if tracked {
          opened.document.baseline = text
          XCTAssertTrue(opened.document.waitUntilCaughtUp(timeout: 60))
        }
        let timer = EditTimer(inner: opened.document)
        opened.document.surface.delegate = timer
        _ = type(into: opened)
        report(
          label, tracked ? "typing-main (baseline あり)" : "typing-main", timer.times, digits: 3)
        opened.document.surface.delegate = opened.document
        opened.window.orderOut(nil)
      }
    }
  }

  /// 1200×800 の窓に Swift の文書を開き、裏の仕事（文書全体の構文色）が追いついてから測る。速いドラッグは開いた
  /// ばかりの文書で、打鍵・ホイール・打鍵の後の速いドラッグは別に開き直した文書で測る。文書を端から端まで通した後の
  /// 打鍵も参考に出す（TextKit が段落を覚えるので、開いたばかりの文書より重い）。
  private func run(label: String, bytes: Int) throws {
    let text = Self.swiftSource(bytes: bytes)
    let dragged = try open(text)
    print(
      "PERF", label, "env", ProcessInfo.processInfo.environment.count, "lines",
      dragged.document.text.lineCount, "bytes", dragged.document.text.length)
    drag(label, "fast-drag", dragged)
    report(label, "typing-after-drag (参考)", type(into: dragged))
    dragged.window.orderOut(nil)

    let typed = try open(text)
    report(label, "typing", type(into: typed))
    let recolored = recolor(into: typed)
    report(label, "typing-recolor", recolored.redraw)
    report(label, "typing-catch-up (参考)", recolored.catchUp)
    let clip = try XCTUnwrap(typed.document.surface.responder.enclosingScrollView).contentView
    let times = (0..<60).map { _ in
      frame(typed.pane) {
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 36))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
      }
    }
    report(label, "wheel", times)
    drag(label, "fast-drag-after-typing", typed)
    report(label, "scrollbar-draw (一致の多い検索)", scrollbarDraws(typed))
    typed.window.orderOut(nil)
  }

  private struct Opened {
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    let document: EditorDocument
  }

  private func open(_ text: String) throws -> Opened {
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: queries))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 1200, height: 800)
    window.appearance = NSAppearance(named: .darkAqua)
    let document = try tab.editor.open(try caseFile("big-\(UUID().uuidString).swift", text))
    pane.layoutSubtreeIfNeeded()
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "本文が layout される")
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
    window.makeFirstResponder(document.surface.responder)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    return Opened(tab: tab, pane: pane, window: window, document: document)
  }

  /// 速いドラッグを 3 回。
  private func drag(_ label: String, _ name: String, _ opened: Opened) {
    let rounds = (1...3).map { _ in fastDrag(opened.pane, opened.document) }
    print(
      "PERF", label, name, "updates/s min", String(format: "%.1f", rounds.min() ?? 0), "rounds",
      rounds.map { String(format: "%.1f", $0) }.joined(separator: " "))
  }

  /// 1/3 の位置の行に 30 字打つ。1 字ごとの時間（ms）。
  private func type(into opened: Opened) -> [Double] {
    let document = opened.document
    let middle = document.text.lineCount / 3
    document.scroll(toFirstLine: CGFloat(middle))
    document.surface.selectedRange = NSRange(
      location: document.text.lineStart(middle + 5) + 4, length: 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    var times: [Double] = []
    for character in "let value = compute(offset) ok" {
      times.append(
        frame(opened.pane) {
          document.surface.responder.keyDown(with: .key(String(character), []))
        })
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return times
  }

  /// 打鍵の後、裏から役割が届いてから行う描き直し（1 字ごと、ms）——打鍵のコマとは別に main に載る仕事。役割が変わらない
  /// 打鍵では描き直すものが無い。参考に、打鍵から裏の仕事（文書全体の役割）が追いつくまでの時間も返す。
  private func recolor(into opened: Opened) -> (redraw: [Double], catchUp: [Double]) {
    let document = opened.document
    document.surface.selectedRange = NSRange(
      location: document.text.lineStart(document.text.lineCount / 3 + 7) + 4, length: 0)
    _ = frame(opened.pane) {}
    var redraw: [Double] = []
    var catchUp: [Double] = []
    for character in "let value = compute(offset) ok" {
      let began = Date()
      _ = frame(opened.pane) {
        document.surface.responder.keyDown(with: .key(String(character), []))
      }
      XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
      catchUp.append(Date().timeIntervalSince(began) * 1000)
      redraw.append(frame(opened.pane) {})
    }
    return (redraw, catchUp)
  }

  /// 一致の多い検索（1MB で上限の 19,999 件、200KB で約 1.5 万件）を開いたまま、スクロールバーを 30 回描き直す（1 回ごと、
  /// ms）。
  private func scrollbarDraws(_ opened: Opened) -> [Double] {
    let pane = opened.pane
    pane.showSearch()
    pane.search.setNeedle("e")
    XCTAssertTrue(opened.document.waitUntilCaughtUp(timeout: 60))
    XCTAssertGreaterThan(
      pane.search.matches.count, OverviewRuler.approximateFindMatchCount, "前提: 一致が多い")
    let bar = pane.scrollbar
    let times = (0..<30).map { _ in frame(bar) { bar.needsDisplay = true } }
    pane.closeSearch()
    return times
  }

  /// スクロールバーのつまみを 2 秒で上端から下端まで、8ms ごとにドラッグする。本文の先頭の行が変わった回数を毎秒で返す。
  private func fastDrag(_ pane: EditorPaneView, _ document: EditorDocument) -> Double {
    let bar = pane.scrollbar
    document.scroll(toFirstLine: 0)
    pane.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let start = NSPoint(x: bar.bounds.midX, y: (bar.geometry?.sliderPosition ?? 0) + 5)
    bar.mouseDown(with: bar.mouseEvent(.leftMouseDown, at: start))
    var updates = 0
    var last = document.viewportLines.first
    let began = Date()
    while Date().timeIntervalSince(began) < 2 {
      let progress = Date().timeIntervalSince(began) / 2
      let y = start.y + CGFloat(progress) * (bar.bounds.height - 30)
      bar.mouseDragged(
        with: bar.mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x, y: y)))
      RunLoop.main.run(until: Date().addingTimeInterval(0.008))
      pane.displayIfNeeded()
      let first = document.viewportLines.first
      if first != last {
        updates += 1
        last = first
      }
    }
    bar.mouseUp(
      with: bar.mouseEvent(.leftMouseUp, at: NSPoint(x: start.x, y: bar.bounds.height)))
    return Double(updates) / 2
  }

  /// 操作 1 回を layout と描画まで含めて測る（ms）。
  private func frame(_ view: NSView, _ body: () -> Void) -> Double {
    let began = Date()
    body()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    return Date().timeIntervalSince(began) * 1000
  }

  /// 中央値・p95・最大（ms。`digits` は小数の桁数）。
  private func report(_ label: String, _ name: String, _ times: [Double], digits: Int = 1) {
    let sorted = times.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    let format = "%.\(digits)f"
    print(
      "PERF", label, name, "median", String(format: format, median), "p95",
      String(format: format, p95), "max", String(format: format, sorted.last ?? 0))
  }

  /// `bytes` を超えるまで同じ形の宣言を連ねた Swift の本文（1MB で 43,261 行）。
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

/// 編集の通知を文書へ流し、その呼び出しが戻るまでの時間（ms）を記録する delegate。
@MainActor
private final class EditTimer: TextSurfaceDelegate {
  let inner: EditorDocument
  private(set) var times: [Double] = []

  init(inner: EditorDocument) { self.inner = inner }

  func surface(_ surface: any TextSurface, didChange edit: TextEdit) {
    let began = DispatchTime.now().uptimeNanoseconds
    inner.surface(surface, didChange: edit)
    times.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
  }
  func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
    inner.surface(surface, focusDidChange: focused)
  }
  func surfaceDidChangeViewport(_ surface: any TextSurface) {
    inner.surfaceDidChangeViewport(surface)
  }
  func surfaceDidChangeSelection(_ surface: any TextSurface) {
    inner.surfaceDidChangeSelection(surface)
  }
  func surface(_ surface: any TextSurface, rolesIn range: NSRange) -> [HighlightSpan] {
    inner.surface(surface, rolesIn: range)
  }
  func surfaceLineCount(_ surface: any TextSurface) -> Int { inner.surfaceLineCount(surface) }
  func surface(_ surface: any TextSurface, lineContaining offset: Int) -> Int {
    inner.surface(surface, lineContaining: offset)
  }
  func surface(_ surface: any TextSurface, rangeOfLine line: Int) -> NSRange {
    inner.surface(surface, rangeOfLine: line)
  }
}
