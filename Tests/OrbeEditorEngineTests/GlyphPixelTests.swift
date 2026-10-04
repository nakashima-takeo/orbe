import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 字の見た目——面の本文と行番号が、同じ行を Core Text で同じ色空間に（font smoothing つきで）描いたものと、字のある画素で
/// 最大 1 段（8bit）の差に収まる。ASCII・日本語・絵文字・代替フォント・結合文字の記号の字を、1x と 2x で見る。比べるのは
/// 不透明な地に描いた絵（透明な面は窓の合成で地と混ざるので、地を塗った画面外の絵で比べる）。字どうしのインクが重なる形
/// （アラビア語のつながり・字に接する記号）は、重なる画素が数段ずれうるので見本に含めない。画面の色空間（Display P3）でも
/// 描き、そこへ Core Text が直に描いたものと揃うことも見る。壊れると字が細る・太る・にじむ・位置が半画素ずれる・記号が
/// 基線に落ちる・画面で字の縁と絵文字の色が AppKit の描く字とずれる。
@MainActor
final class GlyphPixelTests: EngineTestCase {
  private static let background = MTLClearColor(
    red: 30.0 / 255, green: 30.0 / 255, blue: 30.0 / 255, alpha: 1)

  private static let sample = """
    // 日本語のコメントと絵文字 😀👍🏽 fin
    func render(into buffer: inout [String]) -> Int {
      let greek = "Ωμέγα ∑ √ ≈ ⌘ 한국어 ภาษาไทย á́ بِ سْ"
      return buffer.count + 42
    }

    """

  /// 字だけを見る見え方（装備は透明に描く——基準の Core Text の行は装備を持たない）。
  private static var glyphsOnly: TextSurfaceStyle {
    var style = EngineTestCase.style()
    style.decorations.whitespaceColor = .clear
    return style
  }

  func testGlyphsMatchCoreTextWithinOneLevel() throws {
    try compareWithCoreText(in: CGColorSpace.sRGB, tolerance: 1)
  }

  /// 窓の色空間（ここでは Display P3）で描いた字と絵文字が、Core Text がその色空間へ直に描いたものと揃う。太らせの縁は
  /// 5 段のマスクで近似するので、色の値によっては縁の 1 画素が 2 段ずれる（sRGB の見本の色では 1 段に収まる）。別の色空間で
  /// 描いてから色を合わせると、本文で 3〜5 段、色付きの絵文字で十数段ずれる。
  func testGlyphsInTheWindowsColorSpaceMatchCoreTextDrawnThere() throws {
    try compareWithCoreText(in: CGColorSpace.displayP3, tolerance: 2)
  }

  private func compareWithCoreText(in spaceName: CFString, tolerance: Int) throws {
    let space = try XCTUnwrap(CGColorSpace(name: spaceName))
    for scale: CGFloat in [1, 2] {
      let size = CGSize(width: 600, height: 140)
      let opened = try open(Self.sample, size: size, scale: scale, style: Self.glyphsOnly)
      opened.surface.viewStateDidChange(size: size, scale: scale, space: space, visible: false)
      let id = opened.surface.id
      opened.surface.flush()
      let metal = try XCTUnwrap(
        RenderThread.shared.performAndWait {
          Transfer(value: $0.snapshot(id, background: Self.background))
        }.value)
      let reference = try coreText(opened)
      let name = "\(spaceName)-\(Int(scale))x"
      writePNG(metal, previewURL("glyphs-metal-\(name).png"))
      writePNG(reference, previewURL("glyphs-coretext-\(name).png"))
      let right = Int((opened.surface.surfaceLayout.text.maxX * scale).rounded())
      let difference = Self.compare(metal, reference, right: right)
      print("GLYPHS \(name) ink=\(difference.ink) worst=\(difference.worst)")
      XCTAssertGreaterThan(difference.ink, 500, "前提: 字が描かれている")
      XCTAssertLessThanOrEqual(
        difference.worst, tolerance, "\(name): 字のある画素の差は最大 \(tolerance) 段")
    }
  }

  /// 基準を描く座標系（px、原点は左下）と見え方。
  private struct Reference {
    let context: CGContext
    let space: CGColorSpace
    let config: SurfaceConfig
    let palette: FramePalette
    let scale: Double
    let height: Double
    let top: Double
    let column: Double
    /// 本文の区画の右端（面は俯瞰の左で本文を切る）。
    let textRight: Double

    func color(_ color: FrameColor) -> CGColor {
      let c = (0..<4).map {
        CGFloat(($0 == 3 ? 255 : (color.packed >> (8 * UInt32($0))) & 0xFF)) / 255
      }
      return CGColor(colorSpace: space, components: c)!
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

  /// 同じ行を Core Text で面と同じ色空間の不透明な地に描いた基準。位置の規則は面と同じ（行の上端 + 基線、行番号は
  /// 右寄せで縦の中央）。
  private func coreText(_ opened: Opened) throws -> CGImage {
    let config = opened.surface.config
    let material = opened.surface.drawn
    let content = try XCTUnwrap(material.content)
    let s = Double(material.scale)
    let (width, height) = Renderer.pixelSize(material)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: material.space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue))
    let bg = Self.background
    context.setFillColor(
      try XCTUnwrap(
        CGColor(colorSpace: material.space, components: [bg.red, bg.green, bg.blue, 1])))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setAllowsFontSmoothing(true)
    context.setShouldSmoothFonts(true)
    context.setAllowsFontSubpixelPositioning(true)
    context.setShouldSubpixelPositionFonts(true)
    context.setAllowsFontSubpixelQuantization(true)
    context.setShouldSubpixelQuantizeFonts(true)
    let r = Reference(
      context: context, space: material.space, config: config,
      palette: try XCTUnwrap(material.palette), scale: s,
      height: Double(height), top: (Double(config.topInset) * s).rounded(),
      column: (Double(config.columnWidth(lineCount: content.text.lineCount)) * s).rounded(),
      textRight: (Double(opened.surface.surfaceLayout.text.maxX) * s).rounded())
    let lineHeight = Double(config.lineHeight) * s
    for row in 0..<content.text.lineCount {
      let rowTop = r.top + (Double(row) * lineHeight).rounded()
      guard rowTop < Double(height) else { break }
      r.draw(
        line(row, content, r), x: r.column,
        baseline: rowTop + (Double(config.baseline) * s).rounded(),
        clip: CGRect(x: r.column, y: 0, width: r.textRight - r.column, height: r.height - r.top))
      let number = NSAttributedString(
        string: "\(row + 1)",
        attributes: [
          .init(kCTFontAttributeName as String): config.gutterFont,
          .init(kCTForegroundColorAttributeName as String): r.color(r.palette.gutterText.color),
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
        .init(kCTForegroundColorAttributeName as String): r.color(r.palette.text.color),
      ])
    for span in content.roles.roles(in: NSRange(location: start, length: source.length)) {
      let ink = r.palette.ink(span.role)
      attributed.addAttribute(
        .init(kCTForegroundColorAttributeName as String), value: r.color(ink.color),
        range: NSRange(location: span.range.location - start, length: span.range.length))
    }
    return attributed
  }

  /// 字のある画素（どちらかが地と違う画素）での最大の差（RGB の段）と、字のある画素の数。比べるのは左から `right`
  /// px まで（その右は俯瞰）。
  static func compare(_ a: CGImage, _ b: CGImage, right: Int) -> (worst: Int, ink: Int) {
    let pa = pixels(a)
    let pb = pixels(b)
    let bg = UInt8((background.blue * 255).rounded())
    var worst = 0
    var ink = 0
    for i in stride(from: 0, to: min(pa.count, pb.count), by: 4) where (i / 4) % a.width < right {
      let isInk = (0..<3).contains { pa[i + $0] != bg || pb[i + $0] != bg }
      guard isInk else { continue }
      ink += 1
      let d = (0..<3).map { abs(Int(pa[i + $0]) - Int(pb[i + $0])) }.max()!
      worst = max(worst, d)
    }
    return (worst, ink)
  }

  /// 絵の画素（絵の色空間の値のまま）。
  static func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
      data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
  }
}
