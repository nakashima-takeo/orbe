import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の縦スクロールバーの印と縁と影（VS Code と同じ規則）。壊れると git の変更・検索の一致・語の出現・キャレットの
/// 位置がスクロールバーに出ない・違うレーンに出る、前へ伸ばした選択でキャレットの印が動かない側の端に出る、縁が無い、
/// 上に隠れた行や右に続く本文があるのに影が出ない（無いのに出る）、影がミニマップに掛かる。
@MainActor
final class SurfaceOverviewMarksTests: EngineTestCase {
  private static let white = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)

  /// 印の種類ごとに見分けられる不透明な色の見え方。
  private var style: TextSurfaceStyle {
    var style = EngineTestCase.style()
    style.overview.scrollbar.added = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    style.overview.scrollbar.findMatch = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    style.overview.scrollbar.wordOccurrence = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    style.overview.scrollbar.caret = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    return style
  }

  /// git の印は左のレーン、検索の一致と語の出現は中央のレーン、キャレットは全幅に、その行の高さに出る。
  func testRulerMarksGitFindWordAndTheCaretInTheirLanes() throws {
    let lines = (0..<40).map { "line \($0)\n" }.joined()
    let opened = try open(
      lines, size: CGSize(width: 800, height: 400), style: style, waitForColors: false)
    opened.document.baseline = lines.replacingOccurrences(of: "line 5\n", with: "")
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    let rope = opened.document.text
    opened.surface.setHighlights(
      [NSRange(location: rope.lineStart(20), length: 4)], for: .findMatch)
    opened.surface.setHighlights(
      [NSRange(location: rope.lineStart(25), length: 4)], for: .wordOccurrence)
    opened.surface.selectedRange = NSRange(location: rope.lineStart(30), length: 0)
    let shot = try pixelShot(opened)
    let bar = opened.surface.surfaceLayout.verticalScrollbar
    let ruler = OverviewRuler(
      lineCount: rope.lineCount, visibleLines: opened.surface.viewportLines.visible,
      height: bar.height, scale: 2)
    let at = { (lane: OverviewRuler.Lane, span: OverviewRuler.Span) -> [Int] in
      let x = OverviewRuler.lane(lane, width: bar.width, scale: 2)
      return shot.rgb(
        bar.minX + CGFloat(2 * x.x + x.width) / 4, bar.minY + CGFloat(span.y1 + span.y2) / 4)
    }
    let row = { (row: Int) in ruler.spans([row...row])[0] }
    XCTAssertEqual(at(.left, row(5)), [0, 255, 0], "追加は左のレーン")
    XCTAssertEqual(at(.center, row(5)), [0, 0, 0])
    XCTAssertEqual(at(.center, row(20)), [255, 0, 0], "検索の一致は中央のレーン")
    XCTAssertEqual(at(.left, row(20)), [0, 0, 0])
    XCTAssertEqual(at(.center, row(25)), [0, 0, 255], "語の出現は中央のレーン")
    let caret = ruler.caret(row: 30)
    XCTAssertEqual(at(.left, caret), [255, 255, 255], "キャレットは全幅")
    XCTAssertEqual(at(.center, caret), [255, 255, 255])
    XCTAssertEqual(at(.left, row(10)), [0, 0, 0], "印の無い行")
  }

  /// 上端の影は先頭の行が隠れている間だけ、本文の上端に出る。
  func testTheTopShadowShowsOnlyWhileTheFirstLineIsHidden() throws {
    let opened = try open(
      (0..<200).map { "row \($0)\n" }.joined(), size: CGSize(width: 800, height: 400))
    let x = opened.surface.surfaceLayout.text.minX + 20
    XCTAssertEqual(
      try pixelShot(opened, background: Self.white).rgb(x, 0.25), [255, 255, 255], "先頭が見えていれば無い")
    opened.surface.scroll(toFirstLine: 10)
    let scrolled = try pixelShot(opened, background: Self.white).rgb(x, 0.25)
    XCTAssertLessThan(scrolled[0], 200, "先頭が隠れていれば出る: \(scrolled)")
  }

  /// ミニマップの左の影は本文が右に続く間だけ、ミニマップの左 6pt の帯の外側（左）に、本文の上だけに出る。
  func testTheMinimapShadowShowsOnlyWhileTheTextContinuesToTheRight() throws {
    var style = EngineTestCase.style()
    style.overview.minimapShadow = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    let opened = try open(
      String(repeating: "x", count: 400) + String(repeating: "\n", count: 60),
      size: CGSize(width: 800, height: 400), style: style)
    _ = opened.surface.snapshot()
    pump(until: { opened.surface.clipsRight }, "前提: 長い行の長さを測った")
    let edge = opened.surface.surfaceLayout.minimap.minX
    let y: CGFloat = 200
    let shot = try pixelShot(opened, background: Self.white)
    let outside = shot.rgb(edge - 7, y)
    XCTAssertLessThan(outside[0], 200, "帯の外側に影: \(outside)")
    XCTAssertEqual(shot.rgb(edge - 3, y), [255, 255, 255], "帯の中には描かない")
    XCTAssertEqual(shot.rgb(edge + 0.5, y), [255, 255, 255], "ミニマップに掛けない")
    opened.surface.scroll(toX: opened.surface.scrollState().limits.maximum.x)
    XCTAssertFalse(opened.surface.clipsRight, "前提: 右端まで送った")
    XCTAssertEqual(
      try pixelShot(opened, background: Self.white).rgb(edge - 7, y), [255, 255, 255],
      "右に続かなければ無い")
  }

  /// キャレットの印は選択の動く側の端（キャレット）の行に出る——後ろへ伸ばせば終わりの行、前へ伸ばせば先頭の行。
  func testTheCaretMarkFollowsTheMovingEndOfTheSelection() throws {
    let opened = try open(
      (0..<200).map { "line \($0)\n" }.joined(), size: CGSize(width: 800, height: 400),
      style: style)
    let rope = opened.document.text
    let surface = opened.surface
    let bar = surface.surfaceLayout.verticalScrollbar
    let ruler = OverviewRuler(
      lineCount: rope.lineCount, visibleLines: surface.viewportLines.visible, height: bar.height,
      scale: 2)
    let marked = { (row: Int) throws -> Bool in
      let span = ruler.caret(row: row)
      return try self.pixelShot(opened).rgb(bar.midX, bar.minY + CGFloat(span.y1 + span.y2) / 4)
        == [255, 255, 255]
    }
    surface.selectedRange = NSRange(
      location: rope.lineStart(60), length: rope.lineStart(140) - rope.lineStart(60))
    XCTAssertTrue(try marked(140), "後ろへ伸ばした選択は終わりの行")
    XCTAssertFalse(try marked(60))
    surface.selectedRange = NSRange(location: rope.lineStart(140), length: 0)
    for _ in 0..<80 {
      surface.responder.doCommand(
        by: #selector(NSStandardKeyBindingResponding.moveUpAndModifySelection(_:)))
    }
    XCTAssertEqual(
      surface.selectedRange,
      NSRange(location: rope.lineStart(60), length: rope.lineStart(140) - rope.lineStart(60)),
      "前提: 前へ伸ばした")
    XCTAssertTrue(try marked(60), "前へ伸ばした選択は先頭の行")
    XCTAssertFalse(try marked(140))
  }

  /// 縦スクロールバーの左端と上端に 1 デバイス px の縁が出る。
  func testTheRulerHasABorderOnItsLeftAndTopEdges() throws {
    var style = EngineTestCase.style()
    style.overview.scrollbar.border = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
    let opened = try open(
      (0..<200).map { "line \($0)\n" }.joined(), size: CGSize(width: 800, height: 400),
      style: style)
    opened.surface.selectedRange = NSRange(location: opened.document.text.lineStart(100), length: 0)
    let shot = try pixelShot(opened)
    let bar = opened.surface.surfaceLayout.verticalScrollbar
    XCTAssertEqual(shot.rgb(bar.minX + 0.25, 100), [255, 0, 255], "左端の縁")
    XCTAssertEqual(shot.rgb(bar.minX + 0.75, 100), [0, 0, 0], "縁は 1 デバイス px")
    XCTAssertEqual(shot.rgb(bar.midX, 0.25), [255, 0, 255], "上端の縁")
    XCTAssertEqual(shot.rgb(bar.midX, 0.75), [0, 0, 0])
  }
}
