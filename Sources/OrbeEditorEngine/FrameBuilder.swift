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

/// 1 コマの中身を組み立てる（描画スレッドだけ。配列は面ごとに使い回す）。下から順に、本文の字（行番号の列の右だけ）→
/// 行番号 → git の印 → 長い行の「ほか N 字」。地は描かない（透明に消し、下の地を透かす）。
///
/// 行の位置は y = 上端の余白 + 行 × 行高で、折り返さない。見えている行だけその場で組版し（キャッシュする）、字の色は
/// 行ごとに役割の並びから区間の役割を引いて決める。スクロール量は装置の画素に揃える（字がにじまない）。
final class FrameBuilder {
  private(set) var text: [[GlyphInstance]] = []
  private(set) var color: [[GlyphInstance]] = []
  private(set) var gutter: [[GlyphInstance]] = []
  var shapes: [ShapeInstance] = []
  private(set) var textScissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
  private(set) var gutterScissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
  /// 組んだ行のうち最も長い幅（pt。末尾の「ほか N 字」を含む）。
  private(set) var longestLine: CGFloat = 0

  /// 描いた字の数（計測・テストが見る）。
  var glyphCount: Int { (text + color + gutter).reduce(0) { $0 + $1.count } }

  /// GPU の buffer に要る大きさ（配列ごとに 256 バイトに揃える）。
  var byteCount: Int {
    let glyphArrays = text + color + gutter
    let glyphs = glyphArrays.reduce(0) {
      $0 + (($1.count * MemoryLayout<GlyphInstance>.stride + 255) & ~255)
    }
    return glyphs + ((shapes.count * MemoryLayout<ShapeInstance>.stride + 255) & ~255)
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

    /// 行の上端の y。
    func rowTop(_ row: Int) -> Double { top + (Double(row) * lineHeight).rounded() - scrollY }
  }

  /// 1 コマの間だけ使う、描く先の座標系と色・アトラス・見え方。
  struct Context {
    let g: Geometry
    let palette: FramePalette
    let atlas: GlyphAtlas
    let config: SurfaceConfig
  }

  /// 1 コマを組む元。
  struct Source {
    let material: FrameMaterial
    let position: SIMD2<Double>
    /// 描く先の大きさ（px）。
    let pixels: (width: Int, height: Int)
    let atlas: GlyphAtlas
    let config: SurfaceConfig
  }

  func build(_ source: Source, cache: LineLayoutCache, fonts: FontRegistry) {
    for i in text.indices { text[i].removeAll(keepingCapacity: true) }
    for i in color.indices { color[i].removeAll(keepingCapacity: true) }
    for i in gutter.indices { gutter[i].removeAll(keepingCapacity: true) }
    shapes.removeAll(keepingCapacity: true)
    longestLine = 0
    let config = source.config
    guard let content = source.material.content, let palette = source.material.palette else {
      return
    }
    let s = Double(source.material.scale)
    let lineCount = content.text.lineCount
    let g = Geometry(
      scale: s, width: Double(source.pixels.width), height: Double(source.pixels.height),
      scrollX: (source.position.x * s).rounded(), scrollY: (source.position.y * s).rounded(),
      top: (Double(config.topInset) * s).rounded(), lineHeight: Double(config.lineHeight) * s,
      column: (Double(config.columnWidth(lineCount: lineCount)) * s).rounded())
    let c = Context(g: g, palette: palette, atlas: source.atlas, config: config)
    textScissor = Self.scissor(x: g.column, y: g.top, g)
    gutterScissor = Self.scissor(x: 0, y: g.top, width: g.column, g)
    guard g.height > g.top else { return }
    let first = max(0, Int((g.scrollY / g.lineHeight).rounded(.down)))
    let last = min(
      lineCount - 1, Int(((g.scrollY + g.height - g.top) / g.lineHeight).rounded(.down)))
    guard first <= last else { return }
    let baseline = (Double(config.baseline) * s).rounded()
    let numberFont = fonts.id(config.gutterFont)
    for row in first...last {
      let top = g.rowTop(row)
      let (line, start) = LineShaper.source(row: row, in: content.text)
      let laid = cache.line(
        line, tabColumns: source.material.tabColumns, config: config, fonts: fonts)
      let spans = content.roles.roles(
        in: NSRange(location: start, length: line.length - laid.omitted))
      let width = drawText(laid, start: start, spans: spans, baseline: top + baseline, c)
      longestLine = max(longestLine, width)
      drawNumber(row + 1, rowTop: top, font: numberFont, c)
    }
    drawMarks(source.material.marks, rows: first...last, c)
  }

  /// 行の字を置き、行の幅（末尾の印を含む、pt）を返す。行番号の列の下に隠れる字と右端の外の字は置かない。
  private func drawText(
    _ line: LaidOutLine, start: Int, spans: [HighlightSpan], baseline: Double, _ c: Context
  ) -> CGFloat {
    let g = c.g
    let originX = g.column - g.scrollX
    let leftmost = Float((g.column - originX) / g.scale - Double(c.config.cell) * 4)
    var cursor = RoleCursor(spans: spans)
    var i = Self.lowerBound(line.xs, leftmost)
    while i < line.glyphs.count {
      let x = originX + Double(line.xs[i]) * g.scale
      if x > g.width { break }
      let role = cursor.role(at: start + Int(line.offsets[i]))
      let ink = role.flatMap { c.palette.roles[$0] } ?? c.palette.text
      place(
        Glyph(font: line.fonts[i], glyph: line.glyphs[i], x: x, baseline: baseline), ink, .text, c)
      i += 1
    }
    guard let mark = line.omittedMark else { return line.width }
    let markX = originX + Double(line.width + c.config.cell) * g.scale
    for j in mark.glyphs.indices {
      let x = markX + Double(mark.xs[j]) * g.scale
      if x > g.width { break }
      place(
        Glyph(font: mark.fonts[j], glyph: mark.glyphs[j], x: x, baseline: baseline),
        c.palette.gutterText, .text, c)
    }
    return line.width + c.config.cell + mark.width
  }

  /// 置くグリフ 1 つ（x・基線は px）。
  struct Glyph {
    let font: UInt16
    let glyph: CGGlyph
    let x: Double
    let baseline: Double
  }

  /// グリフを置く。横の位置は Core Text と同じく切り捨てで量子化する（誤差で境目を跨がないよう僅かに足す）。
  func place(_ item: Glyph, _ ink: FrameColor, _ layer: FrameBuilderLayer, _ c: Context) {
    let variants = Double(c.atlas.variants)
    let quantized = (item.x * variants + 1e-3).rounded(.down)
    let whole = (quantized / variants).rounded(.down)
    let variant = Int(quantized - whole * variants)
    guard
      let entry = c.atlas.entry(
        font: item.font, glyph: item.glyph, variant: variant, dilation: ink.dilation)
    else { return }
    let instance = GlyphInstance(
      position: SIMD2(Float(whole) + Float(entry.left), Float(item.baseline) - Float(entry.top)),
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

/// 昇順の役割の区間を、増えていくオフセットで引く（戻れば二分探索で引き直す）。
private struct RoleCursor {
  let spans: [HighlightSpan]
  var index = 0

  init(spans: [HighlightSpan]) {
    self.spans = spans
  }

  mutating func role(at offset: Int) -> SyntaxRole? {
    guard !spans.isEmpty else { return nil }
    if index < spans.count, offset < spans[index].range.location, index > 0 {
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
