import CoreText
import Metal
import OrbeEditorCore

/// グリフ 1 つ（px）。シェーダの `Glyph` と同じ並び。
struct GlyphInstance {
  var position: SIMD2<Float>
  var size: SIMD2<Float>
  var uv: SIMD2<Float>
  var color: UInt32
  var pad: UInt32 = 0
}

/// 図形 1 つ（px）。`kind` は 0 が角の丸い矩形、1 が右向きの三角。シェーダの `Shape` と同じ並び。
struct ShapeInstance {
  var rect: SIMD4<Float>
  var color: UInt32
  var radius: Float
  var kind: UInt32
  var pad: UInt32 = 0
}

/// 1 コマの中身を組み立てる（描画スレッドだけ。配列は面ごとに使い回す）。重ねる順は `Renderer.encode` が持つ。
///
/// 行の位置は上端の余白 + 縦の並び（`RowLayout`。差し込みが無ければ行 × 行高）で、折り返さない。見えている行と差し込んだ
/// 行だけその場で組版し（キャッシュする）、字の色は
/// 行ごとに、横に見えている字の区間の役割を役割の並びから引いて決める（長い行でも行全体の役割は引かない）。スクロール量
/// は装置の画素に揃える（字がにじまない）。
final class FrameBuilder {
  private(set) var text: [[GlyphInstance]] = []
  private(set) var color: [[GlyphInstance]] = []
  private(set) var gutter: [[GlyphInstance]] = []
  var shapes: [ShapeInstance] = []
  /// 行の型の地（行番号の列の左端から本文の区画の右端まで。いちばん下の層）。
  var lineBackgrounds: [ShapeInstance] = []
  /// 行の装備（空白の丸点・URL の下線。本文の列に切り取る）。
  var decorShapes: [ShapeInstance] = []
  /// 本文の行に重ねるもの——選択の地と未確定の文字の地、未確定の文字の下線・キャレット・落とす位置の印（本文の列に
  /// 切り取る）。
  var overlays = OverlayShapes()
  /// 強調の地（本文の列に切り取る）。
  var highlightShapes: [ShapeInstance] = []
  private(set) var textScissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
  private(set) var gutterScissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
  /// 区画の箱と行の型の地の切り取り——行番号の列と本文の区画（区画の影は行番号の列にも落ちる。行番号と印はその上に描く）。
  private(set) var zoneScissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
  /// 組んだ行のうち最も長い幅（pt。末尾の「ほか N 字」を含む）。
  var longestLine: CGFloat = 0
  /// このコマのミニマップ。
  var minimap = MinimapFrame()
  /// 影（上端・ミニマップの左）と、俯瞰の図形（ミニマップの帯・縦横のスクロールバーと印）。
  var shadowShapes: [ShapeInstance] = []
  var overviewShapes: [ShapeInstance] = []
  /// スクロールバーの印の縦の区間（元が変わったときだけ作り直す）。
  var rulerSpans = RulerSpans()
  /// 区画の箱・画像（画像の地図の頁ごと）・区画の文の選択の地（本文の列に切り取る）。
  var zoneBoxes: [BoxInstance] = []
  var zoneImages: [[GlyphInstance]] = []
  var zoneSelectionShapes: [ShapeInstance] = []
  /// 見えている入力欄の層。
  var fieldLayers: [FieldLayer] = []
  /// このコマで入力欄の横の送りが動いた（main へ知らせる）。
  var fieldRevealed = false

  /// GPU の buffer に要る大きさ（配列ごとに 256 バイトに揃える）。
  var byteCount: Int {
    let fields = fieldLayers
    let glyphArrays = text + color + gutter + zoneImages + fields.flatMap { $0.text + $0.color }
    let glyphs = glyphArrays.reduce(0) {
      $0 + (($1.count * MemoryLayout<GlyphInstance>.stride + 255) & ~255)
    }
    let boxes = (zoneBoxes.count * MemoryLayout<BoxInstance>.stride + 255) & ~255
    let cells = minimap.chunks.reduce(0) {
      $0 + (($1.cells.count * MemoryLayout<MinimapCellInstance>.stride + 255) & ~255)
    }
    return
      ([
        lineBackgrounds, shapes, decorShapes, overlays.under, highlightShapes, overlays.over,
        minimap.decorations,
        shadowShapes, overviewShapes, zoneSelectionShapes,
      ] + fields.flatMap { [$0.overlays.under, $0.overlays.over] })
      .reduce(boxes + glyphs + cells + ((MemoryLayout<GlyphInstance>.stride + 255) & ~255)) {
        $0 + (($1.count * MemoryLayout<ShapeInstance>.stride + 255) & ~255)
      }
  }

  /// px の座標系（左上が原点）。
  struct Geometry {
    let scale: Double
    let width: Double
    let height: Double
    let scrollX: Double
    let scrollY: Double
    let top: Double
    let lineHeight: Double
    let column: Double
    /// 本文の区画の右端（ミニマップの左端）。
    let textRight: Double
    /// 縦の並び（pt。px へは `scale` を掛けて引く）。
    let rows: RowLayout

    /// 文書の行の上端の y。
    func rowTop(_ row: Int) -> Double {
      top + rows.y(ofLine: row, scale: scale).rounded() - scrollY
    }

    /// 文書の行の下端の y（その行の下の差し込みは含めない）。
    func rowBottom(_ row: Int) -> Double {
      top + (rows.y(ofLine: row, scale: scale) + lineHeight).rounded() - scrollY
    }

    /// 塊 `index`（区画）の上端の y。
    func blockTop(_ index: Int) -> Double {
      top + rows.top(ofBlock: index, scale: scale).rounded() - scrollY
    }

    /// 塊 `index` の中の `line` 行目の上端の y。
    func insertedTop(block index: Int, line: Int) -> Double {
      top + (rows.top(ofBlock: index, scale: scale) + Double(line) * lineHeight).rounded()
        - scrollY
    }
  }

  /// 1 コマの間だけ使う、描く先の座標系と色・アトラス・見え方。
  struct Context {
    let g: Geometry
    let palette: FramePalette
    /// 面に焦点があるか（選択の地の色）。
    let focused: Bool
    let atlas: GlyphAtlas
    let config: SurfaceConfig
    /// タブの桁（インデントの単位）。
    let tabColumns: Int
    /// 役割の並び（字と下線の色）。
    let roles: RoleRuns
    /// ⌘ を押している間の本文の上のポインタ（px）。焦点が無ければ nil。
    let linkPointer: SIMD2<Double>?
    /// 本文の行に重ねるもの（選択・キャレット・未確定の文字・落とす位置）の筆。
    let pen: OverlayPen
    let fonts: FontRegistry
    /// 行番号の列の中の配置と、番号の列の数。
    let gutter: GutterColumns
    let numberColumns: Int
  }

  /// 1 コマを組む元。
  struct Source {
    let material: FrameMaterial
    let position: SIMD2<Double>
    /// その位置の範囲（俯瞰は端を越えている間も端の位置を表す）。
    let limits: ScrollPhysics.Limits
    /// このコマでキャレットを描くか（点滅と焦点）。
    let caretVisible: Bool
    /// 描く先の大きさ（px）。
    let pixels: (width: Int, height: Int)
    let atlas: GlyphAtlas
    let config: SurfaceConfig
    let minimapCells: MinimapCells
    let rulerRows: RulerRows
    /// 帯とつまみの濃さの時間の動きと、このコマの時刻。
    let motion: OverviewMotion
    let time: Double
    /// 横の範囲の基準を取り直した測定の回数（`ScrollBox.baselines`）。
    let baselines: Int
    /// 前のコマのミニマップの配置（揺れ止め）。
    let previousPlacement: MinimapLayout?
    /// 区画を描く持ち物（画像の地図・入力欄の組版のキャッシュ）。
    let zones: ZoneResources
  }

  /// コマを組む（組版のキャッシュのコマは呼び手が始めてある——`Renderer.begin`）。
  func build(_ source: Source, cache: LineLayoutCache, fonts: FontRegistry) {
    for i in text.indices { text[i].removeAll(keepingCapacity: true) }
    for i in color.indices { color[i].removeAll(keepingCapacity: true) }
    for i in gutter.indices { gutter[i].removeAll(keepingCapacity: true) }
    shapes.removeAll(keepingCapacity: true)
    lineBackgrounds.removeAll(keepingCapacity: true)
    decorShapes.removeAll(keepingCapacity: true)
    overlays.removeAll()
    highlightShapes.removeAll(keepingCapacity: true)
    shadowShapes.removeAll(keepingCapacity: true)
    overviewShapes.removeAll(keepingCapacity: true)
    zoneBoxes.removeAll(keepingCapacity: true)
    for i in zoneImages.indices { zoneImages[i].removeAll(keepingCapacity: true) }
    zoneSelectionShapes.removeAll(keepingCapacity: true)
    fieldLayers.removeAll(keepingCapacity: true)
    fieldRevealed = false
    longestLine = 0
    minimap.reset()
    let config = source.config
    guard let content = source.material.content, let palette = source.material.palette else {
      return
    }
    let s = Double(source.material.scale)
    let lineCount = content.text.lineCount
    let rows = source.material.rows
    let layout = config.layout(
      size: source.material.size, lineCount: lineCount, rows: rows,
      arrangement: source.material.arrangement)
    let g = Geometry(
      scale: s, width: Double(source.pixels.width), height: Double(source.pixels.height),
      scrollX: (source.position.x * s).rounded(), scrollY: (source.position.y * s).rounded(),
      top: (Double(config.topInset) * s).rounded(), lineHeight: Double(config.lineHeight) * s,
      column: (Double(layout.column) * s).rounded(),
      textRight: (Double(layout.text.maxX) * s).rounded(), rows: rows)
    let tabColumns = source.material.tabColumns
    let focused = source.material.caret.focused
    let c = Context(
      g: g, palette: palette, focused: focused, atlas: source.atlas, config: config,
      tabColumns: tabColumns, roles: content.roles,
      linkPointer: focused
        ? source.material.linkPointer.map { SIMD2(Double($0.x) * s, Double($0.y) * s) } : nil,
      pen: OverlayPen(
        originX: g.column - g.scrollX, lineHeight: g.lineHeight,
        baseline: (Double(config.baseline) * s).rounded(), scale: s, cell: Double(config.cell),
        caretSize: config.caretSize, focused: focused, selection: palette.selection,
        inactiveSelection: palette.inactiveSelection, caret: palette.caret,
        activeClause: palette.text.color, markedUnderline: palette.markedUnderline,
        markedBackground: palette.markedBackground), fonts: fonts, gutter: layout.gutter,
      numberColumns: source.material.arrangement.numberColumns)
    textScissor = Self.scissor(x: g.column, y: g.top, width: g.textRight - g.column, g)
    gutterScissor = Self.scissor(x: 0, y: g.top, width: g.column, g)
    zoneScissor = Self.scissor(x: 0, y: g.top, width: g.textRight, g)
    let lines = source.limits.viewportLines(at: source.position, rows: rows, lineCount: lineCount)
    buildMinimap(layout, lines: lines, source, content, c)
    drawShadows(layout, lines: lines, clipsRight: Self.clipsRight(source), c)
    drawVerticalScrollbar(layout, lines: lines, source, content, c)
    drawSliders(
      layout, lines: lines, source,
      contentLines: CGFloat(rows.contentLines(lineCount: lineCount)), c)
    guard g.height > g.top else { return }
    drawRows(source, content, cache: cache, c)
  }

  /// 見えている行を組む（組版のキャッシュのコマはここで終える）。行頭はロープを 1 度辿って引き、前のコマで描いていない
  /// 行だけ中身を読む。
  func layRows(
    _ rows: ClosedRange<Int>, _ source: Source, text: TextRope, cache: LineLayoutCache,
    fonts: FontRegistry
  ) -> [RowInFrame] {
    var result: [RowInFrame] = []
    result.reserveCapacity(rows.count)
    let starts = text.lineStarts(rows.lowerBound..<(rows.upperBound + 1))
    var overlays = CaretOverlays(
      source.material.caret, drop: source.material.drop, caretVisible: source.caretVisible,
      text: text, from: starts[0])
    let highlights = source.material.highlights
    let lastRow = text.lineCount - 1
    for (index, row) in rows.enumerated() {
      let start = starts[index]
      let end = starts[index + 1]
      let overlay = overlays.next(row: row, line: start..<end)
      let highlighted = highlights.touches(start..<max(end, start + 1))
      let laid = cache.line(
        row: row,
        source: { LineShaper.source(start: start, next: row < lastRow ? end : nil, in: text) },
        tabColumns: source.material.tabColumns, config: source.config, fonts: fonts,
        carets: overlay.needsCarets || highlighted)
      result.append(RowInFrame(row: row, start: start, end: end, laid: laid, overlay: overlay))
    }
    cache.endFrame()
    return result
  }

  /// 本文が右にまだ続く（横に隠れている部分がある）か。
  static func clipsRight(_ source: Source) -> Bool {
    let maximum = source.limits.maximum.x
    return min(max(0, source.position.x), maximum) < maximum - 0.5 / Double(source.material.scale)
  }

  /// このコマで描く行 1 つ。
  struct RowInFrame {
    let row: Int
    /// 行頭と次の行頭のオフセット。
    let start: Int
    let end: Int
    let laid: LaidOutLine
    let overlay: RowOverlays
    /// 行の型の字の色（あれば構文の色に代わる）。
    var ink: InkColor?
  }

  /// 横に見えている字——グリフの番号の区間と、その字の行内の位置の範囲（見えている字が無ければ nil）。行番号の列の下に
  /// 隠れる字（左に 4 桁の余裕を残す）と本文の区画の右の外の字は含めない。
  struct VisibleGlyphs {
    let glyphs: Range<Int>
    let offsets: ClosedRange<Int>?
  }

  func visibleGlyphs(_ line: LaidOutLine, _ c: Context) -> VisibleGlyphs {
    let g = c.g
    let originX = g.column - g.scrollX
    let leftmost = Float((g.column - originX) / g.scale - Double(c.config.cell) * 4)
    let rightmost = Float((g.textRight - originX) / g.scale)
    let from = Self.lowerBound(line.xs, leftmost)
    var to = from
    var low = Int32.max
    var high = Int32.min
    while to < line.glyphs.count, line.xs[to] <= rightmost {
      low = min(low, line.offsets[to])
      high = max(high, line.offsets[to])
      to += 1
    }
    return VisibleGlyphs(glyphs: from..<to, offsets: from < to ? Int(low)...Int(high) : nil)
  }

  /// 置くグリフ 1 つ（x・基線は px。基線は y が下向きの座標）。
  struct Glyph {
    let font: UInt16
    let glyph: CGGlyph
    let x: Double
    let baseline: Double
  }

  /// グリフを置く。横の置き方はアトラスが Core Graphics と同じに決める。縦は装置の画素に揃え、端数は Core Graphics と
  /// 同じく下向きへ切り上げる。
  func place(_ item: Glyph, _ ink: InkColor, _ layer: FrameBuilderLayer, _ c: Context) {
    guard let placed = placed(item, ink, c) else { return }
    if placed.isColor {
      Self.append(placed.instance, to: &color, page: placed.page)
    } else if layer == .gutter {
      Self.append(placed.instance, to: &gutter, page: placed.page)
    } else {
      Self.append(placed.instance, to: &text, page: placed.page)
    }
  }

  /// アトラスに置いたグリフ——instance と、アトラスの頁と、色付きの字か。
  struct PlacedGlyph {
    let instance: GlyphInstance
    let page: Int
    let isColor: Bool
  }

  /// グリフをアトラスに置く（頁が埋まって置けなければ nil）。
  func placed(_ item: Glyph, _ ink: InkColor, _ c: Context) -> PlacedGlyph? {
    guard
      let (entry, pen) = c.atlas.glyph(
        font: item.font, glyph: item.glyph, x: item.x, dilation: ink.dilation)
    else { return nil }
    let instance = GlyphInstance(
      position: SIMD2(
        Float(pen) + Float(entry.left), Float(item.baseline.rounded(.up)) - Float(entry.top)),
      size: SIMD2(Float(entry.w), Float(entry.h)), uv: SIMD2(Float(entry.u), Float(entry.v)),
      color: entry.isColor ? 0xFFFF_FFFF : ink.color.packed)
    return PlacedGlyph(instance: instance, page: Int(entry.page), isColor: entry.isColor)
  }

  static func append(
    _ instance: GlyphInstance, to pages: inout [[GlyphInstance]], page: Int
  ) {
    while pages.count <= page { pages.append([]) }
    pages[page].append(instance)
  }

  /// `xs` の中で `value` 以上の最初の位置（左から右の字は x が増えていく）。
  private static func lowerBound(_ xs: [Float], _ value: Float) -> Int {
    var low = 0
    var high = xs.count
    while low < high {
      let mid = (low + high) / 2
      if xs[mid] < value { low = mid + 1 } else { high = mid }
    }
    return low
  }

  static func scissor(x: Double, y: Double, width: Double? = nil, _ g: Geometry) -> MTLScissorRect {
    let left = Int(min(max(0, x), g.width))
    let top = Int(min(max(0, y), g.height))
    let right = Int(min(max(Double(left), width.map { x + $0 } ?? g.width), g.width))
    return MTLScissorRect(
      x: left, y: top, width: max(0, right - left), height: max(0, Int(g.height) - top))
  }
}

/// グリフを置く層（本文の切り取りか、行番号の列の切り取りか）。
enum FrameBuilderLayer {
  case text, gutter
}
