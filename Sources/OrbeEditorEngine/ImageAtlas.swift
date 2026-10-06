import Metal

/// 区画の画像の地図（面ごと。描画スレッドだけが触る）。main が倍率で描いた画素（`ZonePixels`）を、鍵ごとに 1 回だけ頁へ
/// 写す。頁が上限まで埋まれば全体を作り直す（作り直したコマの残りの画像は描かず、次のコマで置き直す——同じコマで先に
/// 置いた画像の場所を上書きしない）。
final class ImageAtlas {
  struct Entry {
    var page: Int
    var x: Int
    var y: Int
    var width: Int
    var height: Int
  }

  static let pageSize = 1024
  static let maximumPages = 4

  private let device: MTLDevice
  private(set) var pages: [MTLTexture] = []
  private var packers: [ShelfPacker] = []
  private var entries: [Int: Entry] = [:]
  /// このコマで作り直した。
  private var exhausted = false

  init(device: MTLDevice) {
    self.device = device
  }

  /// コマを組み始める。
  func beginFrame() {
    exhausted = false
  }

  /// 画素 `pixels` の置き場所（無ければ写す）。置けなければ地図を空にして nil。
  func entry(_ pixels: ZonePixels) -> Entry? {
    if let entry = entries[pixels.key] { return entry }
    guard !exhausted else { return nil }
    guard let entry = place(pixels.width, pixels.height) else {
      exhausted = true
      entries.removeAll()
      packers = packers.map { ShelfPacker(size: $0.size) }
      return nil
    }
    pages[entry.page].replace(
      region: MTLRegionMake2D(entry.x, entry.y, pixels.width, pixels.height), mipmapLevel: 0,
      withBytes: pixels.bytes, bytesPerRow: pixels.width * 4)
    entries[pixels.key] = entry
    return entry
  }

  /// `w`×`h` の置き場所（頁が上限まで埋まれば nil）。
  private func place(_ w: Int, _ h: Int) -> Entry? {
    for page in packers.indices {
      if let spot = packers[page].place(w, h) {
        return Entry(page: page, x: spot.x, y: spot.y, width: w, height: h)
      }
    }
    guard pages.count < Self.maximumPages else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: Self.pageSize, height: Self.pageSize, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    pages.append(texture)
    packers.append(ShelfPacker(size: Self.pageSize))
    guard let spot = packers[packers.count - 1].place(w, h) else { return nil }
    return Entry(page: pages.count - 1, x: spot.x, y: spot.y, width: w, height: h)
  }
}
