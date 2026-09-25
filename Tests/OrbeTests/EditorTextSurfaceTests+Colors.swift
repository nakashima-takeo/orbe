import AppKit
import OrbeEditorCore
import STTextView
import XCTest

@testable import Orbe

/// エンジンの色の窓——構文の色は見えている行にだけ塗り、上流が layout した範囲（見えている範囲と先読みの帯）の外には
/// 置かない。見えている字の色は常に文書の今の役割と一致する。先読みの帯はスクロールで見えたときに塗る。
///
/// 壊れると何が起きるか。遠くへ飛んだ先の字や、スクロールで帯から見えてきた字が色無しで出る。打鍵で役割の変わった隣の字
/// （呼び出しになった識別子・閉じた文字列の後ろ）が古い色のまま残る、undo や外部変更の差し替えの後に古い色が別の字に付く。
/// 窓の外に色が溜まる・見えない帯まで塗れば、打鍵とスクロールが重くなる。
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

  /// 見えている行の区間（先頭に見えている行から可視行数ぶん）。
  private func visibleLines(_ document: EditorDocument) -> NSRange {
    let index = document.lineIndex
    let (first, visible) = document.viewportLines
    let last = min(index.lineCount - 1, Int((first + visible).rounded(.up)) - 1)
    let start = index.start(ofRow: Int(first))
    return NSRange(location: start, length: index.end(ofRow: last) - start)
  }

  /// 見えている字はすべて役割どおりの色で、窓の外に色は無い。
  private func assertColorsFollowTheWindow(
    _ document: EditorDocument, _ message: String, file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let window = try window(document)
    XCTAssertGreaterThan(window.length, 0, message, file: file, line: line)
    XCTAssertEqual(
      try mismatches(document, in: visibleLines(document)), [], message, file: file, line: line)
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

  /// 打鍵の後、描く前の layout で見えている字の色が編集の後の役割に揃う。`compute` の後ろを消すと呼び出しでなくなり、
  /// `"` を打てば行末まで文字列になる——どちらも編集した字の外の役割が変わる。
  func testAnEditRecolorsTheVisibleTextBeforeItIsDrawn() throws {
    let (document, _) = try open(source(200))
    let view = document.surface.view
    let call = (document.surface.text as NSString).range(of: "(3)")
    document.surface.selectedRange = NSRange(location: call.location, length: 3)
    document.surface.responder.deleteBackward(nil)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(try mismatches(document, in: visibleLines(document)), [], "括弧を消した後の layout")

    let quote = document.lineIndex.start(ofRow: 5)
    document.surface.selectedRange = NSRange(location: quote, length: 0)
    document.surface.responder.keyDown(with: .key("\"", []))
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(try mismatches(document, in: visibleLines(document)), [], "引用符を打った後の layout")
    try assertColorsFollowTheWindow(document, "layout の後")

    document.surface.responder.undoManager?.undo()
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(try mismatches(document, in: visibleLines(document)), [], "undo の後の layout")
    try assertColorsFollowTheWindow(document, "undo の layout の後")
  }

  /// 打鍵の直後の描画で、役割の変わった字が古い色で出ない。6 行目の頭に `"` を打つと、同じ行の `let` は keyword の青から
  /// 文字列の色になる。画素は描き直しを強いない層の写しから読む。
  func testTheFrameAfterAnEditDrawsTheNewColors() throws {
    let (document, _) = try open(source(200))
    let view = document.surface.view
    view.displayIfNeeded()
    let style = EditorStyle.make()
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    let left = style.gutterWidth + style.marks.gutterWidth
    let row = NSRect(
      x: left + cell, y: style.topInset + 5 * style.lineHeight, width: 3 * cell,
      height: style.lineHeight)
    let before = try drawnShot(view, inking: row.offsetBy(dx: -cell, dy: 0))
    XCTAssertGreaterThan(before.bluest(in: row.offsetBy(dx: -cell, dy: 0)), 0.3, "前提: `let` は青")

    document.surface.selectedRange = NSRange(
      location: document.lineIndex.start(ofRow: 5), length: 0)
    document.surface.responder.keyDown(with: .key("\"", []))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let shot = try drawnShot(view, inking: row)
    XCTAssertLessThan(shot.bluest(in: row), 0.1, "keyword の青が残らない")
    XCTAssertGreaterThan(shot.reddest(in: row), 0.3, "文字列の色で描かれる")
  }

  /// 先読みの帯は見えるまで塗らない。窓の中の小さなスクロール（上流は layout しない）で帯から見えてきた行は、その
  /// スクロールの中で塗られ、描き直しを待たずに色付きで描かれる。
  func testTheBandIsColoredWhenItScrollsIntoView() throws {
    let (document, _) = try open(source(3000))
    let view = document.surface.view
    let visible = visibleLines(document)
    let band = try window(document)
    XCTAssertGreaterThan(NSMaxRange(band), NSMaxRange(visible) + 200, "前提: 下に帯がある")
    let beyond = try colored(document).filter { $0.range.location >= NSMaxRange(visible) }
    XCTAssertEqual(beyond.map(\.range), [], "帯は見えるまで塗らない")
    view.displayIfNeeded()

    let clip = try XCTUnwrap(document.surface.responder.enclosingScrollView).contentView
    let style = EditorStyle.make()
    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 3 * style.lineHeight))
    XCTAssertEqual(try window(document), band, "前提: 窓の中のスクロール")
    XCTAssertEqual(try mismatches(document, in: visibleLines(document)), [], "スクロールの中で塗る")

    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let shot = try layerShot(view)
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    let left = style.gutterWidth + style.marks.gutterWidth
    let lastRow =
      clip.bounds.height - style.lineHeight
      - (clip.bounds.height.truncatingRemainder(
        dividingBy: style.lineHeight))
    let bottomLet = NSRect(
      x: left, y: style.topInset + lastRow, width: 3 * cell, height: style.lineHeight)
    XCTAssertGreaterThan(shot.bluest(in: bottomLet), 0.3, "帯から見えてきた行の `let` が keyword の色で描かれる")
  }

  /// 塗った行を二度問い合わせない——窓の中のスクロールで問い合わせるのは新しく見えた行だけで、塗り済みの位置へ戻っても
  /// 問い合わせない。
  func testScrollingQueriesOnlyTheNewlyVisibleLines() throws {
    let (document, _) = try open(source(3000))
    let counter = RolesCounter(inner: document)
    document.surface.delegate = counter
    let clip = try XCTUnwrap(document.surface.responder.enclosingScrollView).contentView
    let style = EditorStyle.make()
    let before = visibleLines(document)
    clip.scroll(to: NSPoint(x: 0, y: 3 * style.lineHeight))
    let after = visibleLines(document)
    let revealed = NSRange(
      location: NSMaxRange(before), length: NSMaxRange(after) - NSMaxRange(before))
    XCTAssertFalse(counter.queried.isEmpty, "新しく見えた行は問い合わせる")
    XCTAssertTrue(
      counter.queried.allSatisfy { NSIntersectionRange($0, revealed) == $0 },
      "問い合わせは新しく見えた行 \(revealed) だけ: \(counter.queried)")

    counter.queried = []
    clip.scroll(to: .zero)
    settle(document)
    XCTAssertEqual(counter.queried, [], "塗り済みの位置へ戻っても問い合わせない")
    document.surface.responder.needsLayout = true
    document.surface.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(counter.queried, [], "layout し直しても塗り済みの行は問い合わせない")
    withExtendedLifetime(counter) {}
  }

  /// 打鍵の塗り直しは見えている行に閉じ、帯の色は見えたときに塗り直す。先頭の行に `/*` を打つと、帯の先の `*/` まで
  /// コメントになる（帯の行の役割が変わる）。
  func testAnEditRepaintsOnlyTheVisibleLinesAndTheBandWhenItComesIntoView() throws {
    var lines = source(3000).components(separatedBy: "\n")
    lines[40] = "// */"
    let (document, _) = try open(lines.joined(separator: "\n"))
    let clip = try XCTUnwrap(document.surface.responder.enclosingScrollView).contentView
    let style = EditorStyle.make()
    clip.scroll(to: NSPoint(x: 0, y: 3 * style.lineHeight))
    let row = Int(document.viewportLines.first + document.viewportLines.visible) - 1
    clip.scroll(to: .zero)
    settle(document)
    let keyword = NSRange(location: document.lineIndex.start(ofRow: row), length: 3)
    XCTAssertGreaterThan(keyword.location, NSMaxRange(visibleLines(document)), "前提: 帯の行")
    XCTAssertEqual(try mismatches(document, in: keyword), [], "前提: 帯の `let` は塗ってある")

    document.surface.selectedRange = NSRange(location: 0, length: 0)
    document.surface.responder.insertText("/*")
    settle(document)
    let shifted = NSRange(location: keyword.location + 2, length: 3)
    XCTAssertEqual(document.roleSpans(in: shifted).first?.role, .comment, "前提: 帯の行もコメントになる")
    XCTAssertEqual(try mismatches(document, in: visibleLines(document)), [], "見えている行は塗り直す")
    XCTAssertEqual(try mismatches(document, in: shifted).count, 3, "帯は塗り直さない（古い色のまま）")

    clip.scroll(to: NSPoint(x: 0, y: 3 * style.lineHeight))
    XCTAssertEqual(try mismatches(document, in: visibleLines(document)), [], "見えてきた行はコメントの色")
  }

  /// 本文を丸ごと置き換えても、古い色が新しい字に残らず、窓の外にも残らない。置き換えの後の選択はキャレットの位置へ
  /// スクロールするので、キャレットを見えている行に置き、行の形を変えない置き換えにする。
  func testReplacingTheWholeTextLeavesNoStaleColors() throws {
    let (document, _) = try open(source(3000))
    document.scroll(toFirstLine: 1200)
    settle(document)
    document.surface.selectedRange = NSRange(location: visibleLines(document).location, length: 0)
    document.surface.replaceAll(with: source(3000).replacingOccurrences(of: "let ", with: "//  "))
    document.surface.view.layoutSubtreeIfNeeded()
    try assertColorsFollowTheWindow(document, "置き換えの後の layout")
    let stale = try colored(document).filter { $0.color != roleColors[.comment] }
      .filter { NSIntersectionRange($0.range, visibleLines(document)).length > 0 }
    XCTAssertTrue(stale.isEmpty, "見えている行に古い色が残る: \(stale.map(\.range))")
  }

  /// 遠くへ飛んだ先の字は色付きで描かれ、描き直しを待たない（色は layout の中・描く前に置くので、layout をやり直さない。
  /// 描いた後に色を置いていれば、次の layout まで素の文字色のまま残る）。画素は描き直しを強いない層の写しから読む——
  /// `cacheDisplay` は全部を描き直すので、描き直し忘れが見えない。
  func testAFarJumpDrawsTheColors() throws {
    let (document, window) = try open(source(3000))
    let view = document.surface.view
    window.displayIfNeeded()
    document.scroll(toFirstLine: 2400)
    let style = EditorStyle.make()
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    let left = style.gutterWidth + style.marks.gutterWidth
    let deadline = Date().addingTimeInterval(5)
    var shot = try layerShot(view)
    while shot.ink(
      in: NSRect(x: left, y: style.topInset, width: 3 * cell, height: style.lineHeight))
      == 0, Date() < deadline
    {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      shot = try layerShot(view)
    }
    // 先頭の行の `let`（keyword の青）の中で、いちばん青みの強い画素。
    let bluest = shot.bluest(
      in: NSRect(x: left, y: style.topInset, width: 3 * cell, height: style.lineHeight))
    XCTAssertGreaterThan(bluest, 0.3, "`let` が keyword の色で描かれている（素の文字色なら青みが出ない）")
  }

  /// 層に字が描かれるまで待って写す（描画の反映は runloop で来る）。
  private func drawnShot(_ view: NSView, inking rect: NSRect) throws -> LayerShot {
    let deadline = Date().addingTimeInterval(5)
    var shot = try layerShot(view)
    while shot.ink(in: rect) == 0, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      shot = try layerShot(view)
    }
    return shot
  }

  /// view の層を描き直さずに写す（2 倍）。
  private func layerShot(_ view: NSView) throws -> LayerShot {
    let size = view.bounds.size
    let rep = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * LayerShot.scale),
        pixelsHigh: Int(size.height * LayerShot.scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0))
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
    context.translateBy(x: 0, y: size.height * LayerShot.scale)
    context.scaleBy(x: LayerShot.scale, y: -LayerShot.scale)
    try XCTUnwrap(view.layer).render(in: context)
    return LayerShot(rep: rep)
  }
}

private struct LayerShot {
  static let scale: CGFloat = 2
  let rep: NSBitmapImageRep

  private func colors(in rect: NSRect) -> [NSColor] {
    stride(from: rect.minY, to: rect.maxY, by: 0.5).flatMap { y in
      stride(from: rect.minX, to: rect.maxX, by: 0.5).compactMap { x in
        rep.colorAt(x: Int(x * Self.scale), y: Int(y * Self.scale))
      }
    }
  }

  func ink(in rect: NSRect) -> CGFloat { colors(in: rect).map(\.alphaComponent).max() ?? 0 }

  func bluest(in rect: NSRect) -> CGFloat {
    colors(in: rect).map { $0.blueComponent - $0.redComponent }.max() ?? 0
  }

  func reddest(in rect: NSRect) -> CGFloat {
    colors(in: rect).map { $0.redComponent - $0.blueComponent }.max() ?? 0
  }
}

/// 役割の問い合わせを記録する delegate（文書へも流す）。
@MainActor
private final class RolesCounter: TextSurfaceDelegate {
  let inner: EditorDocument
  var queried: [NSRange] = []
  init(inner: EditorDocument) { self.inner = inner }
  func surface(_ surface: any TextSurface, rolesIn range: NSRange) -> [HighlightSpan] {
    queried.append(range)
    return inner.surface(surface, rolesIn: range)
  }
  func surface(_ surface: any TextSurface, didChange edit: TextEdit) {
    inner.surface(surface, didChange: edit)
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
  func surfaceLineCount(_ surface: any TextSurface) -> Int { inner.surfaceLineCount(surface) }
  func surface(_ surface: any TextSurface, lineContaining offset: Int) -> Int {
    inner.surface(surface, lineContaining: offset)
  }
  func surface(_ surface: any TextSurface, rangeOfLine line: Int) -> NSRange {
    inner.surface(surface, rangeOfLine: line)
  }
}
