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

/// 1 コマの中身を組み立てる（描画スレッドだけ。配列は面ごとに使い回す）。下から順に、選択の地・未確定の文字の地 → 本文の字
/// と長い行の「ほか N 字」（行番号の列の右だけ）→ 色付きの字（絵文字など）→ 行番号 → git の印 → 未確定の文字の下線・
/// キャレット・落とす位置の印。地は描かない（透明に消し、下の地を透かす）。
///
/// 行の位置は y = 上端の余白 + 行 × 行高で、折り返さない。見えている行だけその場で組版し（キャッシュする）、字の色は
/// 行ごとに、横に見えている字の区間の役割を役割の並びから引いて決める（長い行でも行全体の役割は引かない）。スクロール量
/// は装置の画素に揃える（字がにじまない）。
final class FrameBuilder {
  private(set) var text: [[GlyphInstance]] = []
  private(set) var color: [[GlyphInstance]] = []
  private(set) var gutter: [[GlyphInstance]] = []
  var shapes: [ShapeInstance] = []
  /// 選択の地（本文の字の下。本文の列に切り取る）。
  var underShapes: [ShapeInstance] = []
  /// キャレット（いちばん上。本文の列に切り取る）。
  var overShapes: [ShapeInstance] = []
  private(set) var textScissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
  private(set) var gutterScissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
  /// 組んだ行のうち最も長い幅（pt。末尾の「ほか N 字」を含む）。
  private(set) var longestLine: CGFloat = 0

  /// GPU の buffer に要る大きさ（配列ごとに 256 バイトに揃える）。
  var byteCount: Int {
    let glyphArrays = text + color + gutter
    let glyphs = glyphArrays.reduce(0) {
      $0 + (($1.count * MemoryLayout<GlyphInstance>.stride + 255) & ~255)
    }
    return [shapes, underShapes, overShapes].reduce(glyphs) {
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
  }

  /// 1 コマを組む元。
  struct Source {
    let material: FrameMaterial
    let position: SIMD2<Double>
    /// このコマでキャレットを描くか（点滅と焦点）。
    let caretVisible: Bool
    /// 描く先の大きさ（px）。
    let pixels: (width: Int, height: Int)
    let atlas: GlyphAtlas
    let config: SurfaceConfig
  }

  /// コマを組む（組版のキャッシュのコマは呼び手が始めてある——`Renderer.begin`）。
  func build(_ source: Source, cache: LineLayoutCache, fonts: FontRegistry) {
    for i in text.indices { text[i].removeAll(keepingCapacity: true) }
    for i in color.indices { color[i].removeAll(keepingCapacity: true) }
    for i in gutter.indices { gutter[i].removeAll(keepingCapacity: true) }
    shapes.removeAll(keepingCapacity: true)
    underShapes.removeAll(keepingCapacity: true)
    overShapes.removeAll(keepingCapacity: true)
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
    let c = Context(
      g: g, palette: palette, focused: source.material.caret.focused, atlas: source.atlas,
      config: config)
    textScissor = Self.scissor(x: g.column, y: g.top, g)
    gutterScissor = Self.scissor(x: 0, y: g.top, width: g.column, g)
    guard g.height > g.top else { return }
    let first = max(0, Int((g.scrollY / g.lineHeight).rounded(.down)))
    let last = min(
      lineCount - 1, Int(((g.scrollY + g.height - g.top) / g.lineHeight).rounded(.down)))
    guard first <= last else { return }
    let baseline = (Double(config.baseline) * s).rounded()
    let numberFont = fonts.id(config.gutterFont)
    let tabColumns = source.material.tabColumns
    var start = content.text.lineStart(first)
    var overlays = CaretOverlays(
      source.material, caretVisible: source.caretVisible, text: content.text, from: start)
    for row in first...last {
      let top = g.rowTop(row)
      let end = content.text.lineEnd(row)
      let overlay = overlays.next(row: row, line: start..<end)
      let laid = cache.line(
        row: row, in: content.text, tabColumns: tabColumns, config: config, fonts: fonts,
        carets: overlay.needsCarets)
      drawOverlays(overlay, laid, rowTop: top, c)
      let width = drawText(laid, start: start, roles: content.roles, baseline: top + baseline, c)
      longestLine = max(longestLine, width)
      drawNumber(row + 1, rowTop: top, font: numberFont, c)
      start = end
    }
    cache.endFrame()
    drawMarks(source.material.marks, rows: first...last, c)
  }

  /// 行の字を置き、行の幅（末尾の印を含む、pt）を返す。行番号の列の下に隠れる字と右端の外の字は置かず、役割も置く字の
  /// 区間だけ引く。
  private func drawText(
    _ line: LaidOutLine, start: Int, roles: RoleRuns, baseline: Double, _ c: Context
  ) -> CGFloat {
    let g = c.g
    let originX = g.column - g.scrollX
    let leftmost = Float((g.column - originX) / g.scale - Double(c.config.cell) * 4)
    let rightmost = Float((g.width - originX) / g.scale)
    let from = Self.lowerBound(line.xs, leftmost)
    var to = from
    var low = Int32.max
    var high = Int32.min
    while to < line.glyphs.count, line.xs[to] <= rightmost {
      low = min(low, line.offsets[to])
      high = max(high, line.offsets[to])
      to += 1
    }
    if from < to {
      var cursor = RoleCursor(
        spans: roles.roles(
          in: NSRange(location: start + Int(low), length: Int(high - low) + 1)))
      for i in from..<to {
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
      if x > g.width { break }
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
