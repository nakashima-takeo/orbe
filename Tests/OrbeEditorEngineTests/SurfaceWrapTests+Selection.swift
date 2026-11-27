import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 折り返した行の選択・キー・変換・区間を見せる操作。壊れると、続きの段で選んだ語や行が別の所になる、⌃A・⌃E・行番号の
/// 押下が段の単位に変わる、↓ で字下げの分だけ横にずれる、候補窓が別の段に出る、⌘F の一致が画面の外に残る。
extension SurfaceWrapTests {
  /// 語が 40 個並ぶ長い行と、短い行。
  private var words: String {
    (0..<40).map { "word\($0)" }.joined(separator: " ") + "\nshort\n"
  }

  /// トリプルクリック・行番号の押下・⌃A・⌃E は、続きの段からでも文書の行の単位で動く。
  func testDocumentLineOperationsWorkOnTheWholeLineFromAContinuationSegment() throws {
    let opened = try opened(words)
    let wrap = try wrap(opened)
    let text = opened.document.text
    let line = NSRange(location: 0, length: text.lineStart(1))
    try click(opened, row: 2, column: 3, clicks: 3)
    XCTAssertEqual(opened.surface.selectedRange, line, "トリプルクリックは文書の行を改行まで選ぶ")
    let gutter = CGPoint(x: 8, y: point(opened, row: 2, column: 0).y)
    try mouse(opened, .leftMouseDown, at: gutter)
    try mouse(opened, .leftMouseUp, at: gutter)
    XCTAssertEqual(opened.surface.selectedRange, line, "続きの段の横の行番号の列を押すと、文書の行を選ぶ")
    opened.surface.selectedRange = NSRange(location: wrap.start(of: 1) + 2, length: 0)
    try key(opened, "e", .control, keyCode: 14)
    XCTAssertEqual(
      opened.surface.caretLocation, NSMaxRange(text.contentRange(ofRow: 0)), "⌃E は文書の行末")
    try key(opened, "a", .control, keyCode: 0)
    XCTAssertEqual(opened.surface.caretLocation, 0, "⌃A は文書の行の 1 列目")
  }

  /// 続きの段でダブルクリックした語が選ばれ、段をまたいでドラッグすると、押した字から離した字までが選ばれる。ドラッグが
  /// 本文の右の外へ出れば、横にはスクロールせず、ポインタの段の終わりまで伸びる。
  func testSelectingWithTheMouseFollowsTheCharactersOfEachSegment() throws {
    let opened = try opened(words)
    let wrap = try wrap(opened)
    let text = opened.document.text
    let second = wrap.start(of: 1)
    try click(opened, row: 1, column: 1, clicks: 2)
    let word =
      (text.substring(NSRange(location: second, length: wrap.start(of: 2) - second))
      as NSString).range(of: " ").location
    XCTAssertEqual(
      opened.surface.selectedRange, NSRange(location: second, length: word), "2 段目の頭の語")
    try mouse(opened, .leftMouseDown, at: point(opened, row: 0, column: 2))
    try mouse(opened, .leftMouseDragged, at: point(opened, row: 1, column: 3))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 2, length: second + 3 - 2))
    let right = CGPoint(
      x: opened.surface.surfaceLayout.text.maxX + 40, y: point(opened, row: 1, column: 0).y)
    try mouse(opened, .leftMouseDragged, at: right)
    try mouse(opened, .leftMouseUp, at: right)
    XCTAssertEqual(
      NSMaxRange(opened.surface.selectedRange), wrap.start(of: 2), "右の外は、その段の終わりまで")
    XCTAssertEqual(opened.surface.scrollPosition.x, 0, "横にはスクロールしない")
  }

  /// ↓ は、描いた位置（続きの段の字下げを含む）を保って次の段へ動く——字下げした続きの段では、上の段と同じ x の字に入る。
  func testDownKeepsTheDrawnPositionAcrossTheContinuationIndent() throws {
    let indent = "        "
    let opened = try opened(indent + (0..<40).map { "w\($0)" }.joined(separator: " ") + "\n")
    let wrap = try wrap(opened)
    XCTAssertEqual(
      CGFloat(wrap.indent), 8 * opened.surface.config.cell, accuracy: 0.01, "前提: 8 桁の字下げ")
    opened.surface.selectedRange = NSRange(location: indent.utf16.count + 3, length: 0)
    try key(opened, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125)
    XCTAssertEqual(
      opened.surface.caretLocation, wrap.start(of: 1) + 3, "字下げの分を引いた桁ではなく、同じ x の字")
  }

  /// 変換中の未確定の字が段をまたいでも、未確定の矩形は、未確定の先頭がある段の 1 段の高さに付き、その段の終わりで切れる
  /// （IME へ返す範囲もそこまで）。未確定の中の、次の段の頭から始まる文節の矩形は、次の段に付き、幅を持つ。
  func testTheMarkedRectSitsOnTheSegmentWhereTheMarkedTextStarts() throws {
    let opened = try opened(words)
    let window = host(opened, size: CGSize(width: 420, height: 300))
    fakeInputMethod(opened)
    let wrap = try wrap(opened)
    opened.surface.selectedRange = NSRange(location: wrap.start(of: 2) - 2, length: 0)
    replay([.mark("かなかなかなかな")], on: opened)
    let client = opened.surface.textView
    let marked = client.markedRange()
    let rows = opened.surface.rows
    let segment = rows.segment(containing: marked.location, line: 0)
    XCTAssertEqual(segment, 1, "前提: 未確定の先頭は 2 段目")
    XCTAssertGreaterThan(
      rows.segment(containing: NSMaxRange(marked) - 1, line: 0), segment, "前提: 未確定は段をまたぐ")
    let next = try XCTUnwrap(rows.wrap(ofLine: 0)).start(of: segment + 1)
    func rect(_ range: NSRange) -> (rect: NSRect, actual: NSRange) {
      var actual = NSRange(location: NSNotFound, length: 0)
      let screen = client.firstRect(forCharacterRange: range, actualRange: &actual)
      return (client.convert(window.convertFromScreen(screen), from: nil), actual)
    }
    let whole = rect(marked)
    XCTAssertEqual(
      whole.rect.midY, point(opened, row: 1, column: 0).y, accuracy: 0.5, "2 段目の縦の中央")
    XCTAssertEqual(whole.rect.height, opened.surface.config.lineHeight, accuracy: 0.5, "1 段の高さ")
    XCTAssertEqual(
      whole.actual, NSRange(location: marked.location, length: next - marked.location),
      "2 段目の終わりで切る")
    XCTAssertGreaterThan(whole.rect.width, 0)
    let head = rect(NSRange(location: next, length: 2))
    XCTAssertEqual(
      head.rect.midY, point(opened, row: 2, column: 0).y, accuracy: 0.5, "次の段の頭からの文節は 3 段目")
    XCTAssertGreaterThan(head.rect.width, 0, "次の段の頭からの文節の幅")
    XCTAssertLessThan(head.rect.minX, point(opened, row: 2, column: 1).x, "次の段の頭から")
  }

  /// 段の終わり（付き）にキャレットがあるとき、IME が問う文字の矩形も選択の矩形も、キャレットを描いた上の段の終わりに出る。
  func testTheRectsOfACaretAtASegmentEndSitWhereTheCaretIsDrawn() throws {
    let opened = try opened(words)
    let window = host(opened, size: CGSize(width: 420, height: 300))
    let wrap = try wrap(opened)
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    opened.surface.editor.perform(.move(.end, extending: false))
    XCTAssertEqual(opened.surface.caretLocation, wrap.start(of: 1), "前提: 段の終わり（付き）")
    let client = opened.surface.textView
    let caret = client.convert(
      window.convertFromScreen(
        client.firstRect(
          forCharacterRange: NSRange(location: wrap.start(of: 1), length: 0), actualRange: nil)),
      from: nil)
    let first = point(opened, row: 0, column: 0)
    XCTAssertEqual(caret.midY, first.y, accuracy: 0.5, "1 段目")
    XCTAssertGreaterThan(caret.minX, first.x, "段の頭ではなく終わり")
    let union = client.convert(
      window.convertFromScreen(client.unionRectInVisibleSelectedRange), from: nil)
    XCTAssertEqual(union.midY, first.y, accuracy: 0.5, "選択の矩形も 1 段目")
  }

  /// 区間を見せると（⌘F の一致へ送る）、長い行の後ろの段にある区間でも、その段が見える。
  func testRevealingARangeInALaterSegmentShowsThatSegment() throws {
    let opened = try opened((0..<600).map { "w\($0)" }.joined(separator: " ") + "\n")
    let rows = opened.surface.rows
    let target =
      (opened.document.text.substring(
        NSRange(location: 0, length: opened.document.text.lineEnd(0))) as NSString).range(
        of: "w555")
    let segment = rows.segment(containing: target.location, line: 0)
    let viewport = opened.surface.viewport
    XCTAssertGreaterThan(
      CGFloat(segment), CGFloat(viewport.top.offset) + viewport.visibleLines, "前提: 画面の下の外")
    opened.surface.reveal(target, policy: .centerIfOutside)
    let shown = opened.surface.viewport
    XCTAssertEqual(shown.top.line, 0)
    XCTAssertLessThanOrEqual(shown.top.offset, segment)
    XCTAssertLessThan(
      CGFloat(segment), CGFloat(shown.top.offset) + shown.visibleLines, "一致の段が見える")
  }

  /// マウスで段の終わりより右に着いた端は、付きを持つ——選択の中を押して離したときも、語の単位のドラッグでも。
  func testTheMouseLandsOnTheSegmentEndFromItsRight() throws {
    let opened = try opened(words)
    let wrap = try wrap(opened)
    let editor = opened.surface.editor
    let end = wrap.start(of: 1)
    let last = point(opened, row: 0, column: CGFloat(end - 1) + 0.5)
    opened.surface.selectedRange = NSRange(location: 0, length: end)
    try mouse(opened, .leftMouseDown, at: last)
    try mouse(opened, .leftMouseUp, at: last)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: end, length: 0), "選択の中を押して離す")
    XCTAssertTrue(editor.state.cursors.primary.upstream, "段の終わり")
    let right = CGPoint(
      x: opened.surface.surfaceLayout.text.maxX - 2, y: point(opened, row: 0, column: 0).y)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 0, column: 1), clicks: 2)
    try mouse(opened, .leftMouseDragged, at: right, clicks: 2)
    try mouse(opened, .leftMouseUp, at: right, clicks: 2)
    XCTAssertEqual(NSMaxRange(opened.surface.selectedRange), end, "語の単位のドラッグ")
    XCTAssertTrue(editor.state.cursors.primary.upstream, "段の終わり")
  }

  /// 見えているいちばん下の段の右を押しても、キャレットはその段の終わり（付き）に入り、本文はスクロールしない。
  func testPressingRightOfTheBottomSegmentDoesNotScroll() throws {
    let opened = try opened((0..<600).map { "w\($0)" }.joined(separator: " ") + "\n")
    let surface = opened.surface
    let bottom = Int(surface.viewport.visibleLines) - 1
    XCTAssertLessThan(bottom + 1, try wrap(opened).segments, "前提: 下に続きの段がある")
    let before = surface.scrollPosition
    let at = CGPoint(
      x: surface.surfaceLayout.text.maxX - 2, y: point(opened, row: bottom, column: 0).y)
    try mouse(opened, .leftMouseDown, at: at)
    try mouse(opened, .leftMouseUp, at: at)
    XCTAssertEqual(surface.caretLocation, try wrap(opened).start(of: bottom + 1))
    XCTAssertTrue(surface.editor.state.cursors.primary.upstream)
    XCTAssertEqual(surface.scrollPosition, before, "スクロールしない")
  }

  /// 選択のドラッグが本文の上の外へ出ると、自動スクロールのコマごとに、見えているいちばん上の段の頭まで伸びる（画面の外の
  /// 段落の頭へ飛ばない）。
  func testDraggingAboveTheTextExtendsToTheTopVisibleSegment() throws {
    let opened = try opened((0..<600).map { "w\($0)" }.joined(separator: " ") + "\n")
    let surface = opened.surface
    let wrap = try wrap(opened)
    let pointer = try XCTUnwrap((surface.responder as? MetalTextView)?.pointer)
    surface.scroll(toFirstLine: 20)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 3, column: 2))
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: 100, y: 1))
    // 窓は画面に出ないので display link は回らない。自動スクロールのコマを、時刻を渡して 2 回進める。
    pointer.frame(now: 10)
    pointer.frame(now: 10.1)
    let top = surface.viewport.top
    XCTAssertEqual(top.line, 0)
    XCTAssertGreaterThan(top.offset, 0, "前提: 続きの段が上端")
    XCTAssertEqual(surface.selectedRange.location, wrap.start(of: top.offset), "上端の段の頭")
    try mouse(opened, .leftMouseUp, at: CGPoint(x: 100, y: 1))
  }

  /// 字下げした続きの段の URL は、押した点の字から引く（⌘クリックで開く URL）——URL の最後の字の上でも。
  func testALinkOnAnIndentedContinuationSegmentIsFoundUnderThePointer() throws {
    let indent = "        "
    let url = "https://example.com/wrapped"
    let opened = try opened(
      indent + (0..<30).map { "w\($0)" }.joined(separator: " ") + " " + url + " tail\n")
    let wrap = try wrap(opened)
    let location = (text(opened.document) as NSString).range(of: url).location
    let segment = opened.surface.rows.segment(containing: location, line: 0)
    XCTAssertGreaterThan(segment, 0, "前提: URL は続きの段")
    XCTAssertEqual(
      opened.surface.rows.segment(containing: location + url.utf16.count - 1, line: 0), segment,
      "前提: URL は 1 つの段に収まる")
    let column = CGFloat(indent.count + location + url.utf16.count - 1 - wrap.start(of: segment))
    XCTAssertEqual(
      opened.surface.link(at: point(opened, row: segment, column: column)), URL(string: url))
  }
}
