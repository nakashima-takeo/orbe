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

  /// 1200×800 の窓に Swift の文書を開き、速いドラッグ → 打鍵 → ホイール → 打鍵の後の速いドラッグの順に測る。
  private func run(label: String, bytes: Int) throws {
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: queries))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 1200, height: 800)
    window.appearance = NSAppearance(named: .darkAqua)
    let document = try tab.editor.open(try caseFile("big.swift", Self.swiftSource(bytes: bytes)))
    pane.layoutSubtreeIfNeeded()
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "本文が layout される")
    window.makeFirstResponder(document.surface.responder)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let lines = document.lineIndex.lineCount
    print(
      "PERF", label, "env", ProcessInfo.processInfo.environment.count, "lines", lines, "bytes",
      document.lineIndex.length)

    let drag = { (name: String) in
      let rounds = (1...3).map { _ in self.fastDrag(pane, document) }
      print(
        "PERF", label, name, "updates/s min", String(format: "%.1f", rounds.min() ?? 0), "rounds",
        rounds.map { String(format: "%.1f", $0) }.joined(separator: " "))
    }
    drag("fast-drag")

    let middle = lines / 3
    document.scroll(toFirstLine: CGFloat(middle))
    document.surface.selectedRange = NSRange(
      location: document.lineIndex.start(ofRow: middle + 5) + 4, length: 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    var times: [Double] = []
    for character in "let value = compute(offset) ok" {
      times.append(
        frame(pane) { document.surface.responder.keyDown(with: .key(String(character), [])) })
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    report(label, "typing", times)

    let clip = try XCTUnwrap(document.surface.responder.enclosingScrollView).contentView
    times = (0..<60).map { _ in
      frame(pane) {
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 36))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
      }
    }
    report(label, "wheel", times)

    drag("fast-drag-after-typing")
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
  private func frame(_ pane: EditorPaneView, _ body: () -> Void) -> Double {
    let began = Date()
    body()
    pane.layoutSubtreeIfNeeded()
    pane.displayIfNeeded()
    return Date().timeIntervalSince(began) * 1000
  }

  private func report(_ label: String, _ name: String, _ times: [Double]) {
    let sorted = times.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    print(
      "PERF", label, name, "median", String(format: "%.1f", median), "p95",
      String(format: "%.1f", p95), "max", String(format: "%.1f", sorted.last ?? 0))
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
