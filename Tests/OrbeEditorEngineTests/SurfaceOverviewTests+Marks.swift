import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面の縦スクロールバーの印と影（今の面の俯瞰と同じ規則）。壊れると git の変更・検索の一致・語の出現・キャレットの
/// 位置がスクロールバーに出ない・違うレーンに出る、上に隠れた行があるのに影が出ない（無いのに出る）。
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
}
