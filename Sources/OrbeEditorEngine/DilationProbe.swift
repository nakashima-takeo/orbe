import CoreGraphics
import CoreText
import os

/// 字の色から、アトラスで使う太らせの段（0…5）を実測で決める。
///
/// Core Graphics は font smoothing で字を太らせる量を字の色から何段かに分けて選ぶが、その分け方は公開されておらず、
/// 明るさの単純な丸めとは一致しない（明るさの近い 2 色が別の段になる）。そこで、その色で Core Text が不透明な地に描いた
/// 字と、アトラスが段ごとに描く字（明るさだけのマスクで、塗りの明るさに太らせを選ばせ、その色空間の値のまま地と合成した
/// もの）を小さな絵で比べ、最も近い段を使う。基準は面が描く色空間で描く（Core Text が選ぶ段は、塗りをその色空間で表した
/// 値で決まる）。段 0 は太らせ無し。太らせの量は倍率でも変わるので（1x は 2x より段が 1 つ多い）、色・色空間・倍率の組
/// ごとに 1 回だけ測って覚える。
enum DilationProbe {
  /// 段 1…5 のマスクを描く塗りの明るさ。Core Graphics が塗りの明るさで選ぶ太らせの区切り（おおよそ 0.32・0.58・
  /// 0.78・0.94）の間の値で、段ごとに違う太らせを選ばせる。
  private static let fills: [CGFloat] = [0.16, 0.45, 0.68, 0.86, 0.97]

  /// 段 `level` のマスクを描く塗りの明るさ（段 0 は太らせないので nil）。
  static func fill(level: Int) -> CGFloat? { level > 0 ? fills[level - 1] : nil }

  private struct Key: Hashable {
    var rgb: UInt32
    var scale: CGFloat
    var space: CGColorSpace
  }

  private static let cache = OSAllocatedUnfairLock<[Key: Int]>(initialState: [:])
  private static let width = 160
  private static let height = 36
  private static let sample = "mwgWa@"

  /// 色空間 `space` の値 `red`・`green`・`blue` の字を倍率 `scale` で描くときの段。
  static func level(
    red: Float, green: Float, blue: Float, space: CGColorSpace, scale: CGFloat
  ) -> Int {
    let rgb = [red, green, blue].enumerated().reduce(UInt32(0)) {
      $0 | UInt32(($1.element * 255).rounded()) << (8 * UInt32($1.offset))
    }
    let key = Key(rgb: rgb, scale: scale, space: space)
    if let level = cache.withLock({ $0[key] }) { return level }
    let color = [red, green, blue].map { Double($0) }
    // 地は字と反対の明るさにする（差が最も出る）。
    let luminance = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]
    let ground = luminance > 0.5 ? 0.0 : 1.0
    let reference = drawReference(color, ground: ground, space: space, scale: scale)
    let level = (0...fills.count).min {
      error(reference, mask(level: $0, scale: scale), color, ground)
        < error(reference, mask(level: $1, scale: scale), color, ground)
    }!
    cache.withLock { $0[key] = level }
    return level
  }

  private static var font: CTFont { CTFontCreateUIFontForLanguage(.userFixedPitch, 12, nil)! }

  private static func line(_ color: CGColor) -> CTLine {
    let attributes =
      [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
    return CTLineCreateWithAttributedString(
      CFAttributedStringCreate(nil, sample as CFString, attributes)!)
  }

  /// Core Text がその色で不透明な地に描いた字（色空間 `space` の BGRA）。
  private static func drawReference(
    _ color: [Double], ground: Double, space: CGColorSpace, scale: CGFloat
  ) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
        let groundColor = CGColor(colorSpace: space, components: [ground, ground, ground, 1]),
        let ink = CGColor(colorSpace: space, components: color.map { CGFloat($0) } + [1])
      else { return }
      context.setFillColor(groundColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.setAllowsFontSmoothing(true)
      context.setShouldSmoothFonts(true)
      context.scaleBy(x: scale, y: scale)
      context.textPosition = CGPoint(x: 3, y: 5)
      CTLineDraw(line(ink), context)
    }
    return bytes
  }

  /// アトラスが段 `level` で描く字のマスク。
  private static func mask(level: Int, scale: CGFloat) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height)
    bytes.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
      else { return }
      context.setAllowsFontSmoothing(level > 0)
      context.setShouldSmoothFonts(level > 0)
      context.scaleBy(x: scale, y: scale)
      context.textPosition = CGPoint(x: 3, y: 5)
      CTLineDraw(line(CGColor(gray: fill(level: level) ?? 0, alpha: 1)), context)
    }
    return bytes
  }

  /// マスクを地とその色空間の値のまま合成したものと基準の差の合計。
  private static func error(
    _ reference: [UInt8], _ mask: [UInt8], _ color: [Double], _ ground: Double
  )
    -> Int
  {
    var total = 0
    for i in mask.indices {
      let a = Double(mask[i]) / 255
      for (k, channel) in [2, 1, 0].enumerated() {
        let value = Int(((color[channel] * a + ground * (1 - a)) * 255).rounded())
        total += abs(value - Int(reference[i * 4 + k]))
      }
    }
    return total
  }
}
