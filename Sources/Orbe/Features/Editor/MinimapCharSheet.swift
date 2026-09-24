import AppKit
import OrbeEditorCore

/// ミニマップの字形——ASCII 32…126 と U+FFFD を、1 字 `scale` × `2·scale` デバイス px の明度（0…255）に縮めたもの。
/// VS Code `MinimapCharRendererFactory` の「フォントを描いて縮小する」手順を、Orbe の本文フォントで行う: 太字 16px を
/// 10 × 16 のセルに縦中央で白く描き、各デバイス px に掛かる元の画素を重み付きで平均し、全字で最も明るい値を 255 に
/// 揃える（VS Code は scale 1・2 では焼き込み済みの表を使うが、それは VS Code のフォントから焼いたもので形が違う）。
struct MinimapCharSheet {
  /// 1 字の幅と高さ（デバイス px）。
  let scale: Int
  /// 字ごとの明度（`glyph * scale * 2·scale` から行優先）。
  private let data: [UInt8]

  private static let sampledWidth = 10
  private static let sampledHeight = 16

  init(scale: Int, font: NSFont) {
    self.scale = scale
    data = Self.downsample(Self.sample(font: font), scale: scale)
  }

  var glyphWidth: Int { scale }
  var glyphHeight: Int { scale * 2 }

  /// 字形 `glyph` の (x, y) の明度。
  func value(_ glyph: Int, x: Int, y: Int) -> UInt8 {
    data[(glyph * glyphHeight + y) * glyphWidth + x]
  }

  /// 字を 10 × 16 のセルに並べて描いた覆いの濃さ（0…255）。
  private static func sample(font: NSFont) -> [UInt8] {
    let width = sampledWidth * MinimapLine.glyphCount
    let height = sampledHeight
    var pixels = [UInt8](repeating: 0, count: width * height)
    let bold = NSFontManager.shared.convert(
      NSFont(descriptor: font.fontDescriptor, size: CGFloat(sampledHeight)) ?? font,
      toHaveTrait: .boldFontMask)
    pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
      else { return }
      // canvas の textBaseline = middle: em の中央（ascender と descender の中点）をセルの縦中央に置く。
      let baseline = CGFloat(height) / 2 - (bold.ascender + bold.descender) / 2
      let graphics = NSGraphicsContext(cgContext: context, flipped: false)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphics
      let attributes: [NSAttributedString.Key: Any] = [
        .font: bold, .foregroundColor: NSColor.white,
      ]
      for (index, code) in Self.codes.enumerated() {
        let string = String(UnicodeScalar(code).map(Character.init) ?? " ")
        NSAttributedString(string: string, attributes: attributes).draw(
          at: NSPoint(x: CGFloat(index * sampledWidth), y: baseline + bold.descender))
      }
      NSGraphicsContext.restoreGraphicsState()
    }
    return pixels
  }

  /// 字形の並び（VS Code `allCharCodes`）。
  private static let codes: [UInt32] = Array(32...126) + [0xFFFD]

  /// VS Code `_downsampleChar` / `_downsample`。行は上から（CG の alpha-only は上の行から並ぶ）。
  private static func downsample(_ source: [UInt8], scale: Int) -> [UInt8] {
    let width = scale
    let height = scale * 2
    let rowWidth = sampledWidth * MinimapLine.glyphCount
    var values = [Double](repeating: 0, count: MinimapLine.glyphCount * width * height)
    var brightest = 0.0
    var target = 0
    for glyph in 0..<MinimapLine.glyphCount {
      let offset = glyph * sampledWidth
      for y in 0..<height {
        let y1 = Double(y) / Double(height) * Double(sampledHeight)
        let y2 = Double(y + 1) / Double(height) * Double(sampledHeight)
        for x in 0..<width {
          let x1 = Double(x) / Double(width) * Double(sampledWidth)
          let x2 = Double(x + 1) / Double(width) * Double(sampledWidth)
          var value = 0.0
          var samples = 0.0
          var sy = y1
          while sy < y2 {
            let yBalance = 1 - (sy - floor(sy))
            var sx = x1
            while sx < x2 {
              let weight = (1 - (sx - floor(sx))) * yBalance
              samples += weight
              value += Double(source[Int(floor(sy)) * rowWidth + offset + Int(floor(sx))]) * weight
              sx += 1
            }
            sy += 1
          }
          let final = value / samples
          brightest = max(brightest, final)
          values[target] = floor(min(255, final))
          target += 1
        }
      }
    }
    let adjust = brightest > 0 ? 255 / brightest : 1
    return values.map { UInt8(min(255, ($0 * adjust).rounded(.toNearestOrEven))) }
  }
}
