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

  /// 1MB の Swift で、アウトラインを開いたときと閉じたときの打鍵 1 回の main の仕事（`typing-main` と同じ区間）。開いても
  /// 中央値が閉じたときの 1.5 倍を超えない（文書の大きさ・シンボルの数に比例する仕事が打鍵に乗らない）。
  func testTypingMainTimeWithTheOutlineOpen() throws {
    let text = EditorScrollPerfTests.swiftSource(bytes: 1_000_000)
    var medians: [Bool: Double] = [:]
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
      medians[open] = timer.times.sorted()[timer.times.count / 2]
      opened.document.surface.delegate = opened.document
      opened.window.orderOut(nil)
    }
    let closed = try XCTUnwrap(medians[false])
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(medians[true]), closed * 1.5, "開いても打鍵 1 回の main の仕事の中央値が変わらない")
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

  /// 大きな文書（1MB の Swift・800KB と 5MB の package-lock.json 相当・要素の多い配列の JSON・深い入れ子の JSON）で、
  /// アウトラインの main の仕事——結果の受け取り（開いたときと、編集して取り直したとき）・カーソル追従 1 回・開閉 1 回・
  /// すべて折りたたむ／展開・絞り込みの打鍵 1 回とその結果の受け取り・列の 1 行送りと 1 画面送り。どれも面の layout と
  /// 描画まで——と、開いてから結果が届くまでの裏の時間。main の仕事（数え方は docs/testing/test-architecture.md）は、
  /// どれも p95 が 1 コマの予算（8ms）以内。開いてから結果が届くまでは、深い入れ子の他は 1MB あたり 1 秒以内（要素の数の 2 乗の仕事が
  /// 無い）。深い入れ子は、問い合わせが深さの 2 乗になる上流の性質を受け入れて値を出すだけ。
  func testOutlineMainWorkOnLargeDocuments() throws {
    for (label, ext, text) in [
      ("1MB-swift", "swift", EditorScrollPerfTests.swiftSource(bytes: 1_000_000)),
      ("800KB-json", "json", Self.packageLock(bytes: 800_000)),
      ("5MB-json", "json", Self.packageLock(bytes: 5_000_000)),
      ("2MB-array-json", "json", Self.recordArray(bytes: 2_000_000)),
      ("deep-json", "json", Self.nestedArrays(depth: 1_000)),
    ] {
      let opened = try openEditor(text, extension: ext)
      let document = opened.document
      let outline = opened.pane.outline
      var received: [Double] = []
      let forward = document.onOutlineChange
      document.onOutlineChange = {
        received.append(self.frame(opened.pane) { forward?() })
      }
      let extraction = try openOutline(opened) * 1000
      let symbols = document.outline?.symbols.count ?? 0
      print(
        "PERF", label, "outline-extract (開いてから結果まで・裏)", String(format: "%.1f", extraction),
        "symbols", symbols, "rows", outline.rowCount)
      if label != "deep-json" {
        XCTAssertLessThanOrEqual(
          extraction, Double(text.utf8.count) / 1000, "\(label): 開いてから結果まで 1MB あたり 1 秒以内")
      }
      report(label, "outline-receive", received)

      received = []
      for index in 0..<3 {
        document.surface.selectedRange = NSRange(
          location: document.text.lineStart(1 + index), length: 0)
        document.surface.responder.keyDown(with: .key(" ", []))
        XCTAssertTrue(pumpUntilCaughtUp(document))
      }
      report(label, "outline-refresh-receive (編集して取り直した結果)", received)

      let length = document.text.length
      let follows = (0..<30).map { index in
        document.surface.selectedRange = NSRange(location: length * (index + 1) / 32, length: 0)
        // キャレットを動かした本文の描き直しは区間の外（追従の仕事だけを測る）。
        _ = frame(opened.pane) {}
        return frame(opened.pane) { outline.follow() }
      }
      report(label, "outline-follow", follows)

      reportFolding(label, opened)

      received = []
      var typed: [Double] = []
      for prefix in ["n", "na", "nam", "name"] {
        typed.append(frame(opened.pane) { outline.setFilterText(prefix) })
        XCTAssertTrue(pumpUntilCaughtUp(document))
      }
      report(label, "outline-filter-keystroke", typed)
      report(label, "outline-filter-receive", received)
      outline.clearFilter()
      XCTAssertTrue(pumpUntilCaughtUp(document))

      try reportScroll(label, opened)
      document.onOutlineChange = forward
      opened.window.orderOut(nil)
    }
  }

  /// 開閉 1 回と、すべて折りたたむ／展開（描画まで）。
  private func reportFolding(_ label: String, _ opened: OpenedEditor) {
    let outline = opened.pane.outline
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
    report(label, "outline-toggle", toggles)
    let all = (0..<6).map { _ in frame(opened.pane) { outline.toggleCollapseAll() } }
    report(label, "outline-collapse-all", all)
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
    report(label, "outline-scroll-row", rowStep)
    let pageStep = (0..<30).map { _ in
      frame(opened.pane) {
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + clip.bounds.height))
        list.scrollView.reflectScrolledClipView(clip)
      }
    }
    report(label, "outline-scroll-page", pageStep)
  }

  /// サイドバーをエクスプローラーで開き、アウトラインを開いて、結果が揃うまで待つ（裏を急かさない）。開いてから結果が
  /// 揃うまでの秒を返す。
  @discardableResult
  private func openOutline(_ opened: OpenedEditor) throws -> TimeInterval {
    let began = Date()
    let sidebar = opened.pane.sidebar
    if !sidebar.isOpen || sidebar.panel != .files { sidebar.select(.files) }
    if !sidebar.isOutlineOpen { sidebar.toggleOutline() }
    pumpMain(until: { opened.document.wantsOutline }, "アウトラインが要ると告げる")
    XCTAssertTrue(pumpUntilCaughtUp(opened.document))
    let elapsed = Date().timeIntervalSince(began)
    opened.pane.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    return elapsed
  }

  /// 値を出し、p95 が 1 コマの予算（8ms）以内であることを見る。
  private func report(_ label: String, _ name: String, _ times: [Double]) {
    reportPerf(label, name, times, digits: 3)
    let sorted = times.sorted()
    XCTAssertLessThanOrEqual(
      sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], 8,
      "\(label): \(name) の main のスレッドの CPU 時間の p95")
  }

  /// `body` の main のスレッドの CPU 時間（ms）。
  private static func measure(_ body: () -> Void) -> Double {
    let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    body()
    return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1_000_000
  }

  private func frame(_ view: NSView, _ body: () -> Void) -> Double {
    Self.measure {
      body()
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
    }
  }

  /// `bytes` を超えるまでレコードを連ねた配列の JSON（データの書き出し・API の fixture 相当。要素ごとに 4 つのキーと
  /// 3 要素の配列）。
  static func recordArray(bytes: Int) -> String {
    var text = "[\n"
    var k = 0
    while text.utf8.count < bytes {
      if k > 0 { text += ",\n" }
      text +=
        "  {\"id\": \(k), \"name\": \"item-\(k)\", \"score\": \(k % 100), \"tags\": [\"a\", \"b\", \"c\"]}"
      k += 1
    }
    return text + "\n]\n"
  }

  /// 配列を `depth` 段入れ子にした JSON（各段に値 1 つ）。
  static func nestedArrays(depth: Int) -> String {
    String(repeating: "[1,\n", count: depth) + String(repeating: "]", count: depth) + "\n"
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
