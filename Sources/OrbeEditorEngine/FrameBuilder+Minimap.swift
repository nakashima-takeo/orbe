import Foundation
import OrbeEditorCore

/// 1 コマのミニマップ——字のチャンク（字の列と上端の y）・装飾（画面外の 1 枚に描いて組として不透明度 .9 で重ねる）
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

/// 描くチャンク 1 つ——字の列と上端の y（px）。
struct MinimapChunk {
  let cells: [MinimapCellInstance]
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
    let columns = MinimapLine.columns(canvasWidth: canvas, scale: scale)
    let gutter = CGFloat(MinimapLine.gutter) / CGFloat(scale)
    let limit = max(0, Int(area.width - gutter))
    cells.beginFrame(
      MinimapCells.Key(columns: columns, heads: max(columns, limit) + 2, tabSize: c.tabColumns))
    minimap.uniforms = MinimapUniforms(
      origin: SIMD2(Float(x) + Float(MinimapLine.gutter) * factor, 0),
      cell: SIMD2(Float(scale) * factor, Float(2 * scale) * factor),
      glyph: SIMD2(Float(scale), Float(2 * scale)),
      ratio: Float(MinimapCharSheet.glyphRatio(dark: c.palette.overview.dark)),
      opacity: Float(MinimapCharSheet.opacity))
    guard !placement.lines.isEmpty else { return }
    let firstChunk = placement.lines.lowerBound / MinimapCells.lines
    let lastChunk = (placement.lines.upperBound - 1) / MinimapCells.lines
    let chunks = (firstChunk...lastChunk).map { index in
      let chunk = cells.chunk(index, text: text, roles: content.roles)
      if !chunk.cells.isEmpty {
        let top = Double(placement.y(ofLine: index * MinimapCells.lines)) * s
        minimap.chunks.append(MinimapChunk(cells: chunk.cells, top: Float(top)))
      }
      return MinimapRows.Piece(
        heads: chunk.heads,
        shift: text.lineStart(index * MinimapCells.lines) - chunk.heads.starts[0])
    }
    var decorations = MinimapDecorations(
      placement: placement, material: material, palette: c.palette.overview,
      rows: MinimapRows(
        text: text, chunks: chunks, first: firstChunk * MinimapCells.lines,
        tabSize: c.tabColumns, gutter: gutter, limit: limit),
      width: area.width, scale: CGFloat(scale), pixel: s)
    decorations.draw()
    minimap.decorations = decorations.shapes
  }
}

/// ミニマップの装飾——選択・検索の一致・語の出現・git の印（VS Code `InnerMinimap.renderDecorations`）。描く順は、選択の
/// 行の地 → 一致・語の出現の行の地 → 選択の範囲 → 語の出現・一致の範囲 → git の印。一致が多いときは現在の一致だけを
/// 出す。座標はミニマップの左上を原点にした px（組として画面外の 1 枚に描く）。区間の行と x は、覚えたチャンクの行の頭
/// （`MinimapRows`）から引く。
private struct MinimapDecorations {
  let placement: MinimapLayout
  let material: FrameMaterial
  let palette: OverviewPalette
  /// 描く行の頭と、ミニマップの幅（pt）・ミニマップの倍率・装置の倍率。
  let rows: MinimapRows
  let width: CGFloat
  let scale: CGFloat
  let pixel: Double
  /// 組んだ図形。
  private(set) var shapes: [ShapeInstance] = []

  /// 一致・語の出現の 1 種類——区間と、範囲の色と行の薄い地の色。
  private struct Inline {
    let ranges: [NSRange]
    let color: FrameColor
    let row: FrameColor
  }

  mutating func draw() {
    let gutter = rows.gutter
    let caret = material.caret
    let selections =
      caret.selections.isEmpty
      ? caret.carets.prefix(1).map { NSRange(location: $0, length: 0) } : caret.selections
    var highlighted = [Bool](repeating: false, count: placement.lines.count)
    let first = placement.lines.lowerBound
    for selection in selections {
      let span = rows.rows(of: selection)
      for row in Range(span).clamped(to: placement.lines) { highlighted[row - first] = true }
      guard span.count > 1 else { continue }
      let top = placement.y(ofLine: span.lowerBound)
      let bottom = placement.y(ofLine: span.upperBound)
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
      for range in rows.visible(item.ranges, lines: placement.lines) {
        for row in Range(rows.rows(of: range)).clamped(to: placement.lines)
        where !highlighted[row - first] {
          highlighted[row - first] = true
          fill(
            x: gutter, y: placement.y(ofLine: row), width: width - gutter,
            height: MinimapLayout.lineHeight, item.row)
        }
      }
    }
    for selection in selections { fillRanges([selection], palette.minimapSelection) }
    for item in inline.reversed() {
      fillRanges(rows.visible(item.ranges, lines: placement.lines), item.color)
    }
    drawGitMarks()
  }

  /// 区間を行ごとに x（装飾の桁。タブは固定の桁数）で塗る。区間の終わりの行より前の行は行末（本文の終わり）まで
  /// （VS Code `renderDecorationOnLine`）。
  private mutating func fillRanges(_ ranges: some Collection<NSRange>, _ color: FrameColor) {
    for range in ranges where range.length > 0 {
      let span = rows.rows(of: range)
      for row in Range(span).clamped(to: placement.lines) {
        let start = rows.lineStart(row)
        let end = row == span.upperBound ? NSMaxRange(range) - start : rows.length(row: row)
        let x1 = rows.x(row: row, at: max(range.location, start) - start, width: width)
        let x2 = rows.x(row: row, at: end, width: width)
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

/// ミニマップに描くチャンクの行の頭（`MinimapCells`）——装飾の区間の行と、行の中の位置の x（pt。VS Code の
/// `lineOffsetMap`）をここから引く（チャンクの外の位置だけロープを引く）。覚えたまとまりは、前の行で字の数が変わる編集の
/// 後も中身は正しいが、行頭のオフセットは作った版のままなので、今の本文のまとまりの頭へずらして読む。
private struct MinimapRows {
  /// まとまり 1 つ——行の頭と、覚えた行頭を今の本文の行頭へずらす量。
  struct Piece {
    let heads: LineHeads
    let shift: Int

    /// `index` 番目の行の、今の本文での行頭（`index` が行の数なら最後の行の終わり）。
    func start(_ index: Int) -> Int { heads.starts[index] + shift }
  }

  let text: TextRope
  /// 続くまとまりと、最初の行。
  let chunks: [Piece]
  let first: Int
  let tabSize: Int
  /// 字の左のガター（pt）と、描ける桁の数（x はここで止まる。行の頭はこれより 2 単位以上長く読んである）。
  let gutter: CGFloat
  let limit: Int

  private func locate(_ row: Int) -> (piece: Piece, index: Int) {
    let local = row - first
    return (chunks[local / MinimapCells.lines], local % MinimapCells.lines)
  }

  /// オフセット `offset` を含む行（`TextRope.row(containing:)` と同じ答え）。
  func row(containing offset: Int) -> Int {
    guard let head = chunks.first, let tail = chunks.last, offset >= head.start(0),
      offset < tail.start(tail.heads.starts.count - 1)
    else { return text.row(containing: offset) }
    var chunk = 0
    var high = chunks.count - 1
    while chunk < high {
      let mid = (chunk + high + 1) / 2
      if chunks[mid].start(0) <= offset { chunk = mid } else { high = mid - 1 }
    }
    let piece = chunks[chunk]
    var low = 0
    high = piece.heads.starts.count - 2
    while low < high {
      let mid = (low + high + 1) / 2
      if piece.start(mid) <= offset { low = mid } else { high = mid - 1 }
    }
    return first + chunk * MinimapCells.lines + low
  }

  /// 区間の行（開始の行から終わりの位置の行まで。VS Code は範囲の終わりの行を含める——行を丸ごと選べば次の行まで）。
  func rows(of range: NSRange) -> ClosedRange<Int> {
    let first = row(containing: range.location)
    return first...max(first, row(containing: NSMaxRange(range)))
  }

  /// 行 `row` の行頭のオフセット。
  func lineStart(_ row: Int) -> Int {
    let (piece, index) = locate(row)
    return piece.start(index)
  }

  /// 行 `row` の本文の長さ（UTF-16、改行を除く）。頭が行の終わりに届かない長い行は頭の長さ——描ける桁を越えるので、
  /// x はどちらでも幅で止まる。
  func length(row: Int) -> Int {
    let (piece, index) = locate(row)
    var head = piece.heads.head(index)
    guard piece.heads.isComplete(index) else { return head.count }
    if head.last == 0x0A { head = head.dropLast() }
    if head.last == 0x0D { head = head.dropLast() }
    return head.count
  }

  /// 昇順の列のうち、描く行 `lines` に掛かる区間（二分探索で切る）。
  func visible(_ ranges: [NSRange], lines: Range<Int>) -> ArraySlice<NSRange> {
    guard !ranges.isEmpty else { return [] }
    let start = lineStart(lines.lowerBound)
    let (piece, index) = locate(lines.upperBound - 1)
    let end = piece.start(index + 1)
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

  /// 行 `row` の UTF-16 位置 `index` の x（ミニマップの幅 `width` と描ける桁で止まる——VS Code `getXOffsetForPosition` の
  /// 打ち切り）。行の
  /// 本文の終わりより右は本文の終わり。
  func x(row: Int, at index: Int, width: CGFloat) -> CGFloat {
    guard index > 0 else { return gutter }
    guard gutter + CGFloat(index) < width else { return width }
    let (piece, line) = locate(row)
    var column = 0
    for unit in piece.heads.head(line).prefix(min(index, length(row: row))) {
      column += MinimapLine.decorationWidth(of: unit, tabSize: tabSize)
      if column >= limit { return gutter + CGFloat(limit) }
    }
    return gutter + CGFloat(column)
  }
}
