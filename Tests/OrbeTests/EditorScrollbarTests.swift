import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 本体の右端のスクロールバー——つまみのドラッグ、トラックの押下で飛んでそのままドラッグ、見え隠れ（本体の上のポインタ・
/// スクロールで現れ 500ms 後に消える）、印（git・検索の一致・キャレット・縁）。本体の上端の影とミニマップ左の影も。
///
/// 壊れると何が起きるか。つまみを掴んでも本文が付いてこない、トラックを押すと 1 ページ送り（OS の既定）になる、押した
/// ままドラッグできない。つまみが常に出て本文の右端を覆う、あるいはスクロールしても現れない。印が別の行を指す。
@MainActor
final class EditorScrollbarTests: OrbeTestCase {
  func testThumbFollowsTheScrollbarGeometry() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let bar = hosted.pane.scrollbar
    let (first, visible) = hosted.document.viewportLines
    let expected = ScrollbarGeometry(
      lineCount: hosted.document.lineIndex.lineCount, firstLine: first, visibleLines: visible,
      height: bar.bounds.height)
    XCTAssertEqual(bar.geometry, expected)
    XCTAssertEqual(expected.sliderLength, 20, "長い文書では最小の長さ")
  }

  func testDraggingTheThumbScrollsTheText() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let bar = hosted.pane.scrollbar
    let geometry = try XCTUnwrap(bar.geometry)
    let grab = NSPoint(x: 7, y: geometry.sliderPosition + 5)
    bar.mouseDown(with: bar.mouseEvent(.leftMouseDown, at: grab))
    bar.mouseDragged(with: bar.mouseEvent(.leftMouseDragged, at: grab.offset(dy: 120)))
    bar.mouseUp(with: bar.mouseEvent(.leftMouseUp, at: grab.offset(dy: 120)))
    XCTAssertEqual(hosted.firstLine, geometry.firstLine(afterDragging: 120), accuracy: 0.05)
  }

  /// トラックを押すとつまみの中央がそこへ来るよう飛び、同じ押下のままドラッグを続けられる（起点は飛んだ後の状態）。
  func testPressingTheTrackJumpsThereAndKeepsDragging() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let bar = hosted.pane.scrollbar
    let before = try XCTUnwrap(bar.geometry)
    let press = NSPoint(x: 7, y: 250)
    bar.mouseDown(with: bar.mouseEvent(.leftMouseDown, at: press))
    XCTAssertEqual(
      hosted.firstLine, before.firstLine(centeringSliderAt: 250), accuracy: 0.05, "押した位置へ")
    let jumped = try XCTUnwrap(bar.geometry)
    XCTAssertEqual(
      jumped.sliderPosition + jumped.sliderLength / 2, 250, accuracy: 1, "つまみの中央が押した位置")
    bar.mouseDragged(with: bar.mouseEvent(.leftMouseDragged, at: press.offset(dy: -40)))
    bar.mouseUp(with: bar.mouseEvent(.leftMouseUp, at: press.offset(dy: -40)))
    XCTAssertEqual(
      hosted.firstLine, jumped.firstLine(afterDragging: -40), accuracy: 0.05, "そのままドラッグ")
  }

  /// つまみは開いた直後は隠れ、本体の上にポインタがある間とドラッグ中は見え、スクロールで現れて 500ms 後に消える。
  func testTheThumbShowsWhileHoveringOrDraggingAndHidesAfterScrolling() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let pane = hosted.pane
    let bar = pane.scrollbar
    var hide: (() -> Void)?
    var delays: [TimeInterval] = []
    bar.hideDelay.schedule = { delay, fire in
      delays.append(delay)
      hide = fire
    }
    XCTAssertFalse(bar.isThumbShown, "開いた直後は隠れる")

    pane.mouseEntered(with: pane.enterExitEvent(.mouseEntered, area: pane.bodyTracking))
    XCTAssertTrue(bar.isThumbShown, "本体の上では見える")
    pane.mouseExited(with: pane.enterExitEvent(.mouseExited, area: pane.bodyTracking))
    XCTAssertFalse(bar.isThumbShown, "外へ出れば消える")

    hosted.document.scroll(toFirstLine: 30)
    pumpMain(until: { bar.isThumbShown }, "スクロールで現れる")
    XCTAssertEqual(delays.last, 0.5)
    try XCTUnwrap(hide)()
    XCTAssertFalse(bar.isThumbShown, "止まって 500ms 後に消える")

    let grab = NSPoint(x: 7, y: try XCTUnwrap(bar.geometry).sliderPosition + 5)
    bar.mouseDown(with: bar.mouseEvent(.leftMouseDown, at: grab))
    XCTAssertTrue(bar.isThumbShown, "ドラッグ中は見える")
    hide?()
    XCTAssertTrue(bar.isThumbShown, "ドラッグ中は消えない")
    bar.mouseUp(with: bar.mouseEvent(.leftMouseUp, at: grab))
    XCTAssertFalse(bar.isThumbShown, "離せば消える")
  }

  /// サイドバーや列の頭の上ではつまみは出ない（SwiftUI の骨は自分の出入りを pane へ流してくる）。
  func testTheThumbIgnoresEnteringTheSidebar() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let pane = hosted.pane
    let side = NSTrackingArea(
      rect: pane.sideHost.bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: pane.sideHost)
    pane.sideHost.mouseEntered(with: pane.sideHost.enterExitEvent(.mouseEntered, area: side))
    pane.mouseEntered(with: pane.enterExitEvent(.mouseEntered, area: side))
    XCTAssertFalse(pane.scrollbar.isThumbShown, "本体の外の出入りでは出ない")
  }

  /// ドラッグ中の「この行を先頭に」は runloop 1 回に最新の 1 つだけ当たる（遠くへ飛ぶ layout を溜めない）。
  func testDragScrollsAreCoalescedToTheLatestPerRunLoop() throws {
    let hosted = try hostOverview(numberedLines(1000))
    let bar = hosted.pane.scrollbar
    let geometry = try XCTUnwrap(bar.geometry)
    let grab = NSPoint(x: 7, y: geometry.sliderPosition + 5)
    bar.mouseDown(with: bar.mouseEvent(.leftMouseDown, at: grab))
    bar.mouseDragged(with: bar.mouseEvent(.leftMouseDragged, at: grab.offset(dy: 30)))
    bar.mouseDragged(with: bar.mouseEvent(.leftMouseDragged, at: grab.offset(dy: 50)))
    XCTAssertEqual(hosted.firstLine, 0, "その場では当てない")
    let expected = geometry.firstLine(afterDragging: 50)
    pumpMain(until: { abs(hosted.firstLine - expected) < 0.05 }, "次の runloop で最新の位置へ")
    bar.mouseUp(with: bar.mouseEvent(.leftMouseUp, at: grab.offset(dy: 50)))
  }

  /// 印: 左レーンに git の追加・変更・削除、全幅にキャレットの行、左端と上端に縁。位置はスクロール全体に対する比例。
  func testRulerMarksGitChangesAndTheCaret() throws {
    let hosted = try hostOverview(numberedLines(200))
    hosted.document.baseline = numberedLines(200)
      .replacingOccurrences(of: "line 50\n", with: "line fifty\n")
      .replacingOccurrences(of: "line 100\n", with: "")
      .replacingOccurrences(of: "line 150\n", with: "line 150\nline gone\n")
    pumpMain(until: { hosted.document.hunks.count == 3 }, "ハンク")
    hosted.document.surface.selectedRange = NSRange(
      location: hosted.document.lineIndex.start(ofRow: 120), length: 0)
    let bar = hosted.pane.scrollbar
    let (_, visible) = hosted.document.viewportLines
    let scale = hosted.window.backingScaleFactor
    let ruler = OverviewRuler(
      lineCount: hosted.document.lineIndex.lineCount, visibleLines: visible,
      height: bar.bounds.height, scale: scale)
    func y(_ row: Int) -> CGFloat {
      let span = ruler.spans([row...row])[0]
      return CGFloat(span.y1 + span.y2) / 2 / scale
    }
    let left = CGFloat(OverviewRuler.lane(.left, width: 14, scale: scale).x + 1) / scale
    let pixels = try ViewPixels(bar)
    XCTAssertTrue(Hue.blue(pixels.color(left, y(49))), "行 50 は変更")
    XCTAssertTrue(Hue.green(pixels.color(left, y(99))), "行 100 は追加")
    XCTAssertTrue(Hue.red(pixels.color(left, y(149))), "削除はその境の上の行")
    XCTAssertEqual(pixels.color(left, y(10)).alphaComponent, 0, "印の無い行")
    let caret = ruler.caret(row: 120)
    let caretColor = pixels.color(10, CGFloat(caret.y1 + caret.y2) / 2 / scale)
    XCTAssertGreaterThan(caretColor.alphaComponent, 0.5, "キャレットの行は全幅")
    XCTAssertGreaterThan(pixels.color(0.25, 100).alphaComponent, 0, "左端の縁")
  }

  /// 検索の一致はスクロールバーの中央レーンに出る。一致が多いときは近い行をまとめた印になる。
  func testFindMatchesMarkTheCenterLane() throws {
    let text = (0..<200).map { $0 == 150 ? "the needle\n" : "hay\n" }.joined()
    let hosted = try hostOverview(text)
    let pane = hosted.pane
    pane.showSearch()
    pane.search.setNeedle("needle")
    // キャレットの印とつまみを一致の印から離す（つまみは印の上に重なる）。
    hosted.document.surface.selectedRange = NSRange(location: 0, length: 0)
    hosted.document.scroll(toFirstLine: 0)
    let bar = pane.scrollbar
    let (_, visible) = hosted.document.viewportLines
    let scale = hosted.window.backingScaleFactor
    let ruler = OverviewRuler(
      lineCount: hosted.document.lineIndex.lineCount, visibleLines: visible,
      height: bar.bounds.height, scale: scale)
    let span = ruler.spans([150...150])[0]
    let center = OverviewRuler.lane(.center, width: 14, scale: scale)
    let x = (CGFloat(center.x) + CGFloat(center.width) / 2) / scale
    let pixels = try ViewPixels(bar)
    let mark = pixels.color(x, CGFloat(span.y1 + span.y2) / 2 / scale)
    XCTAssertTrue(Hue.orange(mark), "中央レーンの一致: \(mark)")
    let left = CGFloat(OverviewRuler.lane(.left, width: 14, scale: scale).x + 1) / scale
    XCTAssertEqual(
      pixels.color(left, CGFloat(span.y1 + span.y2) / 2 / scale).alphaComponent, 0, "左レーンには出ない")
  }

  /// 先頭の行が上へ隠れている間は上端の影、本文が右に続くときはミニマップ左の影。どちらも本文の上だけに描く。
  func testShadowsFollowTheScrollAndTheWidth() throws {
    let hosted = try hostOverview(numberedLines(100) + String(repeating: "x", count: 400) + "\n")
    let pane = hosted.pane
    XCTAssertFalse(pane.scrollShadow.showsTop, "先頭では影が無い")
    hosted.document.scroll(toFirstLine: 3.5)
    pumpMain(until: { pane.scrollShadow.showsTop }, "スクロールすると上端に影")
    hosted.document.scroll(toFirstLine: 99)
    pumpMain(until: { hosted.document.surface.viewport.clipsRight }, "長い行が見える")
    XCTAssertEqual(pane.scrollShadow.frame.maxX, pane.minimap.frame.minX, "影は本文の上だけ（ミニマップに掛けない）")
    let edge = try XCTUnwrap(pane.scrollShadow.minimapEdge, "本文が右に続くときはミニマップ左の影")
    XCTAssertEqual(edge, pane.scrollShadow.bounds.width)
    hosted.document.scroll(toFirstLine: 3.5)
    let pixels = try ViewPixels(pane.scrollShadow)
    XCTAssertGreaterThan(pixels.color(edge - 7, 100).alphaComponent, 0, "6pt の帯の外側（左）に影")
    XCTAssertEqual(pixels.color(edge - 3, 100).alphaComponent, 0, "帯の中には描かない")
    XCTAssertGreaterThan(pixels.color(100, 0.5).alphaComponent, 0, "上端の影")
    XCTAssertEqual(pixels.color(100, 12).alphaComponent, 0, "上端の影は 6pt まで")
    hosted.document.scroll(toFirstLine: 0)
    pumpMain(until: { !pane.scrollShadow.showsTop }, "先頭に戻れば影は消える")
    let narrow = try hostOverview(numberedLines(10))
    XCTAssertNil(narrow.pane.scrollShadow.minimapEdge, "右に続かなければ左の影は無い")
  }
}
