import Metal
import XCTest

@testable import OrbeEditorEngine

/// 区画の画像の地図——上限の大きさの画像が頁に収まり、埋まっても置いた場所を空けずに埋まったことを示し、作り直すまで新しい
/// 画像を置かない。壊れると、上限の大きさの画像が 1 頁に 1 枚しか入らず毎コマ作り直す・GPU が読んでいる頁へ次のコマが別の
/// 画素を書く。
final class ImageAtlasTests: XCTestCase {
  private var nextKey = 0

  private func pixels(_ side: Int) -> ZonePixels {
    nextKey += 1
    return ZonePixels(
      key: nextKey, width: side, height: side,
      bytes: [UInt8](repeating: 0xFF, count: side * side * 4))
  }

  func testImagesAtTheLimitFillEveryPageAndAFullAtlasKeepsItsPlacesUntilReset() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let atlas = ImageAtlas(device: device)
    let side = ImageAtlas.maximumSide
    let placed = (0..<(4 * ImageAtlas.maximumPages)).map { _ in pixels(side) }
    for image in placed { XCTAssertNotNil(atlas.entry(image), "1 頁に 4 枚ずつ入る") }
    XCTAssertFalse(atlas.isFull)
    XCTAssertNil(atlas.entry(pixels(side)))
    XCTAssertTrue(atlas.isFull, "置けなければ埋まったことを示す")
    XCTAssertNil(atlas.entry(pixels(1)), "作り直すまで新しい画像は置かない")
    XCTAssertNotNil(atlas.entry(placed[0]), "置いた場所は空けない")
    atlas.reset()
    XCTAssertFalse(atlas.isFull)
    XCTAssertNotNil(atlas.entry(pixels(side)))
  }
}
