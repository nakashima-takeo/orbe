import CoreGraphics
import XCTest

@testable import Orbe

/// `SurfaceView.surfacePixels` の境界値検証。
/// libghostty の size 事前条件（非負・非ゼロ面積・確定 scale）を C API 直前で強制する要（かなめ）で、
/// レイアウト途中の不正中間フレーム（負・NaN・∞・ゼロ）を弾き、正常フレームは期待ピクセルを返す。
final class SurfaceSizeTests: OrbeTestCase {
  /// 確定した非負フレームは bounds × scale を切り捨てたピクセルを返す（scale が非整数でも積の切り捨て）。
  func testValidBoundsReturnFlooredPixels() {
    let retina = SurfaceView.surfacePixels(bounds: CGSize(width: 800, height: 500), scale: 2)
    XCTAssertEqual(retina?.width, 1600)
    XCTAssertEqual(retina?.height, 1000)
    let fractional = SurfaceView.surfacePixels(
      bounds: CGSize(width: 100.4, height: 50.9), scale: 1.5)
    XCTAssertEqual(fractional?.width, 150)
    XCTAssertEqual(fractional?.height, 76)
  }

  /// 負・ゼロ・NaN・∞ の寸法と scale、積が 1px 未満になるフレームは nil で弾く。
  func testInvalidOrZeroAreaFramesReturnNil() {
    let frames: [(CGSize, CGFloat)] = [
      (CGSize(width: -10, height: 500), 2),
      (CGSize(width: 800, height: 0), 2),
      (CGSize(width: 800, height: 500), 0),
      (CGSize(width: 800, height: 500), -2),
      (CGSize(width: CGFloat.nan, height: 500), 2),
      (CGSize(width: 800, height: 500), .nan),
      (CGSize(width: 800, height: CGFloat.infinity), 2),
      (CGSize(width: 0.4, height: 0.4), 1),
    ]
    for (bounds, scale) in frames {
      XCTAssertNil(SurfaceView.surfacePixels(bounds: bounds, scale: scale), "\(bounds) × \(scale)")
    }
  }
}
