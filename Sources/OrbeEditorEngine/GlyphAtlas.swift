import CoreGraphics
import CoreText
import Metal

/// グリフのアトラス（倍率ごとに 1 つを全部の面で共有する。描画スレッドだけが触る）。Core Text でラスタライズし、Core Text
/// の描き方を再現する——鍵は（フォント、グリフ、横の少数ピクセル位置、太らせの段）。
///
/// - 横の少数ピクセル位置は Core Text の量子化に合わせる（字の原点を 1x で 1/3px、2x で 1/2px、3x 以上で 1px に切り捨てる）。
/// - 太らせ（font smoothing 相当）は 5 段（0 は太らせ無し）。字の色からどの段にするかは `DilationProbe` が決める。
/// - 色付きのグリフ（絵文字）は RGBA の別の頁に置く。
/// - 頁が埋まれば頁を足す。上限に当たれば全体を作り直す（追い出しはしない）。
final class GlyphAtlas {
  struct Entry {
    var u: Int16
    var v: Int16
    var w: Int16
    var h: Int16
    /// ペン位置の整数 px から見た画像の左端。
    var left: Int16
    /// 基線から見た画像の上端（上が正）。
    var top: Int16
    var page: UInt8
    var isColor: Bool
  }

  static let monoPageSize = 2048
  static let colorPageSize = 1024
  static let maximumPages = 8

  static func subpixelVariants(scale: CGFloat) -> Int { scale >= 3 ? 1 : (scale >= 2 ? 2 : 3) }

  let scale: CGFloat
  let variants: Int
  private let fonts: FontRegistry
  private let device: MTLDevice
  private(set) var monoPages: [MTLTexture] = []
  private(set) var colorPages: [MTLTexture] = []
  private var monoPackers: [ShelfPacker] = []
  private var colorPackers: [ShelfPacker] = []
  private var entries: [UInt64: Entry] = [:]
  /// 頁が上限まで埋まった。次のコマの前に作り直す。
  private(set) var isFull = false
  /// 作り直した回数（描いた絵の鍵に入れる）。
  private(set) var generation = 0

  init(device: MTLDevice, scale: CGFloat, fonts: FontRegistry) {
    self.device = device
    self.scale = scale
    self.fonts = fonts
    variants = Self.subpixelVariants(scale: scale)
  }

  /// 頁を空にして作り直す（頁の texture は使い回す）。
  func reset() {
    entries.removeAll()
    monoPackers = monoPackers.map { ShelfPacker(size: $0.size) }
    colorPackers = colorPackers.map { ShelfPacker(size: $0.size) }
    isFull = false
    generation += 1
  }

  func entry(font: UInt16, glyph: CGGlyph, variant: Int, dilation: Int) -> Entry? {
    let dilation = fonts.font(font).isColor ? 0 : dilation
    let key =
      UInt64(font) << 40 | UInt64(glyph) << 8 | UInt64(variant) << 4 | UInt64(dilation)
    if let entry = entries[key] { return entry.w == 0 ? nil : entry }
    guard let entry = rasterize(font: font, glyph: glyph, variant: variant, dilation: dilation)
    else { return nil }
    entries[key] = entry
    return entry.w == 0 ? nil : entry
  }

  /// 描くものが無いグリフは空の項目。頁が埋まって置けなければ nil（その字はこのコマに出ない）。
  private func rasterize(font id: UInt16, glyph: CGGlyph, variant: Int, dilation: Int) -> Entry? {
    let (font, isColor) = fonts.font(id)
    let empty = Entry(u: 0, v: 0, w: 0, h: 0, left: 0, top: 0, page: 0, isColor: false)
    var glyph = glyph
    var rect = CGRect.zero
    CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &rect, 1)
    guard !rect.isEmpty else { return empty }
    let shift = CGFloat(variant) / CGFloat(variants)
    // 縁のにじみの分、1px ずつ広げる。
    let x0 = Int((rect.minX * scale + shift).rounded(.down)) - 1
    let x1 = Int((rect.maxX * scale + shift).rounded(.up)) + 1
    let y0 = Int((rect.minY * scale).rounded(.down)) - 1
    let y1 = Int((rect.maxY * scale).rounded(.up)) + 1
    let w = x1 - x0
    let h = y1 - y0
    guard w > 0, h > 0, w < 512, h < 512 else { return empty }
    let bytesPerPixel = isColor ? 4 : 1
    var bytes = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      let context =
        isColor
        ? CGContext(
          data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        : CGContext(
          data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
      guard let context else { return false }
      context.setAllowsAntialiasing(true)
      context.setShouldAntialias(true)
      context.setAllowsFontSubpixelPositioning(true)
      context.setShouldSubpixelPositionFonts(true)
      context.setAllowsFontSubpixelQuantization(false)
      context.setShouldSubpixelQuantizeFonts(false)
      if dilation > 0 {
        // 字の色の明るさに応じた太らせを Core Graphics にさせる（塗りの明るさで段が決まる）。
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)
        context.setFillColor(gray: CGFloat(dilation) * 0.25, alpha: 1)
      } else {
        context.setShouldSmoothFonts(false)
        context.setFillColor(gray: 0, alpha: 1)
      }
      context.translateBy(x: CGFloat(-x0) + shift, y: CGFloat(-y0))
      context.scaleBy(x: scale, y: scale)
      var origin = CGPoint.zero
      CTFontDrawGlyphs(font, &glyph, &origin, 1, context)
      return true
    }
    guard drawn, let slot = place(w, h, color: isColor) else { return nil }
    let texture = isColor ? colorPages[slot.page] : monoPages[slot.page]
    texture.replace(
      region: MTLRegionMake2D(slot.x, slot.y, w, h), mipmapLevel: 0, withBytes: bytes,
      bytesPerRow: w * bytesPerPixel)
    return Entry(
      u: Int16(slot.x), v: Int16(slot.y), w: Int16(w), h: Int16(h), left: Int16(x0),
      top: Int16(y1), page: UInt8(slot.page), isColor: isColor)
  }

  /// 頁の中の置き場所。
  private struct Slot {
    var page: Int
    var x: Int
    var y: Int
  }

  private func place(_ w: Int, _ h: Int, color: Bool) -> Slot? {
    let count = color ? colorPackers.count : monoPackers.count
    for page in 0..<count {
      let spot = color ? colorPackers[page].place(w, h) : monoPackers[page].place(w, h)
      if let spot { return Slot(page: page, x: spot.x, y: spot.y) }
    }
    guard count < Self.maximumPages, addPage(color: color) else {
      isFull = true
      return nil
    }
    let spot = color ? colorPackers[count].place(w, h) : monoPackers[count].place(w, h)
    return spot.map { Slot(page: count, x: $0.x, y: $0.y) }
  }

  private func addPage(color: Bool) -> Bool {
    let size = color ? Self.colorPageSize : Self.monoPageSize
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: color ? .rgba8Unorm : .r8Unorm, width: size, height: size, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { return false }
    if color {
      colorPages.append(texture)
      colorPackers.append(ShelfPacker(size: size))
    } else {
      monoPages.append(texture)
      monoPackers.append(ShelfPacker(size: size))
    }
    return true
  }
}

/// 棚詰め。高さの近い棚へ左から詰め、無ければ下に棚を足す。
struct ShelfPacker {
  let size: Int
  private struct Shelf {
    var y: Int
    var h: Int
    var x: Int
  }

  private var shelves: [Shelf] = []
  private var nextY = 0

  init(size: Int) {
    self.size = size
  }

  mutating func place(_ w: Int, _ h: Int) -> (x: Int, y: Int)? {
    let pw = w + 1
    let ph = h + 1
    for i in shelves.indices
    where shelves[i].h >= ph && shelves[i].h <= ph + ph / 3 && shelves[i].x + pw <= size {
      let x = shelves[i].x
      shelves[i].x += pw
      return (x, shelves[i].y)
    }
    guard nextY + ph <= size, pw <= size else { return nil }
    shelves.append(Shelf(y: nextY, h: ph, x: pw))
    defer { nextY += ph }
    return (0, nextY)
  }
}
