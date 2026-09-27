import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorCore

/// 構文の裏の仕事の計測。`ORBE_EDITOR_PERF=1` のときだけ走る（`scripts/perf-editor.sh` が回し、目標は
/// docs/testing/test-architecture.md）。結果は `PERF` で始まる行に出す。
@MainActor
final class EditorSyntaxPerfTests: OrbeTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  /// 構文の崩れる打鍵の裏の重さ。1MB の Swift と、タグ付きテンプレートを含む 1MB の JS の途中で `let v = f(` の `(` を
  /// 打った 1 回の後の、裏のスレッドの CPU 時間の総和（見えていない範囲の作り直しを含む）・見えている行の色が最終の色に
  /// なるまで・文書全体が揃うまで（どれも打鍵の前から）。続けて同じ崩れた文書で 30ms おきに 50 打鍵し、打ち続けた間と
  /// 止んでからの裏の CPU と、その間の構文解析の回数と、最後の打鍵から全体が揃うまでを出す。裏の CPU はプロセスの CPU から
  /// main スレッドの CPU を引いたもの。
  func testCrumblingKeystroke() throws {
    for (label, ext, text) in [
      ("1MB", "swift", EditorScrollPerfTests.swiftSource(bytes: 1_000_000)),
      ("1MB-js", "js", Self.taggedTemplateSource(bytes: 1_000_000)),
    ] {
      let opened = try openEditor(text, extension: ext)
      let document = opened.document
      let middle = document.text.lineCount / 2
      document.scroll(toFirstLine: CGFloat(middle - 10))
      document.surface.selectedRange = NSRange(location: document.text.lineStart(middle), length: 0)
      for character in "let v = f" {
        document.surface.responder.keyDown(with: .key(String(character), []))
      }
      XCTAssertTrue(document.waitUntilCaughtUp(timeout: 60))
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))

      var deliveries: [(time: Double, roles: [HighlightSpan])] = []
      let visible = { () -> NSRange in
        let lines = document.viewportLines
        let first = Int(lines.first)
        let start = document.text.lineStart(first)
        return NSRange(
          location: start,
          length: document.text.lineEnd(first + Int(lines.visible.rounded(.up))) - start)
      }
      let began = CPUClock()
      let minimap = document.onRolesChange
      document.onRolesChange = { changed in
        minimap?(changed)
        deliveries.append((began.elapsed, document.roles.roles(in: visible())))
      }
      let typed = began.elapsed
      document.surface.responder.keyDown(with: .key("(", []))
      XCTAssertTrue(pumpUntilCaughtUp(document))
      let complete = began.elapsed
      let cpu = began.backgroundCPU
      let final = document.roles.roles(in: visible())
      let settled =
        deliveries.first { delivery in
          deliveries.drop { $0.time < delivery.time }.allSatisfy { $0.roles == final }
        }?.time ?? typed
      print(
        "PERF", label, "crumbling-keystroke background-cpu", ms(cpu), "visible-final",
        ms(max(0, settled - typed)), "complete", ms(complete - typed), "deliveries",
        deliveries.count)

      document.onRolesChange = minimap
      let parsed = document.syntax?.parseCount ?? 0
      let burst = CPUClock()
      for index in 0..<50 {
        document.surface.responder.keyDown(with: .key(index % 2 == 0 ? "a" : "b", []))
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
      }
      let typing = burst.backgroundCPU
      let stopped = burst.elapsed
      XCTAssertTrue(pumpUntilCaughtUp(document))
      print(
        "PERF", label, "crumbled-burst(50x30ms) background-cpu typing", ms(typing), "after",
        ms(burst.backgroundCPU - typing), "parses", (document.syntax?.parseCount ?? 0) - parsed,
        "last-key-to-complete", ms(burst.elapsed - stopped))
      opened.window.orderOut(nil)
    }
  }

  /// 開いてから文書全体の役割が揃うまで（1MB の Swift・JS・Markdown）。開く直前から、急かさずに待って揃うまで——窓と
  /// ファイルの用意は区間の外。
  func testOpeningUntilComplete() throws {
    for (label, ext, text) in [
      ("1MB", "swift", EditorScrollPerfTests.swiftSource(bytes: 1_000_000)),
      ("1MB-js", "js", Self.taggedTemplateSource(bytes: 1_000_000)),
      ("1MB-md", "md", Self.markdownSource(bytes: 1_000_000)),
    ] {
      let times = try (0..<3).map { _ -> Double in
        let host = try editorWindow()
        let url = try caseFile("big-\(UUID().uuidString).\(ext)", text)
        let clock = CPUClock()
        let document = try host.tab.editor.open(url)
        host.pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pumpUntilCaughtUp(document))
        let elapsed = clock.elapsed
        host.window.orderOut(nil)
        return elapsed
      }
      reportPerf(label, "open-until-complete", times)
    }
  }

  private func ms(_ value: Double) -> String { String(format: "%.1f", value) }

  /// `bytes` を超えるまで、段落・インライン・コードブロックを含む同じ形の節を連ねた Markdown の本文。
  static func markdownSource(bytes: Int) -> String {
    let unit = """
      # Section

      Some *emphasis* and `code` with a [link](https://example.com) here.
      > quoted **strong** text

      ```js
      const value = compute(1); // note
      ```

      - item one
      - item `two`


      """
    var text = ""
    while text.utf8.count < bytes { text += unit }
    return text
  }

  /// `bytes` を超えるまで、タグ付きテンプレート（html / css の注入）を含む同じ形の宣言を連ねた JavaScript の本文。
  static func taggedTemplateSource(bytes: Int) -> String {
    let unit = """
      const view = html`<div class="item">${name}</div>`;
      const style = css`.item { color: red; }`;
      function render(items) {
        return items.map((item) => item.name + 1); // note
      }

      """
    var text = ""
    var k = 0
    while text.utf8.count < bytes {
      k += 1
      text += unit.replacingOccurrences(of: "view", with: "view\(k)")
        .replacingOccurrences(of: "render", with: "render\(k)")
    }
    return text
  }
}

/// 経過時間と、プロセスの CPU 時間から main スレッドの CPU 時間を引いた裏の CPU 時間（どちらも ms、作ってから）。main で作る。
@MainActor
private struct CPUClock {
  private let start = DispatchTime.now().uptimeNanoseconds
  private let process = CPUClock.processCPU()
  private let main = CPUClock.mainCPU()

  var elapsed: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
  var backgroundCPU: Double {
    (Self.processCPU() - process) - (Self.mainCPU() - main)
  }

  private static func processCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return milliseconds(usage.ru_utime) + milliseconds(usage.ru_stime)
  }

  private static func mainCPU() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
    let thread = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, thread) }
    _ = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
      }
    }
    return Double(info.user_time.seconds + info.system_time.seconds) * 1000
      + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
  }

  private static func milliseconds(_ time: timeval) -> Double {
    Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
  }
}
