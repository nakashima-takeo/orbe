import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面の右列（ミニマップ＋縦スクロールバー）の配置と、その上のホイール（今の面の俯瞰と同じ規則）。壊れるとミニマップが
/// VS Code の幅にならない（広い面で上限を超える・狭い面や行番号の列が広い面で本文を削る）、スクロールバーが右端に無い、
/// 俯瞰の上でホイールを回しても本文が動かない。
@MainActor
final class SurfaceRightColumnTests: EngineTestCase {
  /// 右端に縦スクロールバー（幅 14）、その左にミニマップ、その左が本文の区画。ミニマップは広い面では上限 120 で止まり、
  /// 狭い面では細くなり、行番号の列が広い（行が多い）ほど細くなる。
  func testTheRightColumnIsTheMinimapThenTheScrollbar() throws {
    let wide = try open(rows(10), size: CGSize(width: 2400, height: 400)).surface.surfaceLayout
    XCTAssertEqual(wide.verticalScrollbar.width, 14)
    XCTAssertEqual(wide.verticalScrollbar.maxX, 2400)
    XCTAssertEqual(wide.minimap.maxX, wide.verticalScrollbar.minX)
    XCTAssertEqual(wide.text.maxX, wide.minimap.minX)
    XCTAssertEqual(wide.minimap.width, 120, "広い面では上限で止まる")

    let size = CGSize(width: 500, height: 400)
    let few = try open(rows(10), size: size, waitForColors: false).surface.surfaceLayout
    let many = try open(rows(10_000), size: size, waitForColors: false).surface.surfaceLayout
    XCTAssertLessThan(few.minimap.width, 120, "狭い面では細くなる")
    XCTAssertGreaterThan(many.column, few.column, "前提: 行番号の列が広い")
    XCTAssertLessThan(many.minimap.width, few.minimap.width, "行番号の列が広いほど細くなる")
    XCTAssertEqual(many.text.maxX, many.minimap.minX)
  }

  /// 俯瞰（ミニマップ・縦スクロールバー）の上のホイールは本文を動かす——俯瞰の区画で当たる子 view から面へ流れる。
  func testWheelOverTheOverviewScrollsTheText() throws {
    let opened = try hosted(rows(400))
    let view = opened.surface.textView
    let layout = opened.surface.surfaceLayout
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -90, wheel2: 0,
        wheel3: 0))
    for point in [
      CGPoint(x: layout.minimap.midX, y: 200), CGPoint(x: layout.verticalScrollbar.midX, y: 200),
    ] {
      let target = try XCTUnwrap(view.hitTest(view.convert(point, to: view.superview)))
      XCTAssertTrue(target !== view, "前提: \(point) は俯瞰の子 view が当たる")
      let before = opened.surface.viewportLines.first
      target.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
      XCTAssertEqual(opened.surface.viewportLines.first, before + 5, accuracy: 1e-9, "\(point)")
    }
  }
}
