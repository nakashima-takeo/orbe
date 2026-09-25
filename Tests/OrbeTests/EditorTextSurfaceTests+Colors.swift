import AppKit
import OrbeEditorCore
import STTextView
import XCTest

@testable import Orbe

/// エンジンの色の窓——構文の色は上流が layout した範囲（見えている範囲と先読みの帯）にだけ置き、その中の色は常に文書の
/// 今の役割と一致する。
///
/// 壊れると何が起きるか。遠くへ飛んだ先の字が色無しで出る、打鍵で役割の変わった隣の字（呼び出しになった識別子・閉じた
/// 文字列の後ろ）が古い色のまま残る、undo や外部変更の差し替えの後に古い色が別の字に付く。窓の外に色が溜まれば、打鍵と
/// スクロールが文書の大きさに比例して重くなる。
@MainActor
final class EditorTextSurfaceColorTests: OrbeTestCase {
  private let roleColors = EditorStyle.make().roleColors

  /// Swift の文書を 600×400 の面で開く。
  private func open(_ text: String) throws -> (EditorDocument, NSWindow) {
    let session = EditorSession(
      surfaces: EditorSurfaces(
        queriesRoot: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()))
    let url = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(
      "c-\(UUID().uuidString).swift")
    try Data(text.utf8).write(to: url)
    let document = try session.open(url)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = document.surface.view
    document.surface.view.frame = try XCTUnwrap(window.contentView).bounds
    window.makeFirstResponder(document.surface.responder)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    settle(document)
    withExtendedLifetime(session) {}
    return (document, window)
  }

  private func settle(_ document: EditorDocument) {
    document.surface.view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    document.surface.view.layoutSubtreeIfNeeded()
  }

  private func textView(_ document: EditorDocument) throws -> STTextView {
    try XCTUnwrap(document.surface.responder as? STTextView)
  }

  /// 置かれている色の区間（本文のオフセット）。
  private func colored(_ document: EditorDocument) throws -> [(range: NSRange, color: NSColor)] {
    let view = try textView(document)
    let manager = view.textContentManager
    var runs: [(NSRange, NSColor)] = []
    view.textLayoutManager.enumerateRenderingAttributes(
      from: manager.documentRange.location, reverse: false
    ) { _, attributes, range in
      if let color = attributes[.foregroundColor] as? NSColor {
        runs.append((NSRange(range, in: manager), color))
      }
      return true
    }
    return runs
  }

  /// 字ごとの色（無ければ nil）が、文書の今の役割の色と一致しない字。
  private func mismatches(_ document: EditorDocument, in range: NSRange) throws -> [Int] {
    let runs = try colored(document)
    let roles = document.roleSpans(in: range)
    return (range.location..<NSMaxRange(range)).filter { offset in
      let shown = runs.first { NSLocationInRange(offset, $0.range) }?.color
      let role = roles.first { NSLocationInRange(offset, $0.range) }?.role
      return shown != role.flatMap { roleColors[$0] }
    }
  }

  /// 上流が layout した範囲。
  private func window(_ document: EditorDocument) throws -> NSRange {
    let view = try textView(document)
    let range = try XCTUnwrap(view.textLayoutManager.textViewportLayoutController.viewportRange)
    return NSRange(range, in: view.textContentManager)
  }

  /// 窓の中の字はすべて役割どおりの色で、窓の外に色は無い。
  private func assertColorsFollowTheWindow(
    _ document: EditorDocument, _ message: String, file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let window = try window(document)
    XCTAssertGreaterThan(window.length, 0, message, file: file, line: line)
    XCTAssertEqual(try mismatches(document, in: window), [], message, file: file, line: line)
    let outside = try colored(document).filter { NSIntersectionRange($0.range, window) != $0.range }
    XCTAssertTrue(
      outside.isEmpty, "\(message): 窓 \(window) の外に色 \(outside.map(\.range))", file: file,
      line: line)
  }

  private func source(_ lines: Int) -> String {
    (1...lines).map { "let value\($0) = compute(\($0)) // note \($0)\n" }.joined()
  }

  func testColorsStayInsideTheWindowWhileScrolling() throws {
    let (document, _) = try open(source(3000))
    try assertColorsFollowTheWindow(document, "開いた直後")
    XCTAssertLessThan(try window(document).length, document.lineIndex.length / 10, "全文には塗らない")
    for line: CGFloat in [1500, 1510, 2990, 0] {
      document.scroll(toFirstLine: line)
      settle(document)
      try assertColorsFollowTheWindow(document, "\(line) 行目へ")
    }
  }

  /// 見えている行（先頭に見えている行から可視行数ぶん）の区間。
  private func visibleLines(_ document: EditorDocument) -> NSRange {
    let index = document.lineIndex
    let (first, visible) = document.viewportLines
    let last = min(index.lineCount - 1, Int(first + visible) + 1)
    let start = index.start(ofRow: Int(first))
    return NSRange(location: start, length: index.end(ofRow: last) - start)
  }

  /// 打鍵のたび、その呼び出しの中で見えている字の色が編集の後の役割に揃う（layout を待たない）。`compute` の後ろを
  /// 消すと呼び出しでなくなり、`"` を打てば行末まで文字列になる——どちらも編集した字の外の役割が変わる。
  func testAnEditRecolorsTheVisibleTextWithinTheSameCall() throws {
    let (document, _) = try open(source(200))
    let call = (document.surface.text as NSString).range(of: "(3)")
    document.surface.selectedRange = NSRange(location: call.location, length: 3)
    document.surface.responder.deleteBackward(nil)
    XCTAssertEqual(try mismatches(document, in: visibleLines(document)), [], "括弧を消した直後")

    let quote = document.lineIndex.start(ofRow: 5)
    document.surface.selectedRange = NSRange(location: quote, length: 0)
    document.surface.responder.keyDown(with: .key("\"", []))
    XCTAssertEqual(try mismatches(document, in: visibleLines(document)), [], "引用符を打った直後")
    settle(document)
    try assertColorsFollowTheWindow(document, "layout の後")

    document.surface.responder.undoManager?.undo()
    XCTAssertEqual(try mismatches(document, in: visibleLines(document)), [], "undo の直後")
    settle(document)
    try assertColorsFollowTheWindow(document, "undo の layout の後")
  }

  /// 本文を丸ごと置き換えても、古い色が新しい字に残らず、窓の外にも残らない。
  func testReplacingTheWholeTextLeavesNoStaleColors() throws {
    let (document, _) = try open(source(3000))
    document.scroll(toFirstLine: 1200)
    settle(document)
    document.surface.replaceAll(with: (1...2000).map { "// comment \($0)\n" }.joined())
    let stale = try colored(document).filter { $0.color != roleColors[.comment] }
    XCTAssertTrue(stale.isEmpty, "置き換えの直後に古い色が残る: \(stale.map(\.range))")
    settle(document)
    try assertColorsFollowTheWindow(document, "置き換えの layout の後")
  }
}
