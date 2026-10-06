import AppKit
import CoreText
import OrbeEditorCore

/// 区画の描く材料——区画の絵を、描画スレッドがそのまま置ける形にしたもの（座標は区画の左上を原点にした pt）。main が絵を
/// 問うたとき・外観や倍率が変わったときに作り、並びと同じ書き込みで材料の箱に載せる。字は Core Text で組んだグリフと
/// 送り、色は面の外観と色空間で解いた値、画像は倍率で描いた画素。
///
/// フォントは不変で、Core Text はスレッドをまたいだ利用を保証する（`SurfaceConfig` と同じ）。
struct ZoneMaterial: @unchecked Sendable {
  /// 箱 1 つ（塗り・枠線・影は無ければ透明）。
  struct Box {
    var frame: CGRect
    var radius: Float
    var fill: FrameColor
    var stroke: FrameColor
    var strokeWidth: Float
    var shadow: FrameColor
    var shadowOffset: Float
    var shadowBlur: Float
  }

  /// 組んだ字の連なり 1 つ（1 つのフォントと色）。`xs` は区画の中の x、`baseline` は区画の中の基線の y、`ys` は基線からの
  /// 上向きのずれ（全部 0 なら空）。
  struct Run {
    var font: CTFont
    var glyphs: [CGGlyph]
    var xs: [Float]
    var ys: [Float]
    var baseline: Float
    var ink: InkColor
  }

  struct Image {
    var frame: CGRect
    var pixels: ZonePixels
  }

  /// 入力欄（場の通し番号と、文を打つ矩形）。
  struct Field {
    var serial: Int
    var frame: CGRect
  }

  var boxes: [Box] = []
  var runs: [Run] = []
  var images: [Image] = []
  var fields: [Field] = []
}

/// 倍率で描いた画像の画素（RGBA・乗算済み。描く色空間の値）。`key` は描画スレッドの画像の地図の鍵。
final class ZonePixels: Sendable {
  let key: Int
  let width: Int
  let height: Int
  let bytes: [UInt8]

  init(key: Int, width: Int, height: Int, bytes: [UInt8]) {
    self.key = key
    self.width = width
    self.height = height
    self.bytes = bytes
  }
}

/// 区画の文の選択の地（区画の中の矩形）。選択は区画の文が主の間だけある。
struct ZoneSelectionMaterial: Equatable, Sendable {
  var zone: ObjectIdentifier
  var rects: [CGRect]
  /// 面に焦点がある（焦点のある選択の色）。
  var focused: Bool
}

/// 区画の当たりの表（main）——押せる場所・入力欄・選べる字の行と、まとまりの文。
struct ZoneHits {
  struct Button {
    var id: AnyHashable
    var frame: CGRect
    var cursor: NSCursor
  }

  struct Field {
    var frame: CGRect
    var field: ZoneTextField
  }

  /// 選べる字の行——まとまり・まとまりの中の範囲・基線の左端・組んだ行（点 → 位置）と位置の x。
  struct Line {
    var text: AnyHashable
    var range: NSRange
    var origin: CGPoint
    var ascent: CGFloat
    var descent: CGFloat
    var width: CGFloat
    var line: CTLine
    var carets: CaretMap

    /// 行の当たる帯（区画の中の y）。
    var band: ClosedRange<CGFloat> { (origin.y - ascent)...(origin.y + descent) }

    /// 区画の中の x にいちばん近い、まとまりの文の位置。
    func offset(atX x: CGFloat) -> Int {
      guard x > origin.x else { return range.location }
      guard x < origin.x + width else { return NSMaxRange(range) }
      let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x - origin.x, y: 0))
      return range.location + min(max(0, index), range.length)
    }

    /// まとまりの文の位置の、区画の中の x。
    func x(of offset: Int) -> CGFloat {
      origin.x + carets.x(min(max(0, offset - range.location), range.length))
    }
  }

  var buttons: [Button] = []
  var fields: [Field] = []
  var lines: [Line] = []
  /// 選べる文のまとまりの文。
  var texts: [AnyHashable: TextRope] = [:]

  /// 区画の中の点の下の選べる文（まとまりと、いちばん近い位置）。字の行の帯と、その左右に少しの余白の上だけ。
  func text(at point: CGPoint) -> (AnyHashable, Int)? {
    let slop: CGFloat = 4
    guard
      let line = lines.last(where: {
        $0.band.contains(point.y) && point.x >= $0.origin.x - slop
          && point.x <= $0.origin.x + $0.width + slop
      })
    else { return nil }
    return (line.text, line.offset(atX: point.x))
  }

  /// まとまり `text` の字の行のうち、区画の中の y にいちばん近い行の、x にいちばん近い位置（上の行より上は文の始まり、
  /// 下の行より下は文の終わり）。まとまりの行が無ければ nil。
  func offset(in text: AnyHashable, at point: CGPoint) -> Int? {
    let candidates = lines.filter { $0.text == text }
    guard let first = candidates.first, let last = candidates.last else { return nil }
    if point.y < first.band.lowerBound { return first.range.location }
    if point.y > last.band.upperBound { return NSMaxRange(last.range) }
    let line =
      candidates.first { $0.band.contains(point.y) }
      ?? candidates.min { abs($0.origin.y - point.y) < abs($1.origin.y - point.y) }!
    return line.offset(atX: point.x)
  }
}

/// 区画の絵を材料と当たりの表に写す（main）。画像は倍率と色空間で描いて覚える（同じ画像・大きさなら描き直さない）。
@MainActor
final class ZonePainter {
  private struct ImageKey: Hashable {
    let image: ObjectIdentifier
    let width: Int
    let height: Int
    let appearance: NSAppearance.Name
  }

  /// 描いた画像（鍵の画像を持って、同一性の使い回しを防ぐ）。
  private var images: [ImageKey: (image: NSImage, pixels: ZonePixels)] = [:]
  private var nextImage = 0
  private var imageScale: CGFloat = 0
  private var imageSpace: CGColorSpace?
  /// 組んだ字のフォントを名前と大きさで 1 つの値に揃える（描画スレッドがフォントを値の同一性で引けるように）。
  private var fonts: [String: CTFont] = [:]

  /// 色と画像を解く外観・色空間・倍率。
  struct Look {
    var appearance: NSAppearance
    var space: CGColorSpace
    var scale: CGFloat
  }

  /// 絵 `picture` を外観 `look` で材料に、入力欄を `serial` で場の通し番号に写す。
  func paint(_ picture: ZonePicture, _ look: Look, serial: (ZoneTextField) -> Int)
    -> (ZoneMaterial, ZoneHits)
  {
    if look.scale != imageScale || look.space != imageSpace {
      images.removeAll()
      imageScale = look.scale
      imageSpace = look.space
    }
    let resolve = { (color: NSColor?) -> FrameColor in
      color.map { FrameColor($0, appearance: look.appearance, space: look.space) } ?? .clear
    }
    var material = ZoneMaterial()
    var hits = ZoneHits()
    for text in picture.texts { hits.texts[text.id] = TextRope(text.string) }
    for element in picture.elements {
      switch element {
      case .box(let box):
        material.boxes.append(
          ZoneMaterial.Box(
            frame: box.frame, radius: Float(box.radius), fill: resolve(box.fill),
            stroke: resolve(box.stroke?.color), strokeWidth: Float(box.stroke?.width ?? 0),
            shadow: resolve(box.shadow?.color), shadowOffset: Float(box.shadow?.offset ?? 0),
            shadowBlur: Float(box.shadow?.blur ?? 0)))
      case .text(let line):
        let styles = line.runs.map {
          ZoneTextStyle(length: $0.string.utf16.count, font: $0.font, color: $0.color)
        }
        let shaped = Self.shape(line.runs.map(\.string).joined(), styles: styles)
        material.runs += runs(shaped, styles: styles, origin: line.origin, look)
      case .selectable(let line):
        let whole = hits.texts[line.text] ?? TextRope()
        let lower = min(max(0, line.range.location), whole.length)
        let upper = min(max(lower, NSMaxRange(line.range)), whole.length)
        let string = whole.substring(NSRange(location: lower, length: upper - lower))
        let shaped = Self.shape(string, styles: line.styles)
        material.runs += runs(shaped, styles: line.styles, origin: line.origin, look)
        let font = line.styles.first?.font ?? .systemFont(ofSize: 12)
        hits.lines.append(
          ZoneHits.Line(
            text: line.text, range: NSRange(location: lower, length: upper - lower),
            origin: line.origin, ascent: font.ascender, descent: -font.descender,
            width: CGFloat(CTLineGetTypographicBounds(shaped, nil, nil, nil)), line: shaped,
            carets: CaretMap(
              shaped, width: CGFloat(CTLineGetTypographicBounds(shaped, nil, nil, nil)))
          ))
      case .image(let image):
        if let pixels = pixels(image, look) {
          material.images.append(ZoneMaterial.Image(frame: image.frame, pixels: pixels))
        }
      case .button(let button):
        hits.buttons.append(
          ZoneHits.Button(id: button.id, frame: button.frame, cursor: button.cursor))
      case .field(let field):
        hits.fields.append(ZoneHits.Field(frame: field.frame, field: field.field))
        material.fields.append(ZoneMaterial.Field(serial: serial(field.field), frame: field.frame))
      }
    }
    return (material, hits)
  }

  /// 文字列を見え方の列で 1 行に組む。
  private static func shape(_ string: String, styles: [ZoneTextStyle]) -> CTLine {
    let attributed = NSMutableAttributedString(string: string)
    var offset = 0
    let length = attributed.length
    for style in styles where offset < length {
      let count = min(style.length, length - offset)
      attributed.addAttribute(
        .font, value: style.font, range: NSRange(location: offset, length: count))
      offset += count
    }
    return CTLineCreateWithAttributedString(attributed)
  }

  /// 組んだ行を、字の連なり（フォントと色ごと）に写す。色は位置の見え方から引く。
  private func runs(
    _ line: CTLine, styles: [ZoneTextStyle], origin: CGPoint, _ look: Look
  ) -> [ZoneMaterial.Run] {
    var bounds: [Int] = []
    var offset = 0
    for style in styles {
      offset += style.length
      bounds.append(offset)
    }
    var result: [ZoneMaterial.Run] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      let attributes = CTRunGetAttributes(run) as NSDictionary
      guard let value = attributes[kCTFontAttributeName] else { continue }
      let font = canonical(value as! CTFont)  // swiftlint:disable:this force_cast
      var glyphs = [CGGlyph](repeating: 0, count: count)
      var positions = [CGPoint](repeating: .zero, count: count)
      var indices = [CFIndex](repeating: 0, count: count)
      let all = CFRange(location: 0, length: count)
      CTRunGetGlyphs(run, all, &glyphs)
      CTRunGetPositions(run, all, &positions)
      CTRunGetStringIndices(run, all, &indices)
      let index = indices.first ?? 0
      let style = bounds.firstIndex { index < $0 }.map { styles[$0] } ?? styles.last
      guard let style else { continue }
      let raised = positions.contains { $0.y != 0 }
      result.append(
        ZoneMaterial.Run(
          font: font, glyphs: glyphs, xs: positions.map { Float(origin.x + $0.x) },
          ys: raised ? positions.map { Float($0.y) } : [], baseline: Float(origin.y),
          ink: InkColor(
            style.color, appearance: look.appearance, space: look.space, scale: look.scale)))
    }
    return result
  }

  private func canonical(_ font: CTFont) -> CTFont {
    let key = "\(CTFontCopyPostScriptName(font) as String)@\(CTFontGetSize(font))"
    if let known = fonts[key] { return known }
    fonts[key] = font
    return font
  }

  /// 画像を矩形の大きさ × 倍率の画素に、外観で描く（覚えていれば使い回す）。
  private func pixels(_ image: ZoneImage, _ look: Look) -> ZonePixels? {
    let (appearance, space, scale) = (look.appearance, look.space, look.scale)
    let width = Int((image.frame.width * scale).rounded())
    let height = Int((image.frame.height * scale).rounded())
    guard width > 0, height > 0, width <= 512, height <= 512 else { return nil }
    let key = ImageKey(
      image: ObjectIdentifier(image.image), width: width, height: height,
      appearance: appearance.name)
    if let cached = images[key] { return cached.pixels }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      appearance.performAsCurrentDrawingAppearance {
        image.image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
      }
      NSGraphicsContext.restoreGraphicsState()
      return true
    }
    guard drawn else { return nil }
    nextImage += 1
    let pixels = ZonePixels(key: nextImage, width: width, height: height, bytes: bytes)
    images[key] = (image.image, pixels)
    return pixels
  }
}
