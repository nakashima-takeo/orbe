import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 字の見た目——新しい面の本文と行番号が、同じ行を Core Text で描いたものと、字のある画素で最大 1 段（8bit）の差に
/// 収まる。ASCII・日本語・絵文字・代替フォントの字で見る。比べるのは不透明な地に描いた絵（透明な面は窓の合成で地と
/// 混ざるので、地を塗った画面外の絵で比べる）。壊れると字が細る・太る・にじむ・位置が半画素ずれる。
@MainActor
final class GlyphPixelTests: EngineTestCase {
  private static let background = MTLClearColor(
    red: 30.0 / 255, green: 30.0 / 255, blue: 30.0 / 255, alpha: 1)

  private static let sample = """
    // 日本語のコメントと絵文字 😀👍🏽 fin
    func render(into buffer: inout [String]) -> Int {
      let greek = "Ωμέγα ∑ √ ≈ ⌘ 한국어 ภาษาไทย Q̃ á́ بِ سْ"
      return buffer.count + 42
    }

    """

  func testGlyphsMatchCoreTextWithinOneLevel() throws {
    for smoothing in [true, false] {
      let options = MetalTextSurfaceOptions(
        elasticScroll: true, fontSmoothing: smoothing, omittedLabel: { "\($0)" })
      let opened = try open(Self.sample, size: CGSize(width: 600, height: 140), options: options)
      let id = opened.surface.id
      let metal = try XCTUnwrap(
        RenderThread.shared.performAndWait {
          Transfer(value: $0.snapshot(id, background: Self.background))
        }.value)
      let reference = try coreText(opened, smoothing: smoothing)
      writePNG(metal, previewURL("glyphs-metal-\(smoothing).png"))
      writePNG(reference, previewURL("glyphs-coretext-\(smoothing).png"))
      let difference = Self.compare(metal, reference)
      print("GLYPHS smoothing=\(smoothing) ink=\(difference.ink) worst=\(difference.worst)")
      XCTAssertGreaterThan(difference.ink, 1_000, "前提: 字が描かれている")
      XCTAssertLessThanOrEqual(
        difference.worst, 1, "太らせ \(smoothing): 字のある画素の差は最大 1 段")
    }
  }

  /// 基準を描く座標系（px、原点は左下）と見え方。
  private struct Reference {
    let context: CGContext
    let config: SurfaceConfig
    let palette: FramePalette
    let scale: Double
    let height: Double
    let top: Double
    let column: Double

    func color(_ color: FrameColor) -> CGColor {
      let c = (0..<4).map {
        CGFloat(($0 == 3 ? 255 : (color.packed >> (8 * UInt32($0))) & 0xFF)) / 255
      }
      return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
    }

    /// `clip` の中に、左上からの位置 `x`・基線 `baseline`（px）で 1 行を描く。
    func draw(_ line: NSAttributedString, x: Double, baseline: Double, clip: CGRect) {
      context.saveGState()
      context.clip(to: clip)
      context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
      context.textPosition = CGPoint(x: x / scale, y: (height - baseline) / scale)
      CTLineDraw(CTLineCreateWithAttributedString(line), context)
      context.restoreGState()
    }
  }

  /// 同じ行を Core Text で不透明な地に描いた基準。位置の規則は新しい面と同じ（行の上端 + 基線、行番号は右寄せで縦の中央）。
  private func coreText(_ opened: Opened, smoothing: Bool) throws -> CGImage {
    let config = opened.surface.config
    let material = opened.surface.material.read()
    let content = try XCTUnwrap(material.content)
    let s = Double(material.scale)
    let (width, height) = Renderer.pixelSize(material)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue))
    let bg = Self.background
    context.setFillColor(CGColor(srgbRed: bg.red, green: bg.green, blue: bg.blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setAllowsFontSmoothing(true)
    context.setShouldSmoothFonts(smoothing)
    context.setAllowsFontSubpixelPositioning(true)
    context.setShouldSubpixelPositionFonts(true)
    context.setAllowsFontSubpixelQuantization(true)
    context.setShouldSubpixelQuantizeFonts(true)
    let r = Reference(
      context: context, config: config, palette: try XCTUnwrap(material.palette), scale: s,
      height: Double(height), top: (Double(config.topInset) * s).rounded(),
      column: (Double(config.columnWidth(lineCount: content.text.lineCount)) * s).rounded())
    let lineHeight = Double(config.lineHeight) * s
    for row in 0..<content.text.lineCount {
      let rowTop = r.top + (Double(row) * lineHeight).rounded()
      guard rowTop < Double(height) else { break }
      r.draw(
        line(row, content, r), x: r.column,
        baseline: rowTop + (Double(config.baseline) * s).rounded(),
        clip: CGRect(x: r.column, y: 0, width: Double(width) - r.column, height: r.height - r.top))
      let number = NSAttributedString(
        string: "\(row + 1)",
        attributes: [
          .init(kCTFontAttributeName as String): config.gutterFont,
          .init(kCTForegroundColorAttributeName as String): r.color(r.palette.gutterText),
        ])
      let numberWidth = Double(config.numberWidth(row + 1).rounded(.up)) * s
      let trailing = Double(config.gutterTrailingInset + config.marks.gutterWidth) * s
      r.draw(
        number, x: r.column - trailing - numberWidth,
        baseline: rowTop + lineHeight / 2
          + Double(config.gutterAscent - config.gutterDescent) / 2 * s,
        clip: CGRect(x: 0, y: 0, width: r.column, height: r.height - r.top))
    }
    return try XCTUnwrap(context.makeImage())
  }

  /// 行 `row` を役割の色で塗った文字列。
  private func line(_ row: Int, _ content: SurfaceContent, _ r: Reference) -> NSAttributedString {
    let (source, start) = LineShaper.source(row: row, in: content.text)
    let attributed = NSMutableAttributedString(
      string: content.text.substring(NSRange(location: start, length: source.length)),
      attributes: [
        .init(kCTFontAttributeName as String): r.config.font,
        .init(kCTForegroundColorAttributeName as String): r.color(r.palette.text),
      ])
    for span in content.roles.roles(in: NSRange(location: start, length: source.length)) {
      guard let color = r.palette.roles[span.role] else { continue }
      attributed.addAttribute(
        .init(kCTForegroundColorAttributeName as String), value: r.color(color),
        range: NSRange(location: span.range.location - start, length: span.range.length))
    }
    return attributed
  }

  /// 字のある画素（どちらかが地と違う画素）での最大の差（RGB の段）と、字のある画素の数。
  static func compare(_ a: CGImage, _ b: CGImage) -> (worst: Int, ink: Int) {
    let pa = pixels(a)
    let pb = pixels(b)
    let bg = UInt8((background.blue * 255).rounded())
    var worst = 0
    var ink = 0
    for i in stride(from: 0, to: min(pa.count, pb.count), by: 4) {
      let isInk = (0..<3).contains { pa[i + $0] != bg || pb[i + $0] != bg }
      guard isInk else { continue }
      ink += 1
      let d = (0..<3).map { abs(Int(pa[i + $0]) - Int(pb[i + $0])) }.max()!
      worst = max(worst, d)
    }
    return (worst, ink)
  }

  static func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
      data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
  }
}
