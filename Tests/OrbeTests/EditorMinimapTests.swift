import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorText

/// 本体の右列——ミニマップ（字の形を 1 行 2pt・1 字 1pt で描く）とスクロールバー 14。ミニマップの帯はホバーで現れ、
/// 掴んでドラッグでき、帯の外の押下はその行を中央へ。検索の一致・語の出現・git の印・選択がミニマップに重なる。
///
/// 壊れると何が起きるか。ミニマップが VS Code の密度にならない（字が見えない・行が詰まらない）。帯が掴めない、掴んでも
/// 本文が付いてこない。帯の外を押すと別の行へ飛ぶ。検索の一致がミニマップに出ない。長い文書でミニマップが滑ると、字や
/// 一致の地が別の行の段に出る。字のチャンクの画像は `EditorMinimapTests+Chunks`。
@MainActor
final class EditorMinimapTests: OrbeTestCase {
  /// デバイス倍率に依らない、ミニマップの字の左のガター（8 デバイス px）。
  func gutter(_ view: NSView) -> CGFloat {
    8 / ((view.window?.backingScaleFactor ?? 1) >= 2 ? 2 : 1)
  }

  /// 行 `row`・桁 `column` のセル（1pt × 2pt）。ミニマップが滑っていないとき。
  func cell(_ view: NSView, row: Int, column: Int) -> NSRect {
    NSRect(x: gutter(view) + CGFloat(column), y: CGFloat(row) * 2, width: 1, height: 2)
  }

  func testTheRightColumnIsTheMinimapThenTheScrollbar() throws {
    let hosted = try hostOverview(numberedLines(10))
    let pane = hosted.pane
    let body = pane.bodyRect
    XCTAssertEqual(pane.scrollbar.frame.width, 14)
    XCTAssertEqual(pane.scrollbar.frame.maxX, body.maxX)
    XCTAssertEqual(pane.minimap.frame.maxX, pane.scrollbar.frame.minX)
    let cell = (" " as NSString).size(withAttributes: [.font: Theme.Typography.editorCode]).width
    XCTAssertEqual(
      pane.minimap.frame.width,
      MinimapLayout.width(
        remaining: body.width - 69, charWidth: cell, scrollbar: 14, maxWidth: 120))
    XCTAssertLessThan(pane.minimap.frame.width, 120, "狭い列ではミニマップも細くなる")
    XCTAssertEqual(pane.surfaceRect.maxX, pane.minimap.frame.minX)
    XCTAssertFalse(pane.minimap.isHidden)
    XCTAssertFalse(pane.scrollbar.isHidden)

    hosted.tab.editor.close(hosted.document)
    pane.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.minimap.isHidden, "文書が無ければ隠れる")
    XCTAssertTrue(pane.scrollbar.isHidden)
    XCTAssertEqual(pane.surfaceRect, pane.bodyRect)
  }

  func testTheMinimapWidthStopsAtTheMaximum() throws {
    let hosted = try hostOverview(numberedLines(10), width: 2400)
    XCTAssertEqual(hosted.pane.minimap.frame.width, 120)
  }

  /// 字は 1 字 1 桁・1 行 2pt で、空白は描かずに桁だけ進み、タブは次のタブ位置まで空ける。字の形は字ごとに違う
  /// （矩形の縮図ではない）。
  func testGlyphsTakeOneColumnPerCharacterAndKeepTheirShape() throws {
    let hosted = try hostOverview("x\n    y\nab\tz\nM.\n")
    let view = hosted.pane.minimap
    let pixels = try ViewPixels(view)
    func ink(_ row: Int, _ column: Int) -> CGFloat {
      pixels.alpha(in: cell(view, row: row, column: column)).max
    }
    XCTAssertGreaterThan(ink(0, 0), 0.2, "x")
    XCTAssertEqual(ink(1, 0), 0, "行頭の空白は描かない")
    XCTAssertEqual(ink(1, 3), 0)
    XCTAssertGreaterThan(ink(1, 4), 0.2, "y は 5 桁目")
    XCTAssertEqual(hosted.document.indentUnit, 4, "前提: タブ幅は検出したインデント単位")
    XCTAssertEqual(ink(2, 2), 0)
    XCTAssertGreaterThan(ink(2, 4), 0.2, "タブは次のタブ位置（4）まで空ける")
    let heavy = pixels.alpha(in: cell(view, row: 3, column: 0)).sum
    let light = pixels.alpha(in: cell(view, row: 3, column: 1)).sum
    XCTAssertGreaterThan(heavy, light * 2, "M は . より濃い（字の形を縮めている）")
  }

  /// 字は構文の役割の色で描く（役割の無い字は素の文字色）。
  func testGlyphsTakeTheColorOfTheirRole() throws {
    let hosted = try hostOverview(
      "struct S {}\n", name: "c-\(UUID().uuidString).swift", colored: true)
    let view = hosted.pane.minimap
    pumpMain(
      until: { !hosted.document.roles.roles(in: NSRange(location: 0, length: 6)).isEmpty }, "色付け")
    view.needsDisplay = true
    let keyword = try ViewPixels(view).strongest(in: cell(view, row: 0, column: 1))
    XCTAssertTrue(Hue.blue(keyword), "struct は keyword の青: \(keyword)")
  }

  /// 文書がミニマップに収まらず滑っている間も、字と一致の地はその行の段に出る（帯と同じ座標）。行 i は `x` を
  /// i % 8 + 1 個持つので、字の最後の桁で行を見分ける。
  func testGlyphsAndMatchesStayOnTheirRowsWhileTheMinimapSlides() throws {
    let text = (0..<1000).map {
      [700, 704].contains($0) ? "needle\n" : String(repeating: "x", count: $0 % 8 + 1) + "\n"
    }.joined()
    let hosted = try hostOverview(text)
    let pane = hosted.pane
    pane.showSearch()
    pane.search.setNeedle("needle")
    catchUp(hosted.document)
    XCTAssertEqual(pane.search.current, 0, "前提: 行 700 の一致が現在（選択の行には行の地を付けない）")
    let view = pane.minimap
    let layout = try XCTUnwrap(view.placement)
    XCTAssertGreaterThan(layout.startLine, 0, "前提: ミニマップが滑っている")
    let pixels = try ViewPixels(view)
    func ink(_ row: Int, _ column: Int) -> CGFloat {
      pixels.alpha(
        in: NSRect(x: gutter(view) + CGFloat(column), y: layout.y(ofLine: row), width: 1, height: 2)
      ).max
    }
    for row in [layout.startLine + 1, 690, 697, 710] {
      XCTAssertGreaterThan(ink(row, row % 8), 0.2, "行 \(row) の最後の字")
      XCTAssertEqual(ink(row, row % 8 + 1), 0, "行 \(row) の字の後ろは空")
    }
    let matchLine = pixels.color(view.bounds.width - 4, layout.y(ofLine: 704) + 1)
    XCTAssertTrue(Hue.orange(matchLine), "行 704 の一致の行の地: \(matchLine)")
    XCTAssertFalse(Hue.orange(pixels.color(view.bounds.width - 4, layout.y(ofLine: 703) + 1)))
  }

  /// 帯は普段は隠れ、ミニマップの上にポインタがあると現れる。掴んでドラッグすると本文が付いてくる。
  func testTheSliderShowsOnHoverAndDraggingItScrollsTheText() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let view = hosted.pane.minimap
    XCTAssertFalse(view.isSliderShown, "普段は隠れる")
    let layout = try XCTUnwrap(view.placement)
    let grab = NSPoint(x: 20, y: layout.sliderTop + layout.sliderHeight / 2)
    view.mouseEntered(with: view.mouseEvent(.mouseMoved, at: grab))
    XCTAssertTrue(view.isSliderShown, "ホバーで現れる")

    view.mouseDown(with: view.mouseEvent(.leftMouseDown, at: grab))
    view.mouseDragged(with: view.mouseEvent(.leftMouseDragged, at: grab.offset(dy: 50)))
    let expected = layout.firstLine(afterDragging: 50)
    pumpMain(until: { abs(hosted.firstLine - expected) < 0.05 }, "帯の動きの分だけ本文が進む")
    view.mouseDragged(with: view.mouseEvent(.leftMouseDragged, at: grab.offset(dy: 20)))
    view.mouseUp(with: view.mouseEvent(.leftMouseUp, at: grab.offset(dy: 20)))
    XCTAssertEqual(
      hosted.firstLine, layout.firstLine(afterDragging: 20), accuracy: 0.05, "離せば最後の位置")
    XCTAssertTrue(view.isSliderShown, "ポインタが上にある間は見える")
    view.mouseExited(with: view.mouseEvent(.mouseMoved, at: .zero))
    XCTAssertFalse(view.isSliderShown, "外へ出れば隠れる")
  }

  /// 帯を掴んだままミニマップの外へ出て離せば、帯は消える（ドラッグ中も出入りを受ける）。
  func testReleasingADragOutsideTheMinimapHidesTheSlider() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let view = hosted.pane.minimap
    view.updateTrackingAreas()
    XCTAssertTrue(
      view.trackingAreas.contains {
        $0.owner === view && $0.options.contains(.enabledDuringMouseDrag)
      },
      "ドラッグ中も出入りを受ける")
    let layout = try XCTUnwrap(view.placement)
    let grab = NSPoint(x: 20, y: layout.sliderTop + layout.sliderHeight / 2)
    view.mouseEntered(with: view.mouseEvent(.mouseMoved, at: grab))
    view.mouseDown(with: view.mouseEvent(.leftMouseDown, at: grab))
    view.mouseExited(with: view.mouseEvent(.mouseMoved, at: grab.offset(dx: -300)))
    XCTAssertTrue(view.isSliderShown, "ドラッグ中は残る")
    view.mouseUp(with: view.mouseEvent(.leftMouseUp, at: grab.offset(dx: -300)))
    XCTAssertFalse(view.isSliderShown, "外で離せば消える")
  }

  /// 帯の外を押すと、その行の上端が本文の中央に来る（ドラッグは続かない。横位置は動かさない——VS Code と同じ）。
  func testPressingOutsideTheSliderCentersThatLine() throws {
    let hosted = try hostOverview(String(repeating: "x", count: 400) + "\n" + numberedLines(1000))
    let clip = hosted.scroll.contentView
    clip.scroll(to: NSPoint(x: 300, y: 0))
    hosted.scroll.reflectScrolledClipView(clip)
    let view = hosted.pane.minimap
    let layout = try XCTUnwrap(view.placement)
    let point = NSPoint(x: 20, y: layout.sliderTop + layout.sliderHeight + 100)
    let line = layout.line(atY: point.y)
    view.mouseDown(with: view.mouseEvent(.leftMouseDown, at: point))
    let visible = hosted.document.viewportLines.visible
    XCTAssertEqual(
      hosted.firstLine, CGFloat(line) - visible / 2, accuracy: 0.05, "その行の上端が中央（VS Code と同じ）")
    XCTAssertEqual(clip.bounds.minX, 300, "横位置は保つ")
    let after = hosted.firstLine
    view.mouseDragged(with: view.mouseEvent(.leftMouseDragged, at: point.offset(dy: 60)))
    view.mouseUp(with: view.mouseEvent(.leftMouseUp, at: point.offset(dy: 60)))
    XCTAssertEqual(hosted.firstLine, after, "帯の外の押下ではドラッグしない")
  }

  /// 検索の一致はミニマップに範囲とその行の薄い地で出る。一致が多いと現在の一致だけが出る。
  func testFindMatchesShowInTheMinimap() throws {
    let text = (0..<40).map { [12, 20].contains($0) ? "has needle here\n" : "plain line\n" }
      .joined()
    let hosted = try hostOverview(text)
    let pane = hosted.pane
    pane.showSearch()
    pane.search.setNeedle("needle")
    catchUp(hosted.document)
    XCTAssertEqual(pane.search.current, 0, "前提: 現在の一致（行 12）が選択され、行 20 は選択されていない")
    let view = pane.minimap
    let pixels = try ViewPixels(view)
    let lineGround = pixels.color(view.bounds.width - 4, 20 * 2 + 1)
    XCTAssertTrue(Hue.orange(lineGround), "一致の行の薄い地: \(lineGround)")
    XCTAssertFalse(Hue.orange(pixels.color(view.bounds.width - 4, 19 * 2 + 1)), "他の行には無い")
    XCTAssertEqual(
      pixels.color(view.bounds.width - 4, 12 * 2 + 1).alphaComponent, 0,
      "選択の行には行の地を付けない（VS Code と同じ）")
    let range = pixels.color(gutter(view) + 6, 20 * 2 + 1)
    XCTAssertGreaterThan(range.alphaComponent, lineGround.alphaComponent, "一致の範囲は行の地より濃い")
  }

  func testManyFindMatchesLeaveOnlyTheCurrentMatchInTheMinimap() throws {
    let text = String(repeating: "a a a a a a a a a a\n", count: 120)
    let hosted = try hostOverview(text)
    let pane = hosted.pane
    pane.showSearch()
    pane.search.setNeedle("a")
    catchUp(hosted.document)
    XCTAssertGreaterThan(pane.search.matches.count, 1000)
    XCTAssertTrue(pane.minimap.decorations.approximatesFindMatches)
    hosted.document.surface.selectedRange = NSRange(
      location: hosted.document.text.lineStart(50) + 2, length: 1)
    let current = try XCTUnwrap(pane.search.current)
    let row = hosted.document.text.row(containing: pane.search.matches[current].location)
    let view = pane.minimap
    let pixels = try ViewPixels(view)
    XCTAssertTrue(
      Hue.orange(pixels.color(view.bounds.width - 4, CGFloat(row + 5) * 2 + 1)) == false,
      "他の一致の行は出ない")
    let column = pane.search.matches[current].location - hosted.document.text.lineStart(row)
    let y = CGFloat(row) * 2 + 1
    let currentCell = pixels.color(gutter(view) + CGFloat(column) + 0.5, y)
    let otherCell = pixels.color(gutter(view) + CGFloat(column) + 4.5, y)
    XCTAssertGreaterThan(
      currentCell.redComponent * currentCell.alphaComponent,
      otherCell.redComponent * otherCell.alphaComponent + 0.1, "現在の一致だけ一致の色が重なる")
  }

  /// git の印は左端（x 2 デバイス px・幅 2 デバイス px）に、追加・変更・削除の色で 1 行ぶんの高さに出る。
  func testGitMarksShowAtTheLeftEdge() throws {
    let hosted = try hostOverview(numberedLines(20))
    hosted.document.baseline = numberedLines(20)
      .replacingOccurrences(of: "line 5\n", with: "line five\n")
      .replacingOccurrences(of: "line 10\n", with: "")
      .replacingOccurrences(of: "line 15\n", with: "line 15\nline gone\n")
    pumpMain(until: { hosted.document.hunks.count == 3 }, "ハンク")
    let view = hosted.pane.minimap
    let scale: CGFloat = (view.window?.backingScaleFactor ?? 1) >= 2 ? 2 : 1
    let x = 3 / scale
    let pixels = try ViewPixels(view)
    XCTAssertTrue(Hue.blue(pixels.color(x, 4 * 2 + 1)), "行 5 は変更")
    XCTAssertTrue(Hue.green(pixels.color(x, 9 * 2 + 1)), "行 10 は追加")
    XCTAssertTrue(Hue.red(pixels.color(x, 14 * 2 + 1)), "削除はその境の上の行（15 行目）")
    XCTAssertEqual(pixels.color(x, 2 * 2 + 1).alphaComponent, 0, "印の無い行")
  }

  /// 行を丸ごと選ぶと（改行まで）、その行に選択の行の地が付く（VS Code は範囲の終わりの行まで数える）。
  func testSelectingWholeLinesHighlightsTheirRows() throws {
    let hosted = try hostOverview(numberedLines(20))
    let rope = hosted.document.text
    hosted.document.surface.selectedRange = NSRange(
      location: rope.lineStart(4), length: rope.lineEnd(4) - rope.lineStart(4))
    let view = hosted.pane.minimap
    let pixels = try ViewPixels(view)
    XCTAssertGreaterThan(pixels.color(view.bounds.width - 4, 4 * 2 + 1).alphaComponent, 0, "行 5 の地")
    XCTAssertEqual(pixels.color(view.bounds.width - 4, 5 * 2 + 1).alphaComponent, 0, "次の行には付かない")
    XCTAssertEqual(pixels.color(view.bounds.width - 4, 3 * 2 + 1).alphaComponent, 0)
  }

  /// 複数行の選択は、途中の行を行末（本文の終わり）まで選択の色で塗り、その先は行の薄い地だけ（VS Code
  /// `renderDecorationOnLine`）。終わりの行は選択の終わりまで。
  func testMultiLineSelectionFillsTheMiddleRowsUpToTheirEnds() throws {
    let hosted = try hostOverview(numberedLines(40))
    let rope = hosted.document.text
    let view = hosted.pane.minimap
    let start = rope.lineStart(2) + 2
    let end = rope.lineStart(30) + 3
    XCTAssertGreaterThan(CGFloat(end - rope.lineStart(3)), view.bounds.width, "前提: 終わりは幅の外")
    hosted.document.surface.selectedRange = NSRange(location: start, length: end - start)
    let pixels = try ViewPixels(view)
    func alpha(_ row: Int, _ column: CGFloat) -> CGFloat {
      pixels.color(gutter(view) + column + 0.5, CGFloat(row) * 2 + 1).alphaComponent
    }
    let text = alpha(3, 3)
    let band = alpha(3, 20)
    XCTAssertGreaterThan(band, 0, "途中の行の本文の先は行の薄い地")
    XCTAssertLessThan(band, text - 0.2, "選択の色は行末まで: 本文 \(text) / その先 \(band)")
    XCTAssertGreaterThan(alpha(30, 1), alpha(30, 4) + 0.2, "終わりの行は選択の終わりまで")
  }

  /// ミニマップとスクロールバーの上のホイールは、面の器を通って本文のスクロールへ届く（右端の列がスクロールの死角に
  /// ならない）。届いた先のスクロールは AppKit が画面の display link で当てる（画面の無い環境では当たらない）ので、
  /// 本文のスクロールへ届くまでを見る。
  func testWheelOverTheRightColumnReachesTheTextScroll() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let container = try XCTUnwrap(hosted.document.surface.view as? SurfaceContainerView)
    XCTAssertIdentical(container.scrollTarget, hosted.scroll, "面の器の渡し先は本文のスクロール")
    let spy = WheelSpy()
    container.scrollTarget = spy
    for view in [hosted.pane.minimap, hosted.pane.scrollbar] as [NSView] {
      let wheel = try XCTUnwrap(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0,
          wheel3: 0))
      let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
      view.scrollWheel(with: event)
      XCTAssertIdentical(spy.received.last, event, "\(type(of: view)) のホイール")
    }
  }
}

/// 届いたホイールを覚えるだけのスクロール。
final class WheelSpy: NSScrollView {
  var received: [NSEvent] = []
  override func scrollWheel(with event: NSEvent) { received.append(event) }
}

extension NSPoint {
  func offset(dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint { NSPoint(x: x + dx, y: y + dy) }
}
