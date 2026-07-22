import CoreGraphics
import XCTest

@testable import Orbe

/// `SurfaceView.surfacePixels` の境界値検証。
/// libghostty の size 事前条件（非負・非ゼロ面積・確定 scale）を C API 直前で強制する要（かなめ）で、
/// レイアウト途中の不正中間フレーム（負・NaN・∞・ゼロ）を弾き、正常フレームは期待ピクセルを返す。
final class SurfaceSizeTests: XCTestCase {
  // MARK: - 正常値

  /// 確定した非負フレームは bounds × scale の切り捨てピクセルを返す（見た目の回帰なし）。
  func testValidBoundsReturnsPixels() {
    let px = SurfaceView.surfacePixels(bounds: CGSize(width: 800, height: 500), scale: 2)
    XCTAssertEqual(px?.width, 1600)
    XCTAssertEqual(px?.height, 1000)
  }

  /// 端数は現行の暗黙切り捨て（`UInt32(浮動小数)`）と同じく `.down` する。
  func testFractionalPixelsRoundDown() {
    let px = SurfaceView.surfacePixels(bounds: CGSize(width: 100.4, height: 50.9), scale: 1)
    XCTAssertEqual(px?.width, 100)
    XCTAssertEqual(px?.height, 50)
  }

  /// scale 非整数でも積の切り捨てで導出する。
  func testNonIntegerScale() {
    let px = SurfaceView.surfacePixels(bounds: CGSize(width: 100, height: 100), scale: 1.5)
    XCTAssertEqual(px?.width, 150)
    XCTAssertEqual(px?.height, 150)
  }

  // MARK: - 不正・ゼロ面積の中間フレーム → nil

  func testNegativeWidthReturnsNil() {
    XCTAssertNil(SurfaceView.surfacePixels(bounds: CGSize(width: -10, height: 500), scale: 2))
  }

  func testNegativeHeightReturnsNil() {
    XCTAssertNil(SurfaceView.surfacePixels(bounds: CGSize(width: 800, height: -10), scale: 2))
  }

  func testZeroWidthReturnsNil() {
    XCTAssertNil(SurfaceView.surfacePixels(bounds: CGSize(width: 0, height: 500), scale: 2))
  }

  func testZeroHeightReturnsNil() {
    XCTAssertNil(SurfaceView.surfacePixels(bounds: CGSize(width: 800, height: 0), scale: 2))
  }

  func testZeroScaleReturnsNil() {
    XCTAssertNil(SurfaceView.surfacePixels(bounds: CGSize(width: 800, height: 500), scale: 0))
  }

  func testNegativeScaleReturnsNil() {
    XCTAssertNil(SurfaceView.surfacePixels(bounds: CGSize(width: 800, height: 500), scale: -2))
  }

  func testNaNBoundsReturnsNil() {
    XCTAssertNil(
      SurfaceView.surfacePixels(bounds: CGSize(width: CGFloat.nan, height: 500), scale: 2))
    XCTAssertNil(
      SurfaceView.surfacePixels(bounds: CGSize(width: 800, height: CGFloat.nan), scale: 2))
  }

  func testInfiniteBoundsReturnsNil() {
    XCTAssertNil(
      SurfaceView.surfacePixels(bounds: CGSize(width: CGFloat.infinity, height: 500), scale: 2))
    XCTAssertNil(
      SurfaceView.surfacePixels(bounds: CGSize(width: 800, height: CGFloat.infinity), scale: 2))
  }

  func testNaNScaleReturnsNil() {
    XCTAssertNil(SurfaceView.surfacePixels(bounds: CGSize(width: 800, height: 500), scale: .nan))
  }

  /// 積が 1px 未満（サブピクセル）になるフレームも面積ゼロ扱いで弾く。
  func testSubPixelAreaReturnsNil() {
    XCTAssertNil(SurfaceView.surfacePixels(bounds: CGSize(width: 0.4, height: 0.4), scale: 1))
  }
}
