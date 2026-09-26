import CoreGraphics
import CoreText
import os

/// 字の色から、アトラスで使う太らせの段（0…4）を実測で決める。
///
/// Core Graphics は font smoothing で字を太らせる量を字の色から何段かに分けて選ぶが、その分け方は公開されておらず、
/// 明るさの単純な丸めとは一致しない（明るさの近い 2 色が別の段になる）。そこで、その色で Core Text が不透明な地に描いた
/// 字と、アトラスが段ごとに描く字（明るさだけのマスクで、塗りの明るさ＝段 × 0.25 に太らせを選ばせ、sRGB のまま地と
/// 合成したもの）を小さな絵で比べ、最も近い段を使う。段 0 は太らせ無し。色ごとに 1 回だけ測って覚える。
enum DilationProbe {
  private static let cache = OSAllocatedUnfairLock<[UInt32: Int]>(initialState: [:])
  private static let width = 160
  private static let height = 36
  private static let sample = "mwgWa@"

  static func level(red: Float, green: Float, blue: Float) -> Int {
    let key = [red, green, blue].enumerated().reduce(UInt32(0)) {
      $0 | UInt32(($1.element * 255).rounded()) << (8 * UInt32($1.offset))
    }
    if let level = cache.withLock({ $0[key] }) { return level }
    let color = [red, green, blue].map { Double($0) }
    // 地は字と反対の明るさにする（差が最も出る）。
    let luminance = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]
    let ground = luminance > 0.5 ? 0.0 : 1.0
    let reference = drawReference(color, ground: ground)
    let level = (0...4).min {
      error(reference, mask(level: $0), color, ground)
        < error(reference, mask(level: $1), color, ground)
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

  /// Core Text がその色で不透明な地に描いた字（BGRA）。
  private static func drawReference(_ color: [Double], ground: Double) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return }
      context.setFillColor(CGColor(srgbRed: ground, green: ground, blue: ground, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.setAllowsFontSmoothing(true)
      context.setShouldSmoothFonts(true)
      context.scaleBy(x: 2, y: 2)
      context.textPosition = CGPoint(x: 3, y: 5)
      CTLineDraw(
        line(CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: 1)), context)
    }
    return bytes
  }

  /// アトラスが段 `level` で描く字のマスク。
  private static func mask(level: Int) -> [UInt8] {
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
      context.scaleBy(x: 2, y: 2)
      context.textPosition = CGPoint(x: 3, y: 5)
      CTLineDraw(line(CGColor(gray: CGFloat(level) * 0.25, alpha: 1)), context)
    }
    return bytes
  }

  /// マスクを地と sRGB のまま合成したものと基準の差の合計。
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
