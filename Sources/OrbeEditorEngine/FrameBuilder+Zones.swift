import CoreText
import Metal
import OrbeEditorCore

/// 絵の差し込みの箱 1 つ（px）。シェーダの `Box` と同じ並び。`quad` は影の広がりを含む描く矩形、`box` は箱。
struct BoxInstance {
  var quad: SIMD4<Float>
  var box: SIMD4<Float>
  /// 角ごとの半径（左上・右上・右下・左下。px）。
  var radius: SIMD4<Float>
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

/// 絵の差し込みを描く描画スレッドの持ち物（面ごと）——画像の地図と、入力欄の場ごとの組版のキャッシュ（場の版と行を、
/// 本文や他の入力欄と取り違えない）。
final class ZoneResources {
  let images: ImageAtlas
  private var fieldLines: [Int: LineLayoutCache] = [:]

  init(device: MTLDevice) {
    images = ImageAtlas(device: device)
  }

  /// 入力欄の場 `serial` の組版のキャッシュ（場の字体と刻みは場ごとに変わらない）。
  func lines(field serial: Int, _ material: FieldMaterial) -> LineLayoutCache {
    if let cache = fieldLines[serial] { return cache }
    let cache = LineLayoutCache(font: material.font, tabWidth: material.tabWidth)
    fieldLines[serial] = cache
    return cache
  }

  /// 材料に無くなった入力欄の場のキャッシュを手放す。
  func keep(fields: Dictionary<Int, FieldMaterial>.Keys) {
    guard fieldLines.count > fields.count else { return }
    fieldLines = fieldLines.filter { fields.contains($0.key) }
  }
}

/// 絵の差し込み——並びの塊の y に、絵の差し込みを描く材料（箱・画像・選んだ文の地・字・入力欄の中身）を本文と
/// 同じ 1 コマに置く。絵の差し込みは横に送らない。左端はいつも本文の区画の左端に揃う。影は絵の差し込みの外へ
/// 落ちるので、見えている範囲の少し外の絵の差し込みも描く。
extension FrameBuilder {
  /// 影が絵の差し込みの外へ落ちうる幅（pt）。
  static let zoneOverhang = 48.0

  func drawZones(_ source: Source, _ c: Context) {
    let g = c.g
    let rows = g.rows
    source.zones.keep(fields: source.material.fields.keys)
    guard rows.hasZones else { return }
    let margin = Self.zoneOverhang * g.scale
    let bottom = g.scrollY + g.height - g.top
    for index in rows.blocks(from: g.scrollY - margin, to: bottom + margin, scale: g.scale) {
      guard case .zone(let id) = rows.contents[index], let zone = source.material.zones[id]
      else { continue }
      drawZone(zone, id: id, top: g.blockTop(index), source, c)
    }
  }

  /// 行の頭の印の絵——ポインタの下の、印を出せる行の頭の列の左右の中央、行の上端から行 1 つ分の高さの縦の中央に描く。
  /// 絵の画像は行番号の列の切り取りの中の層（`markImages`）に積む。
  func drawLeadingMark(_ source: Source, _ c: Context) {
    guard let mark = source.material.leadingMark, let row = mark.hover, let look = mark.look,
      let lead = c.arrangement.leadingMark?.width
    else { return }
    let g = c.g
    switch row {
    case .document(let line):
      guard line < source.material.content?.text.lineCount ?? 0 else { return }
    case .inserted(let block, _):
      guard block < g.rows.count else { return }
    }
    let s = g.scale
    let top = g.extent(of: row).top
    drawPicture(
      look,
      at: (
        ((Double(lead) - Double(mark.size.width)) / 2 * s).rounded(),
        top + ((g.lineHeight - Double(mark.size.height) * s) / 2).rounded()
      ), layer: .mark, source, c)
  }

  private func drawZone(
    _ zone: ZoneMaterial, id: ObjectIdentifier, top: Double, _ source: Source, _ c: Context
  ) {
    let s = c.g.scale
    let left = c.g.column
    drawPicture(zone, at: (left, top), layer: .zone, source, c)
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
    for (origin, layer) in zone.layers {
      let at = (left + Double(origin.x) * s, top + Double(origin.y) * s)
      for field in layer.fields {
        guard let material = source.material.fields[field.serial] else { continue }
        drawField(field, material, origin: at, source, c)
      }
    }
  }

  /// 絵の画像を積む層——絵の差し込みの画像（本文の区画の切り取りの中）か、行の頭の印の絵（行番号の列の切り取りの中）。
  enum PictureLayer {
    case zone, mark
  }

  /// 絵の箱・画像・字を、左上 `origin`（px）に置く（層ごとに、層の原点の分ずらす）。画像は層 `layer` の画像の列（画像の地図の
  /// 頁ごと）に積み、その層の切り取りの横の範囲の外の画像は積まない。
  private func drawPicture(
    _ zone: ZoneMaterial, at origin: (left: Double, top: Double), layer: PictureLayer,
    _ source: Source, _ c: Context
  ) {
    let s = c.g.scale
    for (layerOrigin, part) in zone.layers {
      drawLayer(
        part,
        at: (origin.left + Double(layerOrigin.x) * s, origin.top + Double(layerOrigin.y) * s),
        into: layer, source, c)
    }
  }

  /// 層 1 つの箱・画像・字を、層の原点 `origin`（px）に置く。
  private func drawLayer(
    _ layer: ZoneMaterial.Layer, at origin: (left: Double, top: Double), into target: PictureLayer,
    _ source: Source, _ c: Context
  ) {
    let (left, top) = origin
    let g = c.g
    let s = g.scale
    for box in layer.boxes { zoneBoxes.append(Self.instance(box, left: left, top: top, scale: s)) }
    for image in layer.images {
      let x = (left + Double(image.frame.minX) * s).rounded()
      let y = (top + Double(image.frame.minY) * s).rounded()
      // 画像は層の切り取りの中に描く。その外の画像は地図に入れない（見えている画像の場所を取らない）。
      let columns = target == .zone ? g.column..<g.textRight : 0..<g.column
      guard x < columns.upperBound, x + Double(image.pixels.width) > columns.lowerBound,
        y < g.height,
        y + Double(image.pixels.height) > g.top,
        let entry = source.zones.images.entry(image.pixels)
      else { continue }
      let instance = GlyphInstance(
        position: SIMD2(Float(x), Float(y)), size: SIMD2(Float(entry.width), Float(entry.height)),
        uv: SIMD2(Float(entry.x), Float(entry.y)), color: 0xFFFF_FFFF)
      switch target {
      case .zone: Self.append(instance, to: &zoneImages, page: entry.page)
      case .mark: Self.append(instance, to: &markImages, page: entry.page)
      }
    }
    for run in layer.runs {
      let baseline = top + Double(run.origin.y) * s
      // 見えている範囲の外の字の行は置かない（長い本文の絵の差し込みの一部だけが見えている間も、字のアトラスに見えない字を
      // 入れない）。行の上下は字の大きさの 2 倍まで見る。
      let reach = Double(CTFontGetSize(run.font)) * 2 * s
      guard baseline + reach > g.top, baseline - reach < g.height else { continue }
      let font = c.fonts.id(instance: run.font)
      let x = Double(run.origin.x)
      for i in run.glyphs.indices {
        let y = run.ys.isEmpty ? baseline : baseline - Double(run.ys[i]) * s
        place(
          Glyph(
            font: font, glyph: run.glyphs[i], x: left + (x + Double(run.xs[i])) * s, baseline: y),
          run.ink, .text, c)
      }
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

  /// 入力欄の場の文を、入力欄の矩形に描く（入力欄の矩形と本文の区画の交わりで切り取る。横は場の送りの分だけ
  /// 左へずらす）。選択・キャレット・未確定の文字は本文と同じ描き方で、場の色で描く。`origin` は入力欄の層の原点（px）。
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
    let clip =
      frame
      .intersection(
        CGRect(x: g.column, y: g.top, width: g.textRight - g.column, height: g.height - g.top)
      )
      .intersection(CGRect(x: 0, y: 0, width: g.width, height: g.height))
    guard !clip.isEmpty else { return }
    var layer = FieldLayer(
      scissor: MTLScissorRect(
        x: Int(clip.minX), y: Int(clip.minY), width: Int(clip.width), height: Int(clip.height)))
    let text = material.content.text
    let cache = source.zones.lines(field: field.serial, material)
    let tabColumns = material.tabColumns
    cache.beginFrame(version: material.content.version, tabColumns: tabColumns)
    if let reveal = material.reveal {
      revealField(reveal, material, width: Double(field.frame.width), cache: cache, c)
    }
    limitFieldScroll(material, width: Double(field.frame.width), cache: cache, c)
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
      }, tabColumns: material.tabColumns, config: c.config, fonts: c.fonts, carets: true)
    guard let carets = laid.carets else { return }
    let x = Double(carets.x(location - start))
    let caret = x...(x + Double(c.config.caretSize.width))
    if material.scroll.reveal(serial: reveal.serial, caret: caret, width: width) {
      fieldRevealed = true
    }
  }

  /// 入力欄の横の送りを、最も広い行（全行。組むのは本文の版ごとに 1 回）とキャレットが幅 `width` に収まる所までに収める
  /// （動けば、このコマの後で main へ知らせる）。
  private func limitFieldScroll(
    _ material: FieldMaterial, width: Double, cache: LineLayoutCache, _ c: Context
  ) {
    let text = material.content.text
    let tabColumns = material.tabColumns
    let widest = cache.widestWidth(
      version: material.content.version, tabColumns: tabColumns, rows: text.lineCount
    ) { row in
      cache.line(
        LineShaper.source(
          start: text.lineStart(row),
          next: row + 1 < text.lineCount ? text.lineStart(row + 1) : nil, in: text),
        tabColumns: tabColumns, config: c.config, fonts: c.fonts)
    }
    let limit = Double(widest) + Double(c.config.caretSize.width) - width
    if material.scroll.clamp(to: limit) { fieldRevealed = true }
  }

  /// 入力欄の行に重ねるものの筆——行頭の x が `originX`（px）、行の高さと基線は入力欄の見え方、色は入力欄の色（未確定の
  /// 文字の見た目は本文と同じ）。
  private static func pen(_ material: FieldMaterial, originX: Double, _ c: Context) -> OverlayPen {
    let s = c.g.scale
    let lineHeight = Double(material.lineHeight)
    return OverlayPen(
      originX: originX, lineHeight: lineHeight * s,
      baseline: (Double(material.baseline) * s).rounded(), scale: s,
      cell: Double(c.config.cell),
      caretSize: CGSize(
        width: c.config.caretSize.width, height: min(c.config.caretSize.height, lineHeight)),
      focused: material.caret.focused, selection: material.palette.selection,
      inactiveSelection: material.palette.inactiveSelection, caret: material.palette.caret,
      activeClause: material.palette.text.color, markedUnderline: c.palette.markedUnderline,
      markedBackground: c.palette.markedBackground)
  }
}
