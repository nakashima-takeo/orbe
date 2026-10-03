import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorCore

/// エディターの計測（`EditorTypingPerfTests`・`EditorSyntaxPerfTests`）が文書を開く窓と、時間の出し方。
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
  /// 1200×800 の窓に文書を開き、裏の仕事（文書全体の構文色）が追いつくのを待つ。
  @MainActor
  func openEditor(_ text: String, extension ext: String = "swift") throws -> OpenedEditor {
    let host = try editorWindow()
    let document = try host.tab.editor.open(try caseFile("big-\(UUID().uuidString).\(ext)", text))
    host.pane.layoutSubtreeIfNeeded()
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "面が大きさを持つ")
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
    host.window.makeFirstResponder(document.surface.responder)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    return OpenedEditor(tab: host.tab, pane: host.pane, window: host.window, document: document)
  }

  /// 文書を開く前の、1200×800 の窓とタブ。
  @MainActor
  func editorWindow() throws -> EditorWindow {
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: queries))
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

extension EditorDocument {
  /// 面の見えている行の区間（先頭に見えている行から、見えている行の数を切り上げた行の終わりまで）。
  var visibleRange: NSRange {
    let viewport = surface.viewport
    let first = text.row(containing: viewport.firstVisible)
    let start = text.lineStart(first)
    return NSRange(
      location: start, length: text.lineEnd(first + Int(viewport.visibleLines.rounded(.up))) - start
    )
  }

  /// 打鍵 `typed` の後、裏の仕事が追いつくまで main を回し、裏から届いた結果で見えている行の役割が変わるたびに時刻（ms、
  /// `since` から）とその役割を記録する（打鍵がその場でずらした役割から数える。裏を急かさない——本番と同じ経路）。
  func visibleRoleChanges(
    after typed: () -> Void, since start: UInt64, timeout: TimeInterval = 60
  ) -> [(time: Double, roles: [HighlightSpan])] {
    typed()
    var last = roles.roles(in: visibleRange)
    var changes: [(time: Double, roles: [HighlightSpan])] = []
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.001))
      let now = roles.roles(in: visibleRange)
      if now != last {
        changes.append((Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, now))
        last = now
      }
    } while !isCaughtUp && Date() < deadline
    return changes
  }
}
