import Metal

/// 区画の画像の地図（面ごと。描画スレッドだけが触る）。main が倍率で描いた画素（`ZonePixels`）を、鍵ごとに 1 回だけ頁へ
/// 写す。頁が上限まで埋まって置けない画像は、そのコマに描かない。
///
/// - 前のコマまでの画像が場所を取っていたなら、埋まったことを示す（`isFull`）。描画の口が、GPU が前のコマの頁を読み終えて
///   から作り直し（`reset`。読んでいる途中の場所へ別の画素を書かない）、そのコマを描き直す。
/// - 空の地図から始めたコマだけで埋まったなら、作り直しても同じ所で埋まるので示さない——置けた画像だけを描き、残りは
///   描かずに終える（描き直し続けない）。1 コマに見えている画像が地図に収まる量（上限の大きさなら頁 × 4 枚）を超えると、
///   超えた分は描かれない。
///
/// `GlyphAtlas` と同じ契約。
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
  /// 画像の辺の上限（px）——上限の大きさの画像が、棚詰めの隙間を含めて 1 頁に 4 枚入る。
  static let maximumSide = pageSize / 2 - ShelfPacker.gap

  private let device: MTLDevice
  private(set) var pages: [MTLTexture] = []
  private var packers: [ShelfPacker] = []
  private var entries: [Int: Entry] = [:]
  /// 前のコマまでの画像が場所を取っていて置けない画像があった（作り直すまで新しい画像は置かない）。
  private(set) var isFull = false
  /// このコマの始まりに、前のコマまでの画像が地図にあった。
  private var holdsEarlierFrames = false

  init(device: MTLDevice) {
    self.device = device
  }

  /// コマを組み始める。
  func beginFrame() {
    holdsEarlierFrames = !entries.isEmpty
  }

  /// 頁を空にする（GPU が頁を読んでいない時だけ呼ぶ）。
  func reset() {
    entries.removeAll()
    packers = packers.map { ShelfPacker(size: $0.size) }
    isFull = false
  }

  /// 画素 `pixels` の置き場所（無ければ写す）。置けなければ nil（前のコマまでの画像が場所を取っていたなら埋まったことを
  /// 示す）。
  func entry(_ pixels: ZonePixels) -> Entry? {
    if let entry = entries[pixels.key] { return entry }
    guard !isFull else { return nil }
    guard let entry = place(pixels.width, pixels.height) else {
      isFull = holdsEarlierFrames
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
