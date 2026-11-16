import AppKit
import CoreText
import OrbeEditorCore

/// 絵の差し込みを描く材料——載せる側が描いた絵を、描画スレッドがそのまま置ける形にしたもの（座標は絵の差し込みの左上を
/// 原点にした pt）。main が絵を問うたとき・外観や倍率が変わったときに作り、並びと同じ書き込みで材料の箱に載せる。字は
/// Core Text で組んだグリフと送り、色は面の外観と色空間で解いた値、画像は倍率で描いた画素。
///
/// フォントは不変で、Core Text はスレッドをまたいだ利用を保証する（`SurfaceConfig` と同じ）。
struct ZoneMaterial: @unchecked Sendable {
  /// 箱 1 つ（塗り・枠線・影は無ければ透明）。
  struct Box {
    var frame: CGRect
    /// 角ごとの半径（左上・右上・右下・左下）。
    var radius: SIMD4<Float>
    var fill: FrameColor
    var stroke: FrameColor
    var strokeWidth: Float
    var shadow: FrameColor
    var shadowOffset: Float
    var shadowBlur: Float
  }

  /// 組んだ字の連なり 1 つ（1 つのフォントと色）。`xs` は絵の差し込みの中の x、`baseline` は絵の差し込みの中の基線の
  /// y、`ys` は基線からの上向きのずれ（全部 0 なら空）。
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

/// 絵の差し込みの文の選択の地（絵の差し込みの中の矩形）。選択は絵の差し込みの文が主の間だけある。
struct ZoneSelectionMaterial: Equatable, Sendable {
  var zone: ObjectIdentifier
  var rects: [CGRect]
  /// 面に焦点がある（焦点のある選択の色）。
  var focused: Bool
}

/// 絵の差し込みの当たりの表（main）——押せる場所・入力欄・選べる字の行と、まとまりの文。
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

  /// 選べる字の行——まとまり・基線の左端・字の帯と、組んだ行（元の文の位置 ↔ x）。
  struct Line {
    var text: AnyHashable
    var origin: CGPoint
    var ascent: CGFloat
    var descent: CGFloat
    var layout: ZoneTextLayout.Line

    /// まとまりの中の範囲。
    var range: NSRange { layout.range }

    /// 行の当たる帯（絵の差し込みの中の y）。
    var band: ClosedRange<CGFloat> { (origin.y - ascent)...(origin.y + descent) }

    /// 絵の差し込みの中の x にいちばん近い、まとまりの文の位置。
    func offset(atX x: CGFloat) -> Int { layout.offset(atX: x - origin.x) }

    /// まとまりの文の位置の、絵の差し込みの中の x。
    func x(of offset: Int) -> CGFloat { origin.x + layout.x(of: offset) }
  }

  var buttons: [Button] = []
  var fields: [Field] = []
  var lines: [Line] = []
  /// 選べる文のまとまりの文。
  var texts: [AnyHashable: TextRope] = [:]

  /// 絵の差し込みの中の点の下の選べる文（まとまりと、いちばん近い位置）。字の行の帯と、その左右に少しの余白の上だけ。
  func text(at point: CGPoint) -> (AnyHashable, Int)? {
    let slop: CGFloat = 4
    guard
      let line = lines.last(where: {
        $0.band.contains(point.y) && point.x >= $0.origin.x - slop
          && point.x <= $0.origin.x + $0.layout.width + slop
      })
    else { return nil }
    return (line.text, line.offset(atX: point.x))
  }

  /// まとまり `text` の字の行のうち、絵の差し込みの中の y にいちばん近い行の、x にいちばん近い位置（上の行より上は文の
  /// 始まり、下の行より下は文の終わり）。まとまりの行が無ければ nil。
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

/// 載せる側が描いた絵を材料と当たりの表に写す（main）。画像は倍率と色空間で描いて覚える（同じ画像・大きさなら
/// 描き直さない）。
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
    for element in picture.elements {
      switch element {
      case .box(let box):
        material.boxes.append(
          ZoneMaterial.Box(
            frame: box.frame,
            radius: SIMD4(
              Float(box.radius.topLeft), Float(box.radius.topRight),
              Float(box.radius.bottomRight), Float(box.radius.bottomLeft)),
            fill: resolve(box.fill),
            stroke: resolve(box.stroke?.color), strokeWidth: Float(box.stroke?.width ?? 0),
            shadow: resolve(box.shadow?.color), shadowOffset: Float(box.shadow?.offset ?? 0),
            shadowBlur: Float(box.shadow?.blur ?? 0)))
      case .text(let line):
        material.runs += runs(
          ZoneTextLayout.line(line.runs), colors: line.runs.map(\.color), origin: line.origin,
          look)
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
    for text in picture.texts { paint(text, look, into: &material, hits: &hits) }
    precondition(hits.texts.count == picture.texts.count, "選べる文のまとまりの id は絵の差し込みの中で一意")
    precondition(
      Set(hits.buttons.map(\.id)).count == hits.buttons.count, "押せる場所の id は絵の差し込みの中で一意")
    precondition(
      Set(hits.fields.map(\.field.id)).count == hits.fields.count, "入力欄の id は絵の差し込みの中で一意")
    return (material, hits)
  }

  /// 選べる文のまとまり `text` の文を当たりの表に、その行を材料と当たりの表の行に写す。
  private func paint(
    _ text: ZoneText, _ look: Look, into material: inout ZoneMaterial, hits: inout ZoneHits
  ) {
    hits.texts[text.id] = TextRope(text.string)
    let colors = text.styles.map(\.color)
    for (line, layout) in zip(text.lines, ZoneTextLayout.lines(of: text)) {
      material.runs += runs(layout, colors: colors, origin: line.origin, look)
      let font = Self.font(at: layout.range.location, text.styles) ?? .systemFont(ofSize: 12)
      hits.lines.append(
        ZoneHits.Line(
          text: text.id, origin: line.origin, ascent: font.ascender, descent: -font.descender,
          layout: layout))
    }
  }

  /// 位置 `offset` の字の見え方の字体（位置が見え方の外なら最後の見え方の字体）。
  private static func font(at offset: Int, _ styles: [ZoneTextStyle]) -> NSFont? {
    var end = 0
    for style in styles {
      end += style.length
      if offset < end { return style.font }
    }
    return styles.last?.font
  }

  /// 組んだ行のグリフの連なりを、字の連なり（フォントと色ごと）に写す。色は連なりの見え方の色 `colors` から引く。
  private func runs(
    _ line: ZoneTextLayout.Line, colors: [NSColor], origin: CGPoint, _ look: Look
  ) -> [ZoneMaterial.Run] {
    line.runs.compactMap { run in
      guard colors.indices.contains(run.style) else { return nil }
      let raised = run.positions.contains { $0.y != 0 }
      return ZoneMaterial.Run(
        font: canonical(run.font), glyphs: run.glyphs,
        xs: run.positions.map { Float(origin.x + $0.x) },
        ys: raised ? run.positions.map { Float($0.y) } : [], baseline: Float(origin.y),
        ink: InkColor(
          colors[run.style], appearance: look.appearance, space: look.space, scale: look.scale))
    }
  }

  private func canonical(_ font: CTFont) -> CTFont {
    let key = "\(CTFontCopyPostScriptName(font) as String)@\(CTFontGetSize(font))"
    if let known = fonts[key] { return known }
    fonts[key] = font
    return font
  }

  /// 鍵 `keys` の画素の覚えだけを残す（どの絵の差し込みの材料も指さなくなった画像と画素を手放す）。
  func keep(images keys: Set<Int>) {
    images = images.filter { keys.contains($0.value.pixels.key) }
  }

  /// 画像を矩形の大きさ × 倍率の画素に、外観で描く（覚えていれば使い回す。辺が地図に置ける上限を超えれば描かない）。
  private func pixels(_ image: ZoneImage, _ look: Look) -> ZonePixels? {
    let (appearance, space, scale) = (look.appearance, look.space, look.scale)
    let width = Int((image.frame.width * scale).rounded())
    let height = Int((image.frame.height * scale).rounded())
    guard width > 0, height > 0, width <= ImageAtlas.maximumSide, height <= ImageAtlas.maximumSide
    else { return nil }
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
