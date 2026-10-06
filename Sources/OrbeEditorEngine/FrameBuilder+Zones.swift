import CoreText
import Metal
import OrbeEditorCore

/// 区画の箱 1 つ（px）。シェーダの `Box` と同じ並び。`quad` は影の広がりを含む描く矩形、`box` は箱。
struct BoxInstance {
  var quad: SIMD4<Float>
  var box: SIMD4<Float>
  var radius: Float
  var strokeWidth: Float
  var sigma: Float
  var shadowOffset: Float
  var fill: UInt32
  var stroke: UInt32
  var shadow: UInt32
  var pad: UInt32 = 0
}

/// 入力欄 1 つの層——入力欄の矩形と本文の区画の交わりで切り取る、選択と未確定の文字の地・字・下線とキャレット。
struct FieldLayer {
  var scissor: MTLScissorRect
  var overlays = OverlayShapes()
  var text: [[GlyphInstance]] = []
  var color: [[GlyphInstance]] = []
}

/// 区画を描く描画スレッドの持ち物（面ごと）——画像の地図と、入力欄の場ごとの組版のキャッシュ（場の版と行を、本文や
/// 他の入力欄と取り違えない）。
final class ZoneResources {
  let images: ImageAtlas
  private var fieldLines: [Int: LineLayoutCache] = [:]

  init(device: MTLDevice) {
    images = ImageAtlas(device: device)
  }

  /// 入力欄の場 `serial` の組版のキャッシュ。
  func lines(field serial: Int, font: CTFont) -> LineLayoutCache {
    if let cache = fieldLines[serial] { return cache }
    let cache = LineLayoutCache(font: font)
    fieldLines[serial] = cache
    return cache
  }

  /// 材料に無くなった入力欄の場のキャッシュを手放す。
  func keep(fields: Dictionary<Int, FieldMaterial>.Keys) {
    guard fieldLines.count > fields.count else { return }
    fieldLines = fieldLines.filter { fields.contains($0.key) }
  }
}

/// 区画——並びの塊の y に、区画の材料（箱・画像・選んだ文の地・字・入力欄の中身）を本文と同じ 1 コマに置く。区画は横に
/// 送らない（本文の区画の左端が区画の左端）。影は区画の外へ落ちるので、見えている範囲の少し外の区画も描く。
extension FrameBuilder {
  /// 区画の影が区画の外へ落ちうる幅（pt）。
  static let zoneOverhang = 48.0

  func drawZones(_ source: Source, _ c: Context) {
    let g = c.g
    let rows = g.rows
    source.zones.keep(fields: source.material.fields.keys)
    guard rows.hasZones else { return }
    source.zones.images.beginFrame()
    let margin = Self.zoneOverhang * g.scale
    let bottom = g.scrollY + g.height - g.top
    for index in rows.blocks(from: g.scrollY - margin, to: bottom + margin, scale: g.scale) {
      guard case .zone(let id) = rows.contents[index], let zone = source.material.zones[id]
      else { continue }
      drawZone(zone, id: id, top: g.blockTop(index), source, c)
    }
  }

  private func drawZone(
    _ zone: ZoneMaterial, id: ObjectIdentifier, top: Double, _ source: Source, _ c: Context
  ) {
    let s = c.g.scale
    let left = c.g.column
    for box in zone.boxes { zoneBoxes.append(Self.instance(box, left: left, top: top, scale: s)) }
    for image in zone.images {
      guard let entry = source.zones.images.entry(image.pixels) else { continue }
      let x = (left + Double(image.frame.minX) * s).rounded()
      let y = (top + Double(image.frame.minY) * s).rounded()
      Self.append(
        GlyphInstance(
          position: SIMD2(Float(x), Float(y)), size: SIMD2(Float(entry.width), Float(entry.height)),
          uv: SIMD2(Float(entry.x), Float(entry.y)), color: 0xFFFF_FFFF),
        to: &zoneImages, page: entry.page)
    }
    if let selection = source.material.zoneSelection, selection.zone == id {
      let ink = selection.focused ? c.palette.selection : c.palette.inactiveSelection
      for rect in selection.rects {
        let x0 = (left + Double(rect.minX) * s).rounded()
        let x1 = (left + Double(rect.maxX) * s).rounded()
        let y0 = (top + Double(rect.minY) * s).rounded()
        let y1 = (top + Double(rect.maxY) * s).rounded()
        zoneSelectionShapes.append(
          ShapeInstance(
            rect: SIMD4(Float(x0), Float(y0), Float(x1 - x0), Float(y1 - y0)), color: ink.packed,
            radius: 0, kind: 0))
      }
    }
    for run in zone.runs {
      let font = c.fonts.id(instance: run.font)
      let baseline = top + Double(run.baseline) * s
      for i in run.glyphs.indices {
        let y = run.ys.isEmpty ? baseline : baseline - Double(run.ys[i]) * s
        place(
          Glyph(font: font, glyph: run.glyphs[i], x: left + Double(run.xs[i]) * s, baseline: y),
          run.ink, .text, c)
      }
    }
    for field in zone.fields {
      guard let material = source.material.fields[field.serial] else { continue }
      drawField(field, material, origin: (left, top), source, c)
    }
  }

  /// 箱を px へ写す（箱の縁は装置の画素に揃える）。影は縦に `shadowOffset` ずれ、ぼかし（CSS の blur radius）の半分を σ
  /// とするガウスで、σ の 3 倍まで広がる。
  private static func instance(_ box: ZoneMaterial.Box, left: Double, top: Double, scale: Double)
    -> BoxInstance
  {
    let x0 = (left + Double(box.frame.minX) * scale).rounded()
    let y0 = (top + Double(box.frame.minY) * scale).rounded()
    let x1 = (left + Double(box.frame.maxX) * scale).rounded()
    let y1 = (top + Double(box.frame.maxY) * scale).rounded()
    let sigma = box.shadow.packed >> 24 == 0 ? 0 : Double(box.shadowBlur) / 2 * scale
    let dy = Double(box.shadowOffset) * scale
    let reach = (3 * sigma).rounded(.up)
    let quad = (
      min(x0, x0 - reach), min(y0, y0 + dy - reach), max(x1, x1 + reach), max(y1, y1 + dy + reach)
    )
    return BoxInstance(
      quad: SIMD4(
        Float(quad.0), Float(quad.1), Float(quad.2 - quad.0), Float(quad.3 - quad.1)),
      box: SIMD4(Float(x0), Float(y0), Float(x1 - x0), Float(y1 - y0)),
      radius: box.radius * Float(scale), strokeWidth: box.strokeWidth * Float(scale),
      sigma: Float(sigma), shadowOffset: Float(dy), fill: box.fill.packed,
      stroke: box.stroke.packed, shadow: box.shadow.packed)
  }

  /// 入力欄の場の文を、入力欄の矩形に描く（入力欄の矩形と本文の区画の交わりで切り取る。横は場の送りの分だけ左へずらす）。
  /// 選択・キャレット・未確定の文字は本文と同じ描き方で、場の色で描く。`origin` は区画の左上（px）。
  private func drawField(
    _ field: ZoneMaterial.Field, _ material: FieldMaterial, origin: (x: Double, y: Double),
    _ source: Source, _ c: Context
  ) {
    let g = c.g
    let s = g.scale
    let x0 = (origin.x + Double(field.frame.minX) * s).rounded()
    let y0 = (origin.y + Double(field.frame.minY) * s).rounded()
    let bottom = (origin.y + Double(field.frame.maxY) * s).rounded()
    let frame = CGRect(
      x: x0, y: y0, width: (origin.x + Double(field.frame.maxX) * s).rounded() - x0,
      height: bottom - y0)
    let clip = frame.intersection(
      CGRect(x: g.column, y: g.top, width: g.textRight - g.column, height: g.height - g.top))
    guard !clip.isEmpty else { return }
    var layer = FieldLayer(
      scissor: MTLScissorRect(
        x: Int(clip.minX), y: Int(clip.minY), width: Int(clip.width), height: Int(clip.height)))
    let text = material.content.text
    let cache = source.zones.lines(field: field.serial, font: material.font)
    let tabColumns = Indentation.fallback.unit
    cache.beginFrame(version: material.content.version, tabColumns: tabColumns)
    if let reveal = material.reveal {
      revealField(reveal, material, width: Double(field.frame.width), cache: cache, c)
    }
    let pen = Self.pen(material, originX: x0 - (material.scroll.x * s).rounded(), c)
    var overlays = CaretOverlays(
      material.caret, drop: nil, caretVisible: source.caretVisible, text: text, from: 0)
    let lastRow = text.lineCount - 1
    for row in 0...lastRow {
      let rowTop = y0 + (Double(row) * pen.lineHeight).rounded()
      guard rowTop < bottom, rowTop < g.height else { break }
      let start = text.lineStart(row)
      let end = row < lastRow ? text.lineStart(row + 1) : text.length
      let overlay = overlays.next(row: row, line: start..<end)
      let laid = cache.line(
        row: row,
        source: { LineShaper.source(start: start, next: row < lastRow ? end : nil, in: text) },
        tabColumns: tabColumns, config: c.config, fonts: c.fonts, carets: overlay.needsCarets)
      layer.overlays.draw(overlay, laid, rowTop: rowTop, pen)
      let baseline = rowTop + pen.baseline
      for i in laid.glyphs.indices {
        let y = laid.ys.isEmpty ? baseline : baseline - Double(laid.ys[i]) * s
        let glyph = Glyph(
          font: laid.fonts[i], glyph: laid.glyphs[i], x: pen.originX + Double(laid.xs[i]) * s,
          baseline: y)
        guard let placed = placed(glyph, material.palette.text, c) else { continue }
        if placed.isColor {
          Self.append(placed.instance, to: &layer.color, page: placed.page)
        } else {
          Self.append(placed.instance, to: &layer.text, page: placed.page)
        }
      }
    }
    cache.endFrame()
    fieldLayers.append(layer)
  }

  /// 取引が頼んだ「キャレットが見えるところまで」を、キャレットの行を組んだ x で入力欄の横の送りに解く（まだ解いていない
  /// 頼みだけ。送りが動けば、このコマの後で main へ知らせる）。
  private func revealField(
    _ reveal: HorizontalReveal, _ material: FieldMaterial, width: Double, cache: LineLayoutCache,
    _ c: Context
  ) {
    let text = material.content.text
    let location = min(max(0, reveal.range.location), text.length)
    let row = text.row(containing: location)
    let start = text.lineStart(row)
    let laid = cache.line(
      row: row,
      source: {
        LineShaper.source(
          start: start, next: row + 1 < text.lineCount ? text.lineStart(row + 1) : nil, in: text)
      }, tabColumns: Indentation.fallback.unit, config: c.config, fonts: c.fonts, carets: true)
    guard let carets = laid.carets else { return }
    let x = Double(carets.x(location - start))
    let caret = x...(x + Double(c.config.caretSize.width))
    if material.scroll.reveal(serial: reveal.serial, caret: caret, width: width) {
      fieldRevealed = true
    }
  }

  /// 入力欄の行に重ねるものの筆——行頭の x が `originX`（px）、行の高さと基線は入力欄の見え方、色は入力欄の色（未確定の
  /// 文字の見た目は本文と同じ）。
  private static func pen(_ material: FieldMaterial, originX: Double, _ c: Context) -> OverlayPen {
    let s = c.g.scale
    let lineHeight = Double(material.lineHeight)
    let ascent = Double(CTFontGetAscent(material.font))
    let descent = Double(CTFontGetDescent(material.font))
    return OverlayPen(
      originX: originX, lineHeight: lineHeight * s,
      baseline: (((lineHeight - (ascent + descent)) / 2 + ascent) * s).rounded(), scale: s,
      cell: Double(c.config.cell),
      caretSize: CGSize(
        width: c.config.caretSize.width, height: min(c.config.caretSize.height, lineHeight)),
      focused: material.caret.focused, selection: material.palette.selection,
      inactiveSelection: material.palette.inactiveSelection, caret: material.palette.caret,
      activeClause: material.palette.text.color, markedUnderline: c.palette.markedUnderline,
      markedBackground: c.palette.markedBackground)
  }
}
