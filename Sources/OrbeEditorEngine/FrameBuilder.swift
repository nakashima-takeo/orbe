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
/// 行の位置は y = 上端の余白 + 行 × 行高で、折り返さない。見えている行だけその場で組版し（キャッシュする）、字の色は
/// 行ごとに、横に見えている字の区間の役割を役割の並びから引いて決める（長い行でも行全体の役割は引かない）。スクロール量
/// は装置の画素に揃える（字がにじまない）。
final class FrameBuilder {
  private(set) var text: [[GlyphInstance]] = []
  private(set) var color: [[GlyphInstance]] = []
  private(set) var gutter: [[GlyphInstance]] = []
  var shapes: [ShapeInstance] = []
  /// 行の装備（インデント線・空白の丸点・URL の下線。本文の列に切り取る）。
  var decorShapes: [ShapeInstance] = []
  /// 選択の地と未確定の文字の地（本文の列に切り取る）。
  var underShapes: [ShapeInstance] = []
  /// 強調の地（本文の列に切り取る）。
  var highlightShapes: [ShapeInstance] = []
  /// 未確定の文字の下線・キャレット・落とす位置の印（本文の列に切り取る）。
  var overShapes: [ShapeInstance] = []
  private(set) var textScissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
  private(set) var gutterScissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
  /// 組んだ行のうち最も長い幅（pt。末尾の「ほか N 字」を含む）。
  private(set) var longestLine: CGFloat = 0
  /// このコマのミニマップ。
  var minimap = MinimapFrame()
  /// 影（上端・ミニマップの左）と、俯瞰の図形（ミニマップの帯・縦横のスクロールバーと印）。
  var shadowShapes: [ShapeInstance] = []
  var overviewShapes: [ShapeInstance] = []
  /// スクロールバーの印の縦の区間（元が変わったときだけ作り直す）。
  var rulerSpans = RulerSpans()

  /// GPU の buffer に要る大きさ（配列ごとに 256 バイトに揃える）。
  var byteCount: Int {
    let glyphArrays = text + color + gutter
    let glyphs = glyphArrays.reduce(0) {
      $0 + (($1.count * MemoryLayout<GlyphInstance>.stride + 255) & ~255)
    }
    return [
      shapes, decorShapes, underShapes, highlightShapes, overShapes, minimap.decorations,
      shadowShapes, overviewShapes,
    ]
    .reduce(glyphs + ((MemoryLayout<GlyphInstance>.stride + 255) & ~255)) {
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

    /// 行の上端の y。
    func rowTop(_ row: Int) -> Double { top + (Double(row) * lineHeight).rounded() - scrollY }
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
    /// 前のコマのミニマップの配置（揺れ止め）。
    let previousPlacement: MinimapLayout?
  }

  /// コマを組む（組版のキャッシュのコマは呼び手が始めてある——`Renderer.begin`）。
  func build(_ source: Source, cache: LineLayoutCache, fonts: FontRegistry) {
    for i in text.indices { text[i].removeAll(keepingCapacity: true) }
    for i in color.indices { color[i].removeAll(keepingCapacity: true) }
    for i in gutter.indices { gutter[i].removeAll(keepingCapacity: true) }
    shapes.removeAll(keepingCapacity: true)
    decorShapes.removeAll(keepingCapacity: true)
    underShapes.removeAll(keepingCapacity: true)
    highlightShapes.removeAll(keepingCapacity: true)
    shadowShapes.removeAll(keepingCapacity: true)
    overviewShapes.removeAll(keepingCapacity: true)
    overShapes.removeAll(keepingCapacity: true)
    longestLine = 0
    minimap.reset()
    let config = source.config
    guard let content = source.material.content, let palette = source.material.palette else {
      return
    }
    let s = Double(source.material.scale)
    let lineCount = content.text.lineCount
    let layout = config.layout(size: source.material.size, lineCount: lineCount)
    let g = Geometry(
      scale: s, width: Double(source.pixels.width), height: Double(source.pixels.height),
      scrollX: (source.position.x * s).rounded(), scrollY: (source.position.y * s).rounded(),
      top: (Double(config.topInset) * s).rounded(), lineHeight: Double(config.lineHeight) * s,
      column: (Double(layout.column) * s).rounded(),
      textRight: (Double(layout.text.maxX) * s).rounded())
    let tabColumns = source.material.tabColumns
    let c = Context(
      g: g, palette: palette, focused: source.material.caret.focused, atlas: source.atlas,
      config: config, tabColumns: tabColumns, roles: content.roles)
    textScissor = Self.scissor(x: g.column, y: g.top, width: g.textRight - g.column, g)
    gutterScissor = Self.scissor(x: 0, y: g.top, width: g.column, g)
    let lines = Self.viewportLines(source, lineCount: lineCount, config: config)
    buildMinimap(layout, lines: lines, source, content, c)
    drawShadows(layout, lines: lines, clipsRight: Self.clipsRight(source), c)
    drawVerticalScrollbar(layout, lines: lines, source, content, c)
    drawSliders(layout, lines: lines, source, lineCount: lineCount, c)
    guard g.height > g.top else { return }
    let first = max(0, Int((g.scrollY / g.lineHeight).rounded(.down)))
    let last = min(
      lineCount - 1, Int(((g.scrollY + g.height - g.top) / g.lineHeight).rounded(.down)))
    guard first <= last else { return }
    let baseline = (Double(config.baseline) * s).rounded()
    let numberFont = fonts.id(config.gutterFont)
    let rows = layRows(first...last, source, text: content.text, cache: cache, fonts: fonts)
    let levels = Self.indentLevels(
      rows.map(\.laid), first: first, text: content.text, unit: tabColumns)
    for (index, item) in rows.enumerated() {
      let top = g.rowTop(item.row)
      let visible = visibleGlyphs(item.laid, c)
      drawDecor(item, level: levels[index], rowTop: top, window: visible.offsets, c)
      drawOverlays(item.overlay, item.laid, rowTop: top, c)
      drawHighlights(item, source.material.highlights, rowTop: top, window: visible.offsets, c)
      let width = drawText(item.laid, visible, start: item.start, baseline: top + baseline, c)
      longestLine = max(longestLine, width)
      drawNumber(item.row + 1, rowTop: top, font: numberFont, c)
    }
    drawMarks(source.material.marks, rows: first...last, c)
  }

  /// 見えている行を組む（組版のキャッシュのコマはここで終える）。
  private func layRows(
    _ rows: ClosedRange<Int>, _ source: Source, text: TextRope, cache: LineLayoutCache,
    fonts: FontRegistry
  ) -> [RowInFrame] {
    var result: [RowInFrame] = []
    var start = text.lineStart(rows.lowerBound)
    var overlays = CaretOverlays(
      source.material, caretVisible: source.caretVisible, text: text, from: start)
    let highlights = source.material.highlights
    for row in rows {
      let end = text.lineEnd(row)
      let overlay = overlays.next(row: row, line: start..<end)
      let highlighted = highlights.touches(start..<max(end, start + 1))
      let laid = cache.line(
        row: row, in: text, tabColumns: source.material.tabColumns, config: source.config,
        fonts: fonts, carets: overlay.needsCarets || highlighted, decor: true)
      result.append(
        RowInFrame(
          row: row, start: start, end: end,
          contentEnd: highlighted ? NSMaxRange(text.contentRange(ofRow: row)) : end, laid: laid,
          overlay: overlay))
      start = end
    }
    cache.endFrame()
    return result
  }

  /// 先頭に見えている行（小数。行 + 隠れている割合）と見えている行数——見えている範囲の通知と同じ意味の値で、端を越えて
  /// 見せている間は端で数える（俯瞰は端の位置を表す）。
  static func viewportLines(_ source: Source, lineCount: Int, config: SurfaceConfig) -> (
    first: CGFloat, visible: CGFloat
  ) {
    let limits = source.limits
    let lineHeight = Double(config.lineHeight)
    let y = min(max(0, source.position.y), limits.maximum.y)
    let row = min(Int((y / lineHeight).rounded(.down)), max(0, lineCount - 1))
    let hidden = min(max((y - Double(row) * lineHeight) / lineHeight, 0), 1)
    return (CGFloat(Double(row) + hidden), CGFloat(limits.viewport.y / lineHeight))
  }

  /// 本文が右にまだ続く（横に隠れている部分がある）か——見えている範囲の通知と同じ判定。
  static func clipsRight(_ source: Source) -> Bool {
    let maximum = source.limits.maximum.x
    return min(max(0, source.position.x), maximum) < maximum - 0.5 / Double(source.material.scale)
  }

  /// このコマで描く行 1 つ。
  struct RowInFrame {
    let row: Int
    /// 行頭・次の行頭・行の中身の終わり（改行と行末の `\r` の前。強調の地の掛かる行だけ）のオフセット。
    let start: Int
    let end: Int
    let contentEnd: Int
    let laid: LaidOutLine
    let overlay: RowOverlays
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

  /// 行の字を置き、行の幅（末尾の印を含む、pt）を返す。置くのは横に見えている字だけで、役割もその字の区間だけ引く。
  private func drawText(
    _ line: LaidOutLine, _ visible: VisibleGlyphs, start: Int, baseline: Double, _ c: Context
  ) -> CGFloat {
    let g = c.g
    let originX = g.column - g.scrollX
    if let offsets = visible.offsets {
      var cursor = RoleCursor(
        spans: c.roles.roles(
          in: NSRange(
            location: start + offsets.lowerBound, length: offsets.count)))
      for i in visible.glyphs {
        let role = cursor.role(at: start + Int(line.offsets[i]))
        let ink = role.flatMap { c.palette.roles[$0] } ?? c.palette.text
        let x = originX + Double(line.xs[i]) * g.scale
        let y = line.ys.isEmpty ? baseline : baseline - Double(line.ys[i]) * g.scale
        let glyph = Glyph(font: line.fonts[i], glyph: line.glyphs[i], x: x, baseline: y)
        place(glyph, ink, .text, c)
      }
    }
    guard let mark = line.omittedMark else { return line.width }
    let markX = originX + Double(line.width + c.config.cell) * g.scale
    for j in mark.glyphs.indices {
      let x = markX + Double(mark.xs[j]) * g.scale
      if x > g.textRight { break }
      place(
        Glyph(font: mark.fonts[j], glyph: mark.glyphs[j], x: x, baseline: baseline),
        c.palette.gutterText, .text, c)
    }
    return line.width + c.config.cell + mark.width
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
  func place(_ item: Glyph, _ ink: FrameColor, _ layer: FrameBuilderLayer, _ c: Context) {
    guard
      let (entry, pen) = c.atlas.glyph(
        font: item.font, glyph: item.glyph, x: item.x, dilation: ink.dilation)
    else { return }
    let instance = GlyphInstance(
      position: SIMD2(
        Float(pen) + Float(entry.left), Float(item.baseline.rounded(.up)) - Float(entry.top)),
      size: SIMD2(Float(entry.w), Float(entry.h)), uv: SIMD2(Float(entry.u), Float(entry.v)),
      color: entry.isColor ? 0xFFFF_FFFF : ink.packed)
    let page = Int(entry.page)
    if entry.isColor {
      Self.append(instance, to: &color, page: page)
    } else if layer == .gutter {
      Self.append(instance, to: &gutter, page: page)
    } else {
      Self.append(instance, to: &text, page: page)
    }
  }

  private static func append(
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

/// 昇順の役割の区間を、おおむね増えていくオフセットで引く（右から左の字の塊の中のように、前の区間の終わりより前へ戻れば
/// 二分探索で引き直す）。
struct RoleCursor {
  private let spans: [HighlightSpan]
  private var index = 0

  init(spans: [HighlightSpan]) {
    self.spans = spans
  }

  mutating func role(at offset: Int) -> SyntaxRole? {
    guard !spans.isEmpty else { return nil }
    if index > 0, offset < NSMaxRange(spans[index - 1].range) {
      var low = 0
      var high = spans.count
      while low < high {
        let mid = (low + high) / 2
        if NSMaxRange(spans[mid].range) <= offset { low = mid + 1 } else { high = mid }
      }
      index = low
    }
    while index < spans.count, NSMaxRange(spans[index].range) <= offset { index += 1 }
    guard index < spans.count, spans[index].range.location <= offset else { return nil }
    return spans[index].role
  }
}
