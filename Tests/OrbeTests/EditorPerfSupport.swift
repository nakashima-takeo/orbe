import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エディターの計測（`EditorScrollPerfTests`・`EditorSyntaxPerfTests`）が文書を開く窓と、時間の出し方。
struct OpenedEditor {
  let tab: TerminalTab
  let pane: EditorPaneView
  let window: NSWindow
  let document: EditorDocument
}

extension OrbeTestCase {
  /// 1200×800 の窓に文書を開き、裏の仕事（文書全体の構文色）が追いつくのを待つ。
  @MainActor
  func openEditor(_ text: String, extension ext: String = "swift") throws -> OpenedEditor {
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: queries))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 1200, height: 800)
    window.appearance = NSAppearance(named: .darkAqua)
    let document = try tab.editor.open(try caseFile("big-\(UUID().uuidString).\(ext)", text))
    pane.layoutSubtreeIfNeeded()
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "本文が layout される")
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
    window.makeFirstResponder(document.surface.responder)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    return OpenedEditor(tab: tab, pane: pane, window: window, document: document)
  }

  /// 中央値・p95・最大（ms。`digits` は小数の桁数）。
  func reportPerf(_ label: String, _ name: String, _ times: [Double], digits: Int = 1) {
    let sorted = times.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    let format = "%.\(digits)f"
    print(
      "PERF", label, name, "median", String(format: format, median), "p95",
      String(format: format, p95), "max", String(format: format, sorted.last ?? 0))
  }
}
