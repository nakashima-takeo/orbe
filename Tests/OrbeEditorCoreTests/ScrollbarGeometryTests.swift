import Foundation
import XCTest

@testable import OrbeEditorCore

/// スクロールバーのつまみと印の写像。正解は VS Code（f83f3fba）の `ScrollbarState` と `DecorationsOverviewRuler` の
/// 描き方（`_renderOneLane`・キャレット）・`FindDecorations.set` の近似を、行高 18 で実行した値（VS Code は scrollTop を
/// px に丸めるので、先頭行は 1px ぶんの差を許す）。壊れるとつまみが本文とずれ、印が別の行を指し、トラックのクリックが
/// 押した所へ飛ばない。
final class ScrollbarGeometryTests: XCTestCase {
  private let pixel: CGFloat = 1.0 / 18

  func testSliderLengthPositionAndMappingsOfALongDocument() {
    let top = ScrollbarGeometry(lineCount: 1000, firstLine: 0, visibleLines: 20, height: 360)
    XCTAssertTrue(top.isNeeded)
    XCTAssertEqual(top.sliderLength, 20, "最小の長さ")
    XCTAssertEqual(top.sliderPosition, 0)
    XCTAssertEqual(top.firstLine(afterDragging: 10), 29.38888888888889, accuracy: pixel)
    XCTAssertEqual(top.firstLine(centeringSliderAt: 200), 558.2777777777778, accuracy: pixel)
    let mid = ScrollbarGeometry(lineCount: 1000, firstLine: 400.25, visibleLines: 20, height: 360)
    XCTAssertEqual(mid.sliderPosition, 136)
    XCTAssertEqual(mid.firstLine(afterDragging: 10), 429, accuracy: pixel)
    let end = ScrollbarGeometry(lineCount: 1000, firstLine: 999, visibleLines: 20, height: 360)
    XCTAssertEqual(end.sliderPosition, 340, "最終行が最上段でつまみは下端")
    XCTAssertEqual(end.maxFirstLine, 999)
    XCTAssertEqual(end.firstLine(afterDragging: 50), 999, "上限で止まる")
    XCTAssertEqual(top.firstLine(afterDragging: -50), 0, "下限で止まる")
  }

  func testShortDocumentsCanStillScrollTheLastLineToTheTop() {
    let short = ScrollbarGeometry(lineCount: 5, firstLine: 0, visibleLines: 20, height: 360)
    XCTAssertTrue(short.isNeeded)
    XCTAssertEqual(short.sliderLength, 300)
    XCTAssertEqual(short.firstLine(afterDragging: 10), 0.6666666666666666, accuracy: pixel)
    XCTAssertEqual(short.firstLine(centeringSliderAt: 200), 3.3333333333333335, accuracy: pixel)
    let mid = ScrollbarGeometry(lineCount: 60, firstLine: 10, visibleLines: 20.5, height: 369)
    XCTAssertEqual(mid.sliderLength, 95)
    XCTAssertEqual(mid.sliderPosition, 46)
    XCTAssertEqual(mid.firstLine(afterDragging: 10), 12.055555555555555, accuracy: pixel)
    XCTAssertFalse(
      ScrollbarGeometry(lineCount: 1, firstLine: 0, visibleLines: 20, height: 360).isNeeded)
  }

  func testRulerMapsRowsProportionallyWithAMinimumHeightAndMergesNeighbours() {
    let rows: [ClosedRange<Int>] = [0...0, 2...2, 99...139, 499...499, 998...999]
    let oneX = OverviewRuler(lineCount: 1000, visibleLines: 20.5, height: 400, scale: 1)
    XCTAssertEqual(
      oneX.spans(rows).map { [$0.y1, $0.y2] }, [[0, 6], [38, 54], [192, 198], [388, 394]])
    let twoX = OverviewRuler(lineCount: 1000, visibleLines: 20.5, height: 400, scale: 2)
    XCTAssertEqual(
      twoX.spans(rows).map { [$0.y1, $0.y2] }, [[0, 12], [77, 109], [385, 397], [777, 789]])
    XCTAssertEqual([oneX.caret(row: 0).y1, oneX.caret(row: 0).y2], [0, 2])
    XCTAssertEqual([oneX.caret(row: 499).y1, oneX.caret(row: 499).y2], [194, 196])
    XCTAssertEqual([twoX.caret(row: 999).y1, twoX.caret(row: 999).y2], [781, 785])
  }

  func testRulerLanesSplitTheWidthAfterTheBorderPixel() {
    XCTAssertEqual(OverviewRuler.lane(.left, width: 14, scale: 1).x, 1)
    XCTAssertEqual(OverviewRuler.lane(.left, width: 14, scale: 1).width, 4)
    XCTAssertEqual(OverviewRuler.lane(.center, width: 14, scale: 1).x, 5)
    XCTAssertEqual(OverviewRuler.lane(.center, width: 14, scale: 1).width, 5)
    XCTAssertEqual(OverviewRuler.lane(.right, width: 14, scale: 1).x, 10)
    XCTAssertEqual(OverviewRuler.lane(.full, width: 14, scale: 2).width, 27)
    XCTAssertEqual(OverviewRuler.lane(.center, width: 14, scale: 2).width, 9)
  }

  /// 一致が多いとき、近い行（`max(2, ceil(3 / (高さ / 行数)))` 行以内）はまとめる。
  func testApproximationMergesNearbyRows() {
    XCTAssertEqual(
      OverviewRuler.approximate(
        [0...0, 9...9, 47...47, 48...48, 199...200], lineCount: 5000, height: 400),
      [0...48, 199...200])
    XCTAssertEqual(OverviewRuler.approximate([], lineCount: 10, height: 400), [])
  }
}
