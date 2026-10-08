import Metal
import XCTest

@testable import OrbeEditorEngine

/// 区画の画像の地図——上限の大きさの画像が頁に収まり、前のコマの画像が場所を取って埋まれば置いた場所を空けずに埋まった
/// ことを示し、作り直すまで新しい画像を置かない。空の地図から始めたコマだけで埋まれば示さない。壊れると、上限の大きさの
/// 画像が 1 頁に 1 枚しか入らず毎コマ作り直す・GPU が読んでいる頁へ次のコマが別の画素を書く・収まらない画像が見えている
/// 間ずっと描き直し続ける。
final class ImageAtlasTests: XCTestCase {
  private var nextKey = 0

  private func pixels(_ side: Int) -> ZonePixels {
    nextKey += 1
    return ZonePixels(
      key: nextKey, width: side, height: side,
      bytes: [UInt8](repeating: 0xFF, count: side * side * 4))
  }

  private func atlas() throws -> ImageAtlas {
    ImageAtlas(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
  }

  /// 前のコマの画像で埋まった地図に新しい画像を置けなければ、埋まったことを示し、作り直すまで置かない。置いた場所は空けない。
  func testImagesAtTheLimitFillEveryPageAndAFullAtlasKeepsItsPlacesUntilReset() throws {
    let atlas = try atlas()
    let side = ImageAtlas.maximumSide
    atlas.beginFrame()
    let placed = (0..<(4 * ImageAtlas.maximumPages)).map { _ in pixels(side) }
    for image in placed { XCTAssertNotNil(atlas.entry(image), "1 頁に 4 枚ずつ入る") }
    XCTAssertFalse(atlas.isFull)
    atlas.beginFrame()
    XCTAssertNil(atlas.entry(pixels(side)))
    XCTAssertTrue(atlas.isFull, "前のコマの画像が場所を取っていれば、埋まったことを示す")
    XCTAssertNil(atlas.entry(pixels(1)), "作り直すまで新しい画像は置かない")
    XCTAssertNotNil(atlas.entry(placed[0]), "置いた場所は空けない")
    atlas.reset()
    XCTAssertFalse(atlas.isFull)
    atlas.beginFrame()
    XCTAssertNotNil(atlas.entry(pixels(side)))
  }

  /// 空の地図から始めたコマだけで埋まれば、置けない画像は描かないが、埋まったことは示さない（作り直しても同じなので描き
  /// 直さない）。置いた画像は次のコマでも使える。
  func testAFrameThatAloneOverflowsDropsTheRestWithoutAskingForAReset() throws {
    let atlas = try atlas()
    let side = ImageAtlas.maximumSide
    atlas.beginFrame()
    let placed = (0..<(4 * ImageAtlas.maximumPages)).map { _ in pixels(side) }
    for image in placed { XCTAssertNotNil(atlas.entry(image)) }
    XCTAssertNil(atlas.entry(pixels(side)), "収まらない画像は描かない")
    XCTAssertFalse(atlas.isFull, "作り直しを求めない")
    atlas.beginFrame()
    XCTAssertNotNil(atlas.entry(placed[0]), "置いた画像は次のコマでも使える")
  }
}
