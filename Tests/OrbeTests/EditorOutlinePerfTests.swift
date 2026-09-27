import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorCore

/// アウトラインの計測。`ORBE_EDITOR_PERF=1` のときだけ走る（`scripts/perf-editor.sh` が回し、目標は
/// docs/testing/test-architecture.md）。結果は `PERF` で始まる行に出す。
@MainActor
final class EditorOutlinePerfTests: OrbeTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  /// 1MB の Swift で、アウトラインを開いたときと閉じたときの打鍵 1 回の main の仕事（`typing-main` と同じ区間）。
  func testTypingMainTimeWithTheOutlineOpen() throws {
    let text = EditorScrollPerfTests.swiftSource(bytes: 1_000_000)
    for open in [false, true] {
      let opened = try openEditor(text)
      if open { try openOutline(opened) }
      let timer = EditTimer(inner: opened.document)
      opened.document.surface.delegate = timer
      let document = opened.document
      let middle = document.text.lineCount / 3
      document.scroll(toFirstLine: CGFloat(middle))
      document.surface.selectedRange = NSRange(
        location: document.text.lineStart(middle + 5) + 4, length: 0)
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      for character in "let value = compute(offset) ok" {
        document.surface.responder.keyDown(with: .key(String(character), []))
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
      }
      reportPerf(
        "1MB", open ? "typing-main (アウトラインを開いて)" : "typing-main", timer.times, digits: 3)
      opened.document.surface.delegate = opened.document
      opened.window.orderOut(nil)
    }
  }

  /// 1MB の Swift の途中で構文の崩れる打鍵（`let v = f` の後の `(`）をしたとき、打鍵から見えている行の色が最終の色に
  /// なるまで（`crumbling-keystroke` の `visible-final` と同じ区間）を、アウトラインを開いたときと閉じたときで並べる——
  /// 取り出しは専用の裏の仕事なので、見えている行の色を待たせない。
  func testVisibleColorsDoNotWaitForTheOutline() throws {
    let text = EditorScrollPerfTests.swiftSource(bytes: 1_000_000)
    for open in [false, true] {
      let opened = try openEditor(text)
      if open { try openOutline(opened) }
      let document = opened.document
      let middle = document.text.lineCount / 2
      document.scroll(toFirstLine: CGFloat(middle - 10))
      document.surface.selectedRange = NSRange(location: document.text.lineStart(middle), length: 0)
      for character in "let v = f" {
        document.surface.responder.keyDown(with: .key(String(character), []))
      }
      XCTAssertTrue(pumpUntilCaughtUp(document))
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      let visible = { () -> NSRange in
        let lines = document.viewportLines
        let first = Int(lines.first)
        let start = document.text.lineStart(first)
        return NSRange(
          location: start,
          length: document.text.lineEnd(first + Int(lines.visible.rounded(.up))) - start)
      }
      var deliveries: [(time: Double, roles: [HighlightSpan])] = []
      let began = DispatchTime.now().uptimeNanoseconds
      let elapsed = { Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000 }
      let minimap = document.onRolesChange
      document.onRolesChange = { changed in
        minimap?(changed)
        deliveries.append((elapsed(), document.roles.roles(in: visible())))
      }
      document.surface.responder.keyDown(with: .key("(", []))
      XCTAssertTrue(pumpUntilCaughtUp(document))
      let final = document.roles.roles(in: visible())
      let settled =
        deliveries.first { delivery in
          deliveries.drop { $0.time < delivery.time }.allSatisfy { $0.roles == final }
        }?.time ?? 0
      print(
        "PERF", "1MB", open ? "visible-final (アウトラインを開いて)" : "visible-final",
        String(format: "%.1f", settled))
      document.onRolesChange = minimap
      opened.window.orderOut(nil)
    }
  }

  /// 大きな文書（1MB の Swift・800KB と 5MB の package-lock.json 相当）で、アウトラインの main の仕事——結果の受け取り・
  /// カーソル追従 1 回・開閉 1 回・すべて折りたたむ／展開・絞り込みの打鍵 1 回とその結果の受け取り・列の 1 行送りと
  /// 1 画面送り。どれも面の layout と描画まで——と、開いてから結果が届くまでの裏の時間。
  func testOutlineMainWorkOnLargeDocuments() throws {
    for (label, ext, text) in [
      ("1MB-swift", "swift", EditorScrollPerfTests.swiftSource(bytes: 1_000_000)),
      ("800KB-json", "json", Self.packageLock(bytes: 800_000)),
      ("5MB-json", "json", Self.packageLock(bytes: 5_000_000)),
    ] {
      let opened = try openEditor(text, extension: ext)
      let document = opened.document
      let outline = opened.pane.outline
      var received: [Double] = []
      let forward = document.onOutlineChange
      document.onOutlineChange = {
        received.append(self.frame(opened.pane) { forward?() })
      }
      let began = Date()
      try openOutline(opened)
      let extraction = Date().timeIntervalSince(began) * 1000
      let symbols = document.outline?.symbols.count ?? 0
      print(
        "PERF", label, "outline-extract (開いてから結果まで・裏)", String(format: "%.1f", extraction),
        "symbols", symbols, "rows", outline.rowCount)
      reportPerf(label, "outline-receive", received, digits: 3)

      let length = document.text.length
      let follows = (0..<30).map { index in
        document.surface.selectedRange = NSRange(location: length * (index + 1) / 32, length: 0)
        // キャレットを動かした本文の描き直しは区間の外（追従の仕事だけを測る）。
        _ = frame(opened.pane) {}
        return frame(opened.pane) { outline.follow() }
      }
      reportPerf(label, "outline-follow", follows, digits: 3)

      let parents = (0..<min(outline.rowCount, 400)).map(outline.row(at:)).filter(\.hasChildren)
      let toggles = parents.prefix(30).flatMap { row in
        [
          frame(opened.pane) { outline.setExpanded(row.symbol, false) },
          frame(opened.pane) { outline.setExpanded(row.symbol, true) },
        ]
      }
      _ = frame(opened.pane) { outline.setExpanded(parents[0].symbol, false) }
      XCTAssertEqual(
        opened.pane.outlineList.scrollView.list.rowCount, outline.rowCount,
        "前提: 描画までの区間に列の読み直しが入っている")
      outline.setExpanded(parents[0].symbol, true)
      reportPerf(label, "outline-toggle", toggles, digits: 3)
      let all = (0..<6).map { _ in frame(opened.pane) { outline.toggleCollapseAll() } }
      reportPerf(label, "outline-collapse-all", all, digits: 3)

      received = []
      var typed: [Double] = []
      for prefix in ["n", "na", "nam", "name"] {
        typed.append(frame(opened.pane) { outline.setFilterText(prefix) })
        XCTAssertTrue(pumpUntilCaughtUp(document))
      }
      reportPerf(label, "outline-filter-keystroke", typed, digits: 3)
      reportPerf(label, "outline-filter-receive", received, digits: 3)
      outline.clearFilter()
      XCTAssertTrue(pumpUntilCaughtUp(document))

      try reportScroll(label, opened)
      document.onOutlineChange = forward
      opened.window.orderOut(nil)
    }
  }

  /// 列の 1 行送りと 1 画面送り（描画まで）。
  private func reportScroll(_ label: String, _ opened: OpenedEditor) throws {
    let list = opened.pane.outlineList
    let clip = list.scrollView.contentView
    let rowStep = (0..<60).map { _ in
      frame(opened.pane) {
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + Theme.Layout.editorRow))
        list.scrollView.reflectScrolledClipView(clip)
      }
    }
    reportPerf(label, "outline-scroll-row", rowStep, digits: 3)
    let pageStep = (0..<30).map { _ in
      frame(opened.pane) {
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + clip.bounds.height))
        list.scrollView.reflectScrolledClipView(clip)
      }
    }
    reportPerf(label, "outline-scroll-page", pageStep, digits: 3)
  }

  /// サイドバーをエクスプローラーで開き、アウトラインを開いて、結果が揃うまで待つ（裏を急かさない）。
  private func openOutline(_ opened: OpenedEditor) throws {
    let sidebar = opened.pane.sidebar
    if !sidebar.isOpen || sidebar.panel != .files { sidebar.select(.files) }
    if !sidebar.isOutlineOpen { sidebar.toggleOutline() }
    pumpMain(until: { opened.document.wantsOutline }, "アウトラインが要ると告げる")
    XCTAssertTrue(pumpUntilCaughtUp(opened.document))
    opened.pane.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  }

  private static func measure(_ body: () -> Void) -> Double {
    let began = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
  }

  private func frame(_ view: NSView, _ body: () -> Void) -> Double {
    Self.measure {
      body()
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
    }
  }

  /// `bytes` を超えるまでパッケージを連ねた package-lock.json 相当の本文（1 つに 8〜9 個のキー）。
  static func packageLock(bytes: Int) -> String {
    var text = "{\n  \"name\": \"sample\",\n  \"lockfileVersion\": 3,\n  \"packages\": {\n"
    var k = 0
    while text.utf8.count < bytes {
      if k > 0 { text += ",\n" }
      text += """
            "node_modules/package-\(k)": {
              "version": "1.\(k % 50).\(k % 7)",
              "resolved": "https://registry.npmjs.org/package-\(k)/-/package-\(k)-1.0.0.tgz",
              "integrity": "sha512-\(String(repeating: "a", count: 40))\(k)",
              "dev": true,
              "license": "MIT",
              "dependencies": {
                "name-\(k % 97)": "^2.0.0",
                "other-\(k % 89)": "~1.4.0"
              }
            }
        """
      k += 1
    }
    return text + "\n  }\n}\n"
  }
}
