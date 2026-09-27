import Metal
import OrbeEditorCore

/// 1 コマのミニマップ——字のチャンク（GPU の buffer と上端の y）・装飾（画面外の 1 枚に描いて組として不透明度 .9 で重ねる）
/// ・帯。配置は Core の `MinimapLayout`（前のコマの配置で揺れ止め）で、字は描画スレッドが覚えた列（`MinimapCells`）。
struct MinimapFrame {
  /// ミニマップの矩形（px）。
  var rect = SIMD4<Float>(0, 0, 0, 0)
  /// 字のチャンク。
  var chunks: [MinimapChunk] = []
  /// 字の描き方（シェーダの `MinimapUniforms`。上端の y はチャンクごとに入れる）。
  var uniforms = MinimapUniforms()
  /// ミニマップの倍率（字形の表の倍率。1 か 2）。
  var scale = 2
  /// 装飾（ミニマップの左上を原点にした px）。
  var decorations: [ShapeInstance] = []
  /// 描いた配置（次のコマの揺れ止めと、main の押下の解き方）。
  var placement: MinimapLayout?

  mutating func reset() {
    rect = SIMD4(0, 0, 0, 0)
    chunks.removeAll(keepingCapacity: true)
    decorations.removeAll(keepingCapacity: true)
    placement = nil
  }
}

/// 描くチャンク 1 つ——字の列の buffer・字の数・上端の y（px）。
struct MinimapChunk {
  let buffer: MTLBuffer
  let count: Int
  let top: Float
}

/// シェーダの `MinimapUniforms` と同じ並び。
struct MinimapUniforms {
  /// チャンクの左上（px）。
  var origin = SIMD2<Float>(0, 0)
  /// 字 1 つの大きさ（px）。
  var cell = SIMD2<Float>(0, 0)
  /// 字形の表の 1 字の大きさ（texel）。
  var glyph = SIMD2<Float>(0, 0)
  /// 字形の明度に掛ける明るさの係数と、全体の不透明度。
  var ratio: Float = 1
  var opacity: Float = 1
}

extension FrameBuilder {
  /// ミニマップを組む。`lines` は先頭に見えている行（小数。端を越えている間は端）と見えている行数。
  func buildMinimap(
    _ layout: SurfaceLayout, lines: (first: CGFloat, visible: CGFloat), _ source: Source,
    _ content: SurfaceContent, _ c: Context
  ) {
    let material = source.material
    let cells = source.minimapCells
    let g = c.g
    let area = layout.minimap
    let s = g.scale
    let width = (Double(area.width) * s).rounded()
    guard width > 0, area.height > 0 else { return }
    let text = content.text
    let placement = MinimapLayout(
      lineCount: text.lineCount, firstLine: lines.first, visibleLines: lines.visible,
      height: area.height, previous: source.previousPlacement)
    minimap.placement = placement
    let scale = s >= 2 ? 2 : 1
    let factor = Float(s) / Float(scale)
    minimap.scale = scale
    let x = (Double(area.minX) * s).rounded()
    minimap.rect = SIMD4(Float(x), 0, Float(width), Float(g.height))
    let canvas = Int(area.width * CGFloat(scale))
    cells.beginFrame(
      MinimapCells.Key(
        columns: MinimapLine.columns(canvasWidth: canvas, scale: scale), tabSize: c.tabColumns))
    minimap.uniforms = MinimapUniforms(
      origin: SIMD2(Float(x) + Float(MinimapLine.gutter) * factor, 0),
      cell: SIMD2(Float(scale) * factor, Float(2 * scale) * factor),
      glyph: SIMD2(Float(scale), Float(2 * scale)),
      ratio: Float(MinimapCharSheet.glyphRatio(dark: c.palette.overview.dark)),
      opacity: Float(MinimapCharSheet.opacity))
    guard !placement.lines.isEmpty else { return }
    let firstChunk = placement.lines.lowerBound / MinimapCells.lines
    let lastChunk = (placement.lines.upperBound - 1) / MinimapCells.lines
    for index in firstChunk...lastChunk {
      let chunk = cells.chunk(index, text: text, roles: content.roles)
      guard let buffer = chunk.buffer else { continue }
      let top = Double(placement.y(ofLine: index * MinimapCells.lines)) * s
      minimap.chunks.append(MinimapChunk(buffer: buffer, count: chunk.count, top: Float(top)))
    }
    var decorations = MinimapDecorations(
      placement: placement, text: text, material: material, palette: c.palette.overview,
      width: area.width, scale: CGFloat(scale), pixel: s)
    decorations.draw()
    minimap.decorations = decorations.shapes
  }
}

/// ミニマップの装飾——選択・検索の一致・語の出現・git の印（VS Code `InnerMinimap.renderDecorations`）。描く順は、選択の
/// 行の地 → 一致・語の出現の行の地 → 選択の範囲 → 語の出現・一致の範囲 → git の印。一致が多いときは現在の一致だけを
/// 出す。座標はミニマップの左上を原点にした px（組として画面外の 1 枚に描く）。
private struct MinimapDecorations {
  let placement: MinimapLayout
  let text: TextRope
  let material: FrameMaterial
  let palette: OverviewPalette
  /// ミニマップの幅（pt）と、ミニマップの倍率・装置の倍率。
  let width: CGFloat
  let scale: CGFloat
  let pixel: Double
  private var columns: DecorationColumns
  /// 組んだ図形。
  private(set) var shapes: [ShapeInstance] = []

  /// 一致・語の出現の 1 種類——区間と、範囲の色と行の薄い地の色。
  private struct Inline {
    let ranges: [NSRange]
    let color: FrameColor
    let row: FrameColor
  }

  init(
    placement: MinimapLayout, text: TextRope, material: FrameMaterial, palette: OverviewPalette,
    width: CGFloat, scale: CGFloat, pixel: Double
  ) {
    self.placement = placement
    self.text = text
    self.material = material
    self.palette = palette
    self.width = width
    self.scale = scale
    self.pixel = pixel
    columns = DecorationColumns(
      text: text, tabSize: material.tabColumns, gutter: CGFloat(MinimapLine.gutter) / scale,
      width: width)
  }

  mutating func draw() {
    let gutter = columns.gutter
    let caret = material.caret
    let selections =
      caret.selections.isEmpty
      ? caret.carets.prefix(1).map { NSRange(location: $0, length: 0) } : caret.selections
    var highlighted = Set<Int>()
    for selection in selections {
      let rows = rows(of: selection)
      highlighted.formUnion(Range(rows).clamped(to: placement.lines))
      guard rows.count > 1 else { continue }
      let top = placement.y(ofLine: rows.lowerBound)
      let bottom = placement.y(ofLine: rows.upperBound)
      fill(
        x: gutter, y: top, width: width - gutter, height: bottom - top, palette.minimapSelectionRow)
    }
    let highlights = material.highlights
    let crowded = highlights.crowded
    let inline = [
      Inline(
        ranges: crowded ? Array(highlights.current.prefix(1)) : [], color: palette.minimapFind,
        row: palette.minimapFindRow),
      Inline(
        ranges: crowded ? [] : highlights.find, color: palette.minimapFind,
        row: palette.minimapFindRow),
      Inline(ranges: highlights.word, color: palette.minimapWord, row: palette.minimapWordRow),
    ]
    for item in inline {
      for range in visible(item.ranges) {
        for row in Range(rows(of: range)).clamped(to: placement.lines) {
          guard highlighted.insert(row).inserted else { continue }
          fill(
            x: gutter, y: placement.y(ofLine: row), width: width - gutter,
            height: MinimapLayout.lineHeight, item.row)
        }
      }
    }
    for selection in selections { fillRanges([selection], palette.minimapSelection) }
    for item in inline.reversed() { fillRanges(visible(item.ranges), item.color) }
    drawGitMarks()
  }

  /// 区間の行（開始の行から終わりの位置の行まで。VS Code は範囲の終わりの行を含める——行を丸ごと選べば次の行まで）。
  private func rows(of range: NSRange) -> ClosedRange<Int> {
    let first = text.row(containing: range.location)
    return first...max(first, text.row(containing: NSMaxRange(range)))
  }

  /// 描く行に掛かる区間だけ（昇順の列を二分探索で切る）。
  private func visible(_ ranges: [NSRange]) -> ArraySlice<NSRange> {
    guard !ranges.isEmpty, !placement.lines.isEmpty else { return [] }
    let start = text.lineStart(placement.lines.lowerBound)
    let end = text.lineEnd(placement.lines.upperBound - 1)
    var low = 0
    var high = ranges.count
    while low < high {
      let mid = (low + high) / 2
      if NSMaxRange(ranges[mid]) > start
        || (ranges[mid].length == 0 && ranges[mid].location >= start)
      {
        high = mid
      } else {
        low = mid + 1
      }
    }
    var upper = low
    while upper < ranges.count, ranges[upper].location <= end { upper += 1 }
    return ranges[low..<upper]
  }

  /// 区間を行ごとに x（装飾の桁。タブは固定の桁数）で塗る。区間の終わりの行より前の行は行末（本文の終わり）まで
  /// （VS Code `renderDecorationOnLine`）。
  private mutating func fillRanges(_ ranges: some Collection<NSRange>, _ color: FrameColor) {
    for range in ranges where range.length > 0 {
      let rows = rows(of: range)
      for row in Range(rows).clamped(to: placement.lines) {
        let start = text.lineStart(row)
        let end = row == rows.upperBound ? NSMaxRange(range) - start : columns.length(row: row)
        let x1 = columns.x(row: row, at: max(range.location, start) - start)
        let x2 = columns.x(row: row, at: end)
        fill(
          x: x1, y: placement.y(ofLine: row), width: max(0, x2 - x1),
          height: MinimapLayout.lineHeight, color)
      }
    }
  }

  /// git の印（x = 2 デバイス px、幅 2 デバイス px、1 行ぶんの高さ）。削除はその境の上の行に出る。
  private mutating func drawGitMarks() {
    let x = 2 / scale
    let width = 2 / scale
    let marks = material.marks
    for bar in marks.bars {
      let color = bar.kind == .added ? palette.minimapAdded : palette.minimapModified
      for row in Range(bar.rows).clamped(to: placement.lines) {
        fill(
          x: x, y: placement.y(ofLine: row), width: width, height: MinimapLayout.lineHeight, color)
      }
    }
    for deletion in marks.deletions {
      let row = max(0, deletion.row + (deletion.atBottom ? 1 : 0) - 1)
      guard placement.lines.contains(row) else { continue }
      fill(
        x: x, y: placement.y(ofLine: row), width: width, height: MinimapLayout.lineHeight,
        palette.minimapRemoved)
    }
  }

  /// pt の矩形を px にして塗る。
  private mutating func fill(
    x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, _ color: FrameColor
  ) {
    guard width > 0, height > 0 else { return }
    let left = (Double(x) * pixel).rounded()
    let top = (Double(y) * pixel).rounded()
    let right = (Double(x + width) * pixel).rounded()
    let bottom = (Double(y + height) * pixel).rounded()
    guard right > left, bottom > top else { return }
    shapes.append(
      ShapeInstance(
        rect: SIMD4(Float(left), Float(top), Float(right - left), Float(bottom - top)),
        color: color.packed, radius: 0, kind: 0))
  }
}

/// 1 コマの中で、行ごとの「UTF-16 位置 → 装飾の x（pt）」を 1 度だけ作って共有する（VS Code の `lineOffsetMap`）。読むのは
/// 行の本文（改行を除く）のうち、ミニマップの幅に入る桁までの頭だけ。
private struct DecorationColumns {
  let text: TextRope
  let tabSize: Int
  let gutter: CGFloat
  let width: CGFloat
  private var offsets: [Int: [CGFloat]] = [:]

  init(text: TextRope, tabSize: Int, gutter: CGFloat, width: CGFloat) {
    self.text = text
    self.tabSize = tabSize
    self.gutter = gutter
    self.width = width
  }

  /// 行 `row` の本文の長さ（UTF-16、改行を除く）。
  func length(row: Int) -> Int {
    let start = text.lineStart(row)
    let end = text.lineEnd(row)
    let tail = text.units(
      in: NSRange(location: max(start, end - 2), length: end - max(start, end - 2)))
    return end - start - tail.reversed().prefix { $0 == 0x0A || $0 == 0x0D }.count
  }

  /// 行 `row` の UTF-16 位置 `index` の x（ミニマップの幅で止まる）。行の本文の終わりより右は本文の終わり。
  mutating func x(row: Int, at index: Int) -> CGFloat {
    guard index > 0 else { return gutter }
    guard gutter + CGFloat(index) < width else { return width }
    let line = offsets[row] ?? read(row)
    return index < line.count ? line[index] : line[line.count - 1]
  }

  private mutating func read(_ row: Int) -> [CGFloat] {
    let start = text.lineStart(row)
    let limit = max(0, Int(width - gutter))
    let length = min(text.lineEnd(row) - start, limit + 2)
    var units = text.units(in: NSRange(location: start, length: length))
    if units.count < limit + 2 {
      if units.last == 0x0A { units.removeLast() }
      if units.last == 0x0D { units.removeLast() }
    }
    let line = MinimapLine.decorationColumns(
      units.prefix(limit + 1), tabSize: tabSize, limit: limit
    ).map { gutter + CGFloat($0) }
    offsets[row] = line
    return line
  }
}
