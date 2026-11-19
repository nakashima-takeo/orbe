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
    var layout: ZoneTextLayout.TypesetLine

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
  /// 選べる文のまとまりを組んだもの（次の描き直しで、文と見え方と行の範囲が同じなら使い回す）。
  var typeset: [AnyHashable: ZoneTextTypeset] = [:]
  /// 字の行を組んだもの（次の描き直しで、字と字体が同じ字の行は組み直さずに使い回す）。
  var labels: [ZoneLabelKey: [ZoneTextTypeset.Run]] = [:]

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

  /// 絵 `picture` を外観 `look` で材料に、入力欄を `serial` で場の通し番号に写す。選べる文のまとまりは、前の当たりの表
  /// `previous` に、文と見え方と行の範囲が同じものを組んだものがあれば、組み直さずに使い回す。字の行も、字と字体が同じ
  /// ものを組んだものがあれば使い回す（色は鍵に入れず、描くたびに今の外観で解く）。
  func paint(
    _ picture: ZonePicture, _ look: Look, reusing previous: ZoneHits = ZoneHits(),
    serial: (ZoneTextField) -> Int
  ) -> (ZoneMaterial, ZoneHits) {
    if look.scale != imageScale || look.space != imageSpace {
      images.removeAll()
      imageScale = look.scale
      imageSpace = look.space
    }
    let resolve = { (color: NSColor?) -> FrameColor in
      color.map { FrameColor($0, appearance: look.appearance, space: look.space) } ?? .clear
    }
    var inks = Inks(look: look)
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
        let key = ZoneLabelKey(line.runs)
        let typeset =
          hits.labels[key] ?? previous.labels[key]
          ?? prepared(ZoneTextLayout.line(line.runs).runs)
        hits.labels[key] = typeset
        material.runs += runs(
          typeset, colors: line.runs.map(\.color), origin: line.origin, inks: &inks)
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
    for text in picture.texts {
      paint(
        text, reusing: previous.typeset[text.id], inks: &inks, into: &material, hits: &hits)
    }
    precondition(hits.texts.count == picture.texts.count, "選べる文のまとまりの id は絵の差し込みの中で一意")
    precondition(
      Set(hits.buttons.map(\.id)).count == hits.buttons.count, "押せる場所の id は絵の差し込みの中で一意")
    precondition(
      Set(hits.fields.map(\.field.id)).count == hits.fields.count, "入力欄の id は絵の差し込みの中で一意")
    return (material, hits)
  }

  /// 選べる文のまとまり `text` の文を当たりの表に、その行を材料と当たりの表の行に写す。組んだもの `cached` が同じ文・
  /// 見え方・行の範囲のものなら、組み直さない。
  private func paint(
    _ text: ZoneText, reusing cached: ZoneTextTypeset?, inks: inout Inks,
    into material: inout ZoneMaterial, hits: inout ZoneHits
  ) {
    let typeset =
      cached.flatMap { $0.matches(text) ? $0 : nil }
      ?? ZoneTextTypeset(text, prepare: prepared)
    hits.typeset[text.id] = typeset
    hits.texts[text.id] = typeset.rope
    let colors = text.content.styles.map(\.color)
    for (index, (line, layout)) in zip(text.lines, typeset.lines).enumerated() {
      material.runs += runs(
        typeset.runs[index], colors: colors, origin: line.origin, inks: &inks)
      let metrics = typeset.metrics[index]
      hits.lines.append(
        ZoneHits.Line(
          text: text.id, origin: line.origin, ascent: metrics.ascent, descent: metrics.descent,
          layout: layout))
    }
  }

  /// 組んだ行のグリフの連なりを、外観に依らない形（揃えたフォント・縦の位置）に写す。
  private func prepared(_ glyphRuns: [ZoneTextLayout.GlyphRun]) -> [ZoneTextTypeset.Run] {
    glyphRuns.map { run in
      let raised = run.positions.contains { $0.y != 0 }
      return ZoneTextTypeset.Run(
        style: run.style, font: canonical(run.font), glyphs: run.glyphs, positions: run.positions,
        ys: raised ? run.positions.map { Float($0.y) } : [])
    }
  }

  /// 外観に依らない形のグリフの連なりを、字の連なり（フォントと色ごと）に写す。色は連なりの見え方の色 `colors` から引き、
  /// `inks` で解く。
  private func runs(
    _ prepared: [ZoneTextTypeset.Run], colors: [NSColor], origin: CGPoint, inks: inout Inks
  ) -> [ZoneMaterial.Run] {
    prepared.compactMap { run in
      guard colors.indices.contains(run.style) else { return nil }
      return ZoneMaterial.Run(
        font: run.font, glyphs: run.glyphs, xs: run.positions.map { Float(origin.x + $0.x) },
        ys: run.ys, baseline: Float(origin.y), ink: inks.ink(colors[run.style]))
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

/// 1 回の写しの中で、色を外観で解いた字の色の覚え（同じ色を解き直さない）。
@MainActor
private struct Inks {
  let look: ZonePainter.Look
  var known: [NSColor: InkColor] = [:]

  mutating func ink(_ color: NSColor) -> InkColor {
    if let ink = known[color] { return ink }
    let ink = InkColor(color, appearance: look.appearance, space: look.space, scale: look.scale)
    known[color] = ink
    return ink
  }
}

/// 字の行を組んだものを使い回す鍵——連なりごとの字（UTF-16 の並び）と字体。色は含めない。
struct ZoneLabelKey: Hashable {
  let units: [[UInt16]]
  let fonts: [CTFont]

  init(_ runs: [ZoneTextRun]) {
    units = runs.map { Array($0.string.utf16) }
    fonts = runs.map { $0.font as CTFont }
  }
}

/// 選べる文のまとまりを組んだもの——文と見え方と行の範囲（覚えの鍵）と、そこから決まるもの（組んだ行・行ごとの
/// 外観に依らない形のグリフの連なり・行の字体の高さ・文）。面は当たりの表と一緒に持ち、次の描き直しで鍵が同じなら
/// 組み直さない（ホバーの描き直しで段落を組まない）。色は鍵に入れない（組み方を変えないので、写すときに
/// 今の外観で解く）。覚えは当たりの表と同じく、絵の差し込みが外れれば消え、描き直した絵に無いまとまりの分は次の表に
/// 移らない。
struct ZoneTextTypeset {
  /// 外観に依らない形のグリフの連なり（フォントは面の中で揃えたもの。縦の位置は、どれかのグリフが基線から外れるときだけ）。
  struct Run {
    let style: Int
    let font: CTFont
    let glyphs: [CGGlyph]
    let positions: [CGPoint]
    let ys: [Float]
  }

  let content: ZoneStyledText
  let ranges: [NSRange]
  let lines: [ZoneTextLayout.TypesetLine]
  let runs: [[Run]]
  /// 行ごとの、行の始まりの字の見え方の字体（文の終わりの位置なら最後の見え方の字体）の上下の高さ。
  let metrics: [(ascent: CGFloat, descent: CGFloat)]
  let rope: TextRope

  init(_ text: ZoneText, prepare: ([ZoneTextLayout.GlyphRun]) -> [Run]) {
    content = text.content
    ranges = text.lines.map(\.range)
    lines = ZoneTextLayout.lines(of: text)
    runs = lines.map { prepare($0.runs) }
    var end = 0
    let styles = text.content.styles
    let ends = styles.map { style -> Int in
      end += style.length
      return end
    }
    metrics = lines.map { line in
      var (index, upper) = (0, ends.count)
      while index < upper {
        let middle = (index + upper) / 2
        if line.range.location < ends[middle] { upper = middle } else { index = middle + 1 }
      }
      let font =
        styles.indices.contains(index)
        ? styles[index].font : (styles.last?.font ?? NSFont.systemFont(ofSize: 12) as CTFont)
      return (CTFontGetAscent(font), CTFontGetDescent(font))
    }
    rope = TextRope(text.content.string)
  }

  /// `text` を同じに組めるか——色を除く見え方つきの文と、行の範囲が同じ。
  func matches(_ text: ZoneText) -> Bool {
    guard ranges == text.lines.map(\.range), content.styles.count == text.content.styles.count,
      content.string.utf16.elementsEqual(text.content.string.utf16)
    else { return false }
    return zip(content.styles, text.content.styles).allSatisfy {
      var style = $0
      style.color = $1.color
      return style == $1
    }
  }
}
