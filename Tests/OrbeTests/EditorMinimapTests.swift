import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 本体の右列——ミニマップ（字の形を 1 行 2pt・1 字 1pt で描く）とスクロールバー 14。ミニマップの帯はホバーで現れ、
/// 掴んでドラッグでき、帯の外の押下はその行を中央へ。検索の一致・語の出現・git の印・選択がミニマップに重なる。
///
/// 壊れると何が起きるか。ミニマップが VS Code の密度にならない（字が見えない・行が詰まらない）。帯が掴めない、掴んでも
/// 本文が付いてこない。帯の外を押すと別の行へ飛ぶ。検索の一致がミニマップに出ない。打鍵のたびに窓ぶんの字を描き直して
/// 大きな文書で打鍵が重くなる。
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
      until: { !hosted.document.roleSpans(in: NSRange(location: 0, length: 6)).isEmpty }, "色付け")
    view.needsDisplay = true
    let pixels = try ViewPixels(view)
    let rect = cell(view, row: 0, column: 1)
    var keyword = NSColor.clear
    for py in Int(rect.minY * pixels.scale)..<Int(rect.maxY * pixels.scale) {
      for px in Int(rect.minX * pixels.scale)..<Int(rect.maxX * pixels.scale) {
        let c = pixels.rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) ?? .clear
        if c.alphaComponent > keyword.alphaComponent { keyword = c }
      }
    }
    XCTAssertTrue(Hue.blue(keyword), "struct は keyword の青: \(keyword)")
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

  /// 帯の外を押すと、その行が本文の中央に来る（ドラッグは続かない）。
  func testPressingOutsideTheSliderCentersThatLine() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let view = hosted.pane.minimap
    let layout = try XCTUnwrap(view.placement)
    let point = NSPoint(x: 20, y: layout.sliderTop + layout.sliderHeight + 100)
    let line = layout.line(atY: point.y)
    view.mouseDown(with: view.mouseEvent(.leftMouseDown, at: point))
    let visible = hosted.document.viewportLines.visible
    XCTAssertEqual(hosted.firstLine, CGFloat(line) + 0.5 - visible / 2, accuracy: 0.6, "その行が中央")
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
    XCTAssertGreaterThan(pane.search.matches.count, 1000)
    XCTAssertTrue(pane.minimap.decorations.approximatesFindMatches)
    hosted.document.surface.selectedRange = NSRange(
      location: hosted.document.lineIndex.start(ofRow: 50) + 1, length: 0)
    let current = try XCTUnwrap(pane.search.current)
    let row = hosted.document.lineIndex.point(at: pane.search.matches[current].location).row
    let view = pane.minimap
    let pixels = try ViewPixels(view)
    XCTAssertTrue(
      Hue.orange(pixels.color(view.bounds.width - 4, CGFloat(row + 5) * 2 + 1)) == false,
      "他の一致の行は出ない")
    let column = pane.search.matches[current].location - hosted.document.lineIndex.start(ofRow: row)
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

  /// 字のチャンク: 打鍵は編集の行のチャンクだけ捨て、行が増えれば編集より後ろのチャンクも捨てる。
  func testTypingDropsOnlyTheEditedChunkAndNewlinesDropTheChunksAfterIt() throws {
    let hosted = try hostOverview(numberedLines(300), height: 800)
    let view = hosted.pane.minimap
    view.display()
    let warm = view.cachedChunks
    XCTAssertTrue(warm.isSuperset(of: [0, 1, 2]), "窓のチャンクを覚えている: \(warm)")

    hosted.document.surface.selectedRange = NSRange(
      location: hosted.document.lineIndex.start(ofRow: 100), length: 0)
    hosted.window.makeFirstResponder(hosted.document.surface.responder)
    hosted.document.surface.responder.keyDown(with: .key("x", []))
    XCTAssertEqual(warm.subtracting(view.cachedChunks), [1], "行 100 のチャンクだけ捨てる")

    view.display()
    hosted.document.surface.responder.keyDown(with: .key("\n", []))
    XCTAssertEqual(view.cachedChunks.filter { $0 >= 1 }, [], "行が増えれば以降を捨てる")
    XCTAssertTrue(view.cachedChunks.contains(0), "手前は残る")
  }

  /// 行を丸ごと選ぶと（改行まで）、その行に選択の行の地が付く（VS Code は範囲の終わりの行まで数える）。
  func testSelectingWholeLinesHighlightsTheirRows() throws {
    let hosted = try hostOverview(numberedLines(20))
    let index = hosted.document.lineIndex
    hosted.document.surface.selectedRange = NSRange(
      location: index.start(ofRow: 4), length: index.end(ofRow: 4) - index.start(ofRow: 4))
    let view = hosted.pane.minimap
    let pixels = try ViewPixels(view)
    XCTAssertGreaterThan(pixels.color(view.bounds.width - 4, 4 * 2 + 1).alphaComponent, 0, "行 5 の地")
    XCTAssertEqual(pixels.color(view.bounds.width - 4, 5 * 2 + 1).alphaComponent, 0, "次の行には付かない")
    XCTAssertEqual(pixels.color(view.bounds.width - 4, 3 * 2 + 1).alphaComponent, 0)
  }

  /// ミニマップとスクロールバーの上のホイールは本文をスクロールする（右端の列がスクロールの死角にならない）。
  func testScrollingOverTheRightColumnScrollsTheText() throws {
    let hosted = try hostOverview(numberedLines(1000))
    for view in [hosted.pane.minimap, hosted.pane.scrollbar] as [NSView] {
      let before = hosted.scroll.contentView.bounds.minY
      let wheel = try XCTUnwrap(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0,
          wheel3: 0))
      view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
      pumpMain(until: { hosted.scroll.contentView.bounds.minY > before }, "本文がスクロールする")
    }
  }
}

extension NSPoint {
  func offset(dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint { NSPoint(x: x + dx, y: y + dy) }
}
