import AppKit
import CoreText
import OrbeEditorCore

/// 載せる側が描いた絵を材料と当たりの表に写す（main）。写す単位は絵の層で、前の写しと同じ層（同じ参照）は、外観が同じで
/// 入力欄を持たなければ写し直さずに使い回す——写しの仕事は、使い回す層では層の数に比例し、層の中身の大きさに依らない。
/// 画像は倍率と色空間で描いて覚える（同じ画像・大きさなら描き直さない）。
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

    var key: LookKey { LookKey(appearance: appearance.name, space: space, scale: scale) }
  }

  /// 層の写しを使い回せる外観の鍵。
  struct LookKey: Equatable {
    let appearance: NSAppearance.Name
    let space: CGColorSpace
    let scale: CGFloat
  }

  /// 外観に依らない形のグリフの連なり（フォントは面の中で揃えたもの）。
  struct Glyphs {
    let style: Int
    let font: CTFont
    let glyphs: [CGGlyph]
    let xs: [Float]
    let ys: [Float]
  }

  /// 写したもの——材料と当たりの表と、材料の画像が前の写しから変わったか（使い回さずに写した層と、外した層の画像の鍵で
  /// 比べる）。
  struct Painted {
    var material: ZoneMaterial
    var hits: ZoneHits
    var imagesChanged: Bool
  }

  /// 絵 `picture` を外観 `look` で材料に、入力欄を `serial` で場の通し番号に写す。前の写し `previous` と同じ層は、外観が
  /// 同じで入力欄を持たなければ、その材料と当たりの表を使い回す。字の行は、字と字体が同じものを組んだものがあれば使い回す
  /// （色は鍵に入れず、写すたびに今の外観で解く）。
  func paint(
    _ picture: ZonePicture, _ look: Look,
    reusing previous: (material: ZoneMaterial, hits: ZoneHits) = (ZoneMaterial(), ZoneHits()),
    serial: (ZoneTextField) -> Int
  ) -> Painted {
    if look.scale != imageScale || look.space != imageSpace {
      images.removeAll()
      imageScale = look.scale
      imageSpace = look.space
    }
    let key = look.key
    var known: [ObjectIdentifier: Int] = [:]
    if previous.hits.look == key {
      for (index, placed) in previous.hits.layers.enumerated() {
        known[ObjectIdentifier(placed.layer)] = index
      }
    }
    var inks = Inks(look: look)
    var copy = Copy(previous: previous.hits.labels)
    var material = ZoneMaterial()
    var hits = ZoneHits(look: key)
    var kept = Set<Int>()
    var painted: [Int] = []
    for (origin, layer) in picture.layers {
      let (layerMaterial, layerHits): (ZoneMaterial.Layer, ZoneHits.Layer)
      if let index = known[ObjectIdentifier(layer)],
        previous.material.layers[index].layer.fields.isEmpty
      {
        kept.insert(index)
        layerMaterial = previous.material.layers[index].layer
        layerHits = previous.hits.layers[index].hits
      } else {
        (layerMaterial, layerHits) = paint(
          layer, look, inks: &inks, copy: &copy, serial: serial)
        painted += layerMaterial.images.map(\.pixels.key)
      }
      material.layers.append((origin, layerMaterial))
      hits.layers.append(ZoneHits.Placed(origin: origin, layer: layer, hits: layerHits))
    }
    hits.labels = copy.labels
    let dropped = previous.material.layers.indices.filter { !kept.contains($0) }.flatMap {
      previous.material.layers[$0].layer.images.map(\.pixels.key)
    }
    return Painted(
      material: material, hits: hits, imagesChanged: dropped.sorted() != painted.sorted())
  }

  /// 層 `layer` を材料と当たりの表に写す。
  private func paint(
    _ layer: ZoneLayer, _ look: Look, inks: inout Inks, copy: inout Copy,
    serial: (ZoneTextField) -> Int
  ) -> (ZoneMaterial.Layer, ZoneHits.Layer) {
    let resolve = { (color: NSColor?) -> FrameColor in
      color.map { FrameColor($0, appearance: look.appearance, space: look.space) } ?? .clear
    }
    var material = ZoneMaterial.Layer()
    var hits = ZoneHits.Layer()
    for element in layer.elements {
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
        let runs = copy.label(line.runs) { prepared(ZoneTextLayout.line($0).runs) }
        material.runs += Self.runs(
          runs, colors: line.runs.map(\.color), origin: line.origin, inks: &inks)
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
    for text in layer.texts {
      paint(text, inks: &inks, into: &material, hits: &hits)
    }
    precondition(hits.texts.count == layer.texts.count, "選べる文のまとまりの id は絵の差し込みの中で一意")
    precondition(
      Set(hits.buttons.map(\.id)).count == hits.buttons.count, "押せる場所の id は絵の差し込みの中で一意")
    return (material, hits)
  }

  /// 選べる文のまとまり `text` の文を当たりの表に、その組んだ行を材料と当たりの表の行に写す。
  private func paint(
    _ text: ZoneText, inks: inout Inks, into material: inout ZoneMaterial.Layer,
    hits: inout ZoneHits.Layer
  ) {
    let typeset = text.typeset
    let colors = typeset.content.styles.map(\.color)
    let start = hits.lines.count
    for (index, line) in typeset.lines.enumerated() {
      let origin = text.origins[index]
      material.runs += Self.runs(
        prepared(line.runs), colors: colors, origin: origin, inks: &inks)
      let metrics = typeset.metrics[index]
      hits.lines.append(
        ZoneHits.Line(
          text: text.id, origin: origin, ascent: metrics.ascent, descent: metrics.descent,
          layout: line))
    }
    hits.texts[text.id] = ZoneHits.Text(rope: typeset.rope, lines: start..<hits.lines.count)
  }

  /// 外観に依らない形のグリフの連なりを、字の連なり（フォントと色ごと）に写す。色は連なりの見え方の色 `colors` から引き、
  /// `inks` で解く。
  private static func runs(
    _ glyphRuns: [Glyphs], colors: [NSColor], origin: CGPoint, inks: inout Inks
  ) -> [ZoneMaterial.Run] {
    glyphRuns.compactMap { run in
      guard colors.indices.contains(run.style) else { return nil }
      return ZoneMaterial.Run(
        font: run.font, glyphs: run.glyphs, xs: run.xs, ys: run.ys, origin: origin,
        ink: inks.ink(colors[run.style]))
    }
  }

  /// 組んだ行のグリフの連なりを、外観に依らない形（面の中で揃えたフォント）にする。
  private func prepared(_ runs: [ZoneTextLayout.GlyphRun]) -> [Glyphs] {
    runs.map { run in
      Glyphs(style: run.style, font: canonical(run.font), glyphs: run.glyphs, xs: run.xs, ys: run.ys)
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

/// 1 回の写しの中の字の行の覚え——前の写しで組んだものと、この写しで組んだもの（次の写しへ渡すのは、この写しで写した層の
/// 字の行の分だけ）。
private struct Copy {
  let previous: [ZoneLabelKey: [ZonePainter.Glyphs]]
  var labels: [ZoneLabelKey: [ZonePainter.Glyphs]] = [:]

  init(previous: [ZoneLabelKey: [ZonePainter.Glyphs]]) {
    self.previous = previous
  }

  /// 字の連なり `runs` を組んだもの（覚えに無ければ `make` で組む）。
  mutating func label(
    _ runs: [ZoneTextRun], make: ([ZoneTextRun]) -> [ZonePainter.Glyphs]
  ) -> [ZonePainter.Glyphs] {
    let key = ZoneLabelKey(runs)
    let glyphRuns = labels[key] ?? previous[key] ?? make(runs)
    labels[key] = glyphRuns
    return glyphRuns
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
