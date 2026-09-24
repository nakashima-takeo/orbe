import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorCore
@testable import OrbeEditorText

/// エンジンのスクロールと強調の地——最終行を最上段まで送れる範囲・その下の空き地の押下・「この行を先頭に」の着地
/// （遠くへ飛んでも狙った行に落ち着き、後から動かない）・本文が右に続くか・横スクローラーの様式・強調の地の層の位置。
///
/// 壊れると何が起きるか。最終行を上まで送れない（VS Code と違う）。スクロールバーやミニマップのドラッグで本文が
/// 指と違う行へ飛び、少し後にさらに動く。遠くへ飛んだ直後にインデント線や一致の地が本文から半行ずれ、クリックが
/// 別の行に当たる。OS が「スクロールバーを常に表示」だと本文の下が横スクローラーに削られ可視行数がずれる（CI で
/// 落ちる）。現在の一致が選択の地に埋もれる。
@MainActor
final class EditorTextSurfaceScrollTests: OrbeTestCase {
  struct Opened {
    let document: EditorDocument
    let window: NSWindow
    let scroll: NSScrollView
  }

  /// `text` を開いた 400×200 の面（上端の余白 4 の下に 196pt）。
  func open(_ text: String) throws -> Opened {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let url = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(
      "s-\(UUID().uuidString).txt")
    try Data(text.utf8).write(to: url)
    let document = try session.open(url)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = document.surface.view
    document.surface.view.frame = try XCTUnwrap(window.contentView).bounds
    document.surface.view.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let scroll = try XCTUnwrap(document.surface.view.subviews.first as? NSScrollView)
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "viewport が出る")
    withExtendedLifetime(session) {}
    return Opened(document: document, window: window, scroll: scroll)
  }

  func lines(_ n: Int) -> String { (1...n).map { "line \($0)\n" }.joined() }

  /// 先頭に見えている行（小数）。
  func first(_ document: EditorDocument) -> CGFloat { document.viewportLines.first }

  func testTheLastLineCanBeScrolledToTheTopAndNoFurther() throws {
    let opened = try open(lines(100))
    let document = opened.document
    let last = document.lineIndex.lineCount - 1
    XCTAssertEqual(last, 100, "前提: 末尾の改行の後の空行も行")
    document.scroll(toFirstLine: CGFloat(last))
    XCTAssertEqual(document.surface.viewport.firstVisible, document.lineIndex.length, "末尾の空行が最上段")
    XCTAssertEqual(document.surface.viewport.hiddenFraction, 0)

    let clip = opened.scroll.contentView
    XCTAssertEqual(
      clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: 500)).minY, clip.bounds.minY,
      "それより先へは送れない")
  }

  /// 最終行の下の空き地を押すとキャレットは文書の末尾へ行く（VS Code と同じ）。
  func testPressingBelowTheLastLinePutsTheCaretAtTheEnd() throws {
    let opened = try open(lines(100))
    let document = opened.document
    opened.window.makeFirstResponder(document.surface.responder)
    document.scroll(toFirstLine: 99)
    pumpMain(until: { self.first(document) == 99 }, "最終行の手前まで送る")
    let clip = opened.scroll.contentView
    let below = clip.convert(NSPoint(x: 120, y: clip.bounds.maxY - 20), to: nil)
    let hit = try XCTUnwrap(opened.window.contentView?.hitTest(below))
    XCTAssertTrue(hit === document.surface.responder, "空き地の押下はテキスト面へ渡る")
    hit.mouseDown(with: .mouse(.leftMouseDown, at: below, in: opened.window))
    hit.mouseUp(with: .mouse(.leftMouseUp, at: below, in: opened.window))
    XCTAssertEqual(
      document.surface.selectedRange, NSRange(location: document.lineIndex.length, length: 0))
  }

  /// 「この行をこの割合だけ隠して先頭に」は viewport の逆——遠くへ飛んでも狙った行に落ち着き、後の layout で動かない。
  func testScrollToTopLandsOnTheLineEvenFarAwayAndStaysThere() throws {
    let opened = try open(lines(3000))
    let document = opened.document
    for target: CGFloat in [2500.5, 12.25, 1800, 2999.75, 40] {
      document.scroll(toFirstLine: target)
      XCTAssertEqual(first(document), target, accuracy: 0.01, "\(target) に着地")
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      XCTAssertEqual(first(document), target, accuracy: 0.01, "\(target) から後で動かない")
    }
  }

  /// 遠くへ飛んだ直後も、描いた字は地の中にあり、地は上から 3 行目の行の高さに一致する（layout の推定が動いて、字の
  /// 行片の view だけが古い位置に残ったり、地が半行ずれたりしない）。
  func testTextAndHighlightsStayTogetherAfterAFarJump() throws {
    let text = (1...3000).map { $0 == 2400 ? "MARK\n" : "line \($0)\n" }.joined()
    let opened = try open(text)
    let document = opened.document
    let mark = (text as NSString).range(of: "MARK")
    document.surface.setHighlights([mark], for: .currentFindMatch)
    document.scroll(toFirstLine: 2397)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let view = document.surface.view
    let style = EditorStyle.make()
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    let left = style.gutterWidth + style.marks.gutterWidth
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    // 「MARK」の 4 字の列を縦に走査し、画素の行ごとに「地（橙）がある」「字（明るい文字色）がある」を読む。
    var ground: [Int] = []
    var ink: [Int] = []
    for py in 0..<rep.pixelsHigh {
      var hasGround = false
      var hasInk = false
      for px in Int(left * scale)..<Int((left + 4 * cell) * scale) {
        guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5
        else { continue }
        if c.redComponent > 0.45, c.blueComponent < 0.2 { hasGround = true }
        if c.blueComponent > 0.4 { hasInk = true }
      }
      if hasGround { ground.append(py) }
      if hasInk { ink.append(py) }
    }
    let top = try XCTUnwrap(ground.first)
    let bottom = try XCTUnwrap(ground.last)
    XCTAssertEqual(
      CGFloat(top) / scale, style.topInset + 2 * style.lineHeight, accuracy: 1, "地は 3 行目")
    XCTAssertEqual(CGFloat(bottom - top + 1) / scale, style.lineHeight, accuracy: 1, "地は行の高さ")
    let margin = Int(2 * scale)
    let near = ink.filter { $0 >= top - margin && $0 <= bottom + margin }
    XCTAssertFalse(near.isEmpty, "MARK の字が描かれている")
    XCTAssertTrue(
      near.allSatisfy { $0 >= top && $0 <= bottom }, "字は地の中: 地 \(top)...\(bottom) 字 \(near)")
  }

  /// End は最後の 1 画面を見せる（最終行を最上段まで送れる範囲でも、最終行だけを残さない）。
  func testEndKeyShowsTheLastScreen() throws {
    let opened = try open(lines(100))
    let document = opened.document
    document.surface.responder.perform(#selector(NSResponder.scrollToEndOfDocument(_:)), with: nil)
    let expected = CGFloat(document.lineIndex.lineCount) - document.viewportLines.visible
    pumpMain(until: { abs(self.first(document) - expected) < 0.05 }, "最終行は下端")
  }

  /// 空の文書にも見えている範囲がある（1 行・先頭）。スクロールした後に全部消しても先頭に戻る。
  func testAnEmptyDocumentStillReportsAViewport() throws {
    let empty = try open("")
    XCTAssertEqual(empty.document.surface.viewport.firstVisible, 0)
    XCTAssertGreaterThan(empty.document.surface.viewport.visibleLines, 0)
    XCTAssertFalse(empty.document.surface.viewport.clipsRight)

    let opened = try open(lines(100))
    opened.document.scroll(toFirstLine: 50)
    opened.document.surface.replaceAll(with: "")
    pumpMain(until: { opened.document.surface.viewport.firstVisible == 0 }, "消せば先頭")
    XCTAssertEqual(opened.document.surface.viewport.hiddenFraction, 0)
  }

  /// 最終行より下の空き地のうち本文の列は、押せば効くので I ビームの範囲になる（ガターは除く）。
  func testTheBlankAreaBelowTheLastLineIsTextArea() throws {
    let opened = try open(lines(100))
    let clip = try XCTUnwrap(opened.scroll.contentView as? OverscrollClipView)
    XCTAssertTrue(clip.blankArea.isEmpty, "先頭では空き地が無い")
    opened.document.scroll(toFirstLine: 95)
    let style = EditorStyle.make()
    let documentBottom = try XCTUnwrap(opened.scroll.documentView).frame.maxY
    XCTAssertEqual(clip.blankArea.minY, documentBottom)
    XCTAssertEqual(clip.blankArea.maxY, clip.bounds.maxY)
    XCTAssertEqual(clip.blankArea.minX, style.gutterWidth + style.marks.gutterWidth, accuracy: 0.5)
  }

  func testViewportCountsTheTrailingEmptyLineAsALine() throws {
    let opened = try open("abc\ndef\n")
    let document = opened.document
    document.surface.scroll(toTop: 8, hiddenFraction: 0)
    XCTAssertEqual(document.surface.viewport.firstVisible, 8, "末尾の空行（行索引の最終行）が先頭")
    document.surface.scroll(toTop: 4, hiddenFraction: 0.5)
    XCTAssertEqual(document.surface.viewport.firstVisible, 4)
    XCTAssertEqual(document.surface.viewport.hiddenFraction, 0.5, accuracy: 0.01)
  }

  func testClipsRightTellsWhetherTheTextContinuesToTheRight() throws {
    let narrow = try open("short\n")
    XCTAssertFalse(narrow.document.surface.viewport.clipsRight)
    let wide = try open(String(repeating: "x", count: 300) + "\n")
    XCTAssertTrue(wide.document.surface.viewport.clipsRight)
    let clip = wide.scroll.contentView
    clip.scroll(to: NSPoint(x: 10_000, y: 0))
    wide.scroll.reflectScrolledClipView(clip)
    pumpMain(until: { !wide.document.surface.viewport.clipsRight }, "右端まで送れば続かない")
  }

  /// 横スクローラーはオーバーレイに固定——OS の設定が常時表示に変わっても本文の下を削らない（可視行数が変わらない）。
  func testTheScrollerStyleStaysOverlay() throws {
    let opened = try open(lines(100) + String(repeating: "x", count: 300))
    XCTAssertEqual(opened.scroll.scrollerStyle, .overlay)
    opened.scroll.scrollerStyle = .legacy
    NotificationCenter.default.post(
      name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    XCTAssertEqual(opened.scroll.scrollerStyle, .overlay, "設定が変われば固定し直す")
    XCTAssertEqual(opened.scroll.contentView.bounds.height, 196, "横スクローラーが本文の下を削らない")
  }

  /// 長い 1 行でも、強調の地は横に見えている字の分だけ描く——右へ送った先の一致は、見えている窓の中で字に重なる
  /// （窓の外の一致まで描くと、一致の数 × 行の長さで描画が固まる）。
  func testHighlightsOnALongLineFollowTheHorizontalScroll() throws {
    let text = String(repeating: "xxxxxxxxxx", count: 3000) + "\n"
    let opened = try open(text)
    let document = opened.document
    let far = 25_000
    document.surface.setHighlights(
      (0..<3000).map { NSRange(location: $0 * 10, length: 5) }, for: .currentFindMatch)
    let clip = opened.scroll.contentView
    let style = EditorStyle.make()
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    clip.scroll(to: NSPoint(x: CGFloat(far) * cell, y: 0))
    opened.scroll.reflectScrolledClipView(clip)
    document.surface.view.layoutSubtreeIfNeeded()
    let view = document.surface.view
    let origin = style.gutterWidth + style.marks.gutterWidth
    func lit(_ column: Int) throws -> Bool {
      let x =
        origin + (CGFloat(column - far) + 0.5) * cell - (clip.bounds.minX - CGFloat(far) * cell)
      let c = try pixel(view, x, style.topInset + 2)
      return c.redComponent > 0.5 && c.blueComponent < 0.3
    }
    XCTAssertTrue(try lit(far + 2), "窓の中の一致（25000 桁目から 5 字）に地")
    XCTAssertFalse(try lit(far + 7), "一致の間には地が無い")
  }

  func pixel(_ view: NSView, _ x: CGFloat, _ y: CGFloat) throws -> NSColor {
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    return try XCTUnwrap(
      rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
  }

  /// 強調の地はエンジンの部品の本文の層の中で、選択の層の直上・文字の層の直下に置かれる（部品の版を上げて構造が
  /// 変われば落ちる——並びは選択 < 強調 < 文字）。画素でも、現在の一致の不透明の地が選択の地の上に出る。
  func testHighlightsSitAboveTheSelectionAndBelowTheText() throws {
    let opened = try open("alpha beta\n")
    let document = opened.document
    func descendants(_ view: NSView) -> [NSView] {
      view.subviews.flatMap { [$0] + descendants($0) }
    }
    let highlight = try XCTUnwrap(
      descendants(document.surface.view).first { "\(type(of: $0))" == "TextHighlightView" })
    let layer = try XCTUnwrap(highlight.superview)
    XCTAssertEqual(layer.subviews.firstIndex { $0 === highlight }, 1)
    XCTAssertEqual("\(type(of: layer.subviews[0]))", "STSelectionView")
    XCTAssertEqual("\(type(of: layer.subviews[2]))", "STContentViewportView")

    let range = NSRange(location: 6, length: 4)
    document.surface.selectedRange = range
    document.surface.setHighlights([range], for: .currentFindMatch)
    let style = EditorStyle.make()
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    let point = NSPoint(
      x: style.gutterWidth + style.marks.gutterWidth + 7.5 * cell, y: style.topInset + 2)
    let view = document.surface.view
    func pixel() throws -> NSColor {
      let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)
      let scale = CGFloat(rep.pixelsWide) / view.bounds.width
      return try XCTUnwrap(
        rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    }
    let covered = try pixel()
    XCTAssertGreaterThan(covered.redComponent, 0.5, "現在の一致の不透明の地（暗い黄土）が選択の地の上に出る")
    XCTAssertLessThan(covered.blueComponent, 0.3)
    document.surface.setHighlights([], for: .currentFindMatch)
    let selected = try pixel()
    XCTAssertGreaterThan(abs(selected.redComponent - covered.redComponent), 0.1, "地を外すと選択の地が見える")

  }
}
