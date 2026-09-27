import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorCore

/// エディターの計測（`EditorScrollPerfTests`・`EditorSyntaxPerfTests`）が文書を開く窓と、時間の出し方。
struct OpenedEditor {
  let tab: TerminalTab
  let pane: EditorPaneView
  let window: NSWindow
  let document: EditorDocument
}

/// 文書を開く前の窓とタブ。
struct EditorWindow {
  let tab: TerminalTab
  let pane: EditorPaneView
  let window: NSWindow
}

extension OrbeTestCase {
  /// 1200×800 の窓に文書を `engine` の面で開き、裏の仕事（文書全体の構文色）が追いつくのを待つ。
  @MainActor
  func openEditor(
    _ text: String, extension ext: String = "swift", engine: EditorEngineChoice = .stTextView
  ) throws -> OpenedEditor {
    let host = try editorWindow(engine: engine)
    let document = try host.tab.editor.open(try caseFile("big-\(UUID().uuidString).\(ext)", text))
    host.pane.layoutSubtreeIfNeeded()
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "本文が layout される")
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
    host.window.makeFirstResponder(document.surface.responder)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    return OpenedEditor(tab: host.tab, pane: host.pane, window: host.window, document: document)
  }

  /// 文書を開く前の、1200×800 の窓とタブ。
  @MainActor
  func editorWindow(engine: EditorEngineChoice = .stTextView) throws -> EditorWindow {
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: queries, engine: { engine }))
    let window = hostEditor(tab, width: 1200, height: 800)
    window.appearance = NSAppearance(named: .darkAqua)
    return EditorWindow(tab: tab, pane: tab.view.editor, window: window)
  }

  /// 文書が裏の結果を受け取って今の版に追いつくまで main を回す（裏を急かさない——本番と同じ経路）。
  @MainActor
  func pumpUntilCaughtUp(_ document: EditorDocument, timeout: TimeInterval = 60) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !document.isCaughtUp, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    }
    return document.isCaughtUp
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
