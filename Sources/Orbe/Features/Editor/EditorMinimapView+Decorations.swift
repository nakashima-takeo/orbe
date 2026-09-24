import AppKit
import OrbeEditorCore

/// ミニマップの装飾——選択・検索の一致・語の出現・git の印（VS Code `InnerMinimap.renderDecorations`）。
extension EditorMinimapView {
  /// VS Code の描く順——選択の行の地 → 一致・語の出現の行の地 → 選択の範囲 → 語の出現・一致の範囲 → git の印。一致が
  /// 多いときは現在の一致だけを出す。字と同じく全体に不透明度 .9 を掛ける（VS Code の canvas の opacity）。
  func drawDecorations(
    _ layout: MinimapLayout, document: EditorDocument, context: CGContext
  ) {
    guard !layout.lines.isEmpty else { return }
    context.saveGState()
    context.setAlpha(style.opacity)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    defer {
      context.endTransparencyLayer()
      context.restoreGState()
    }
    let index = document.lineIndex
    let columns = DecorationColumns(
      document: document, gutter: CGFloat(MinimapLine.gutter) / CGFloat(scale),
      width: bounds.width)
    let selection = document.surface.selectedRange
    let selectionRows = rows(of: selection, index: index)
    var highlighted = Set(Range(selectionRows).clamped(to: layout.lines))
    if selectionRows.count > 1 {
      style.selection.withAlphaComponent(0.5).setFill()
      let top = layout.y(ofLine: selectionRows.lowerBound)
      let bottom = layout.y(ofLine: selectionRows.upperBound)
      NSRect(
        x: columns.gutter, y: top, width: bounds.width - columns.gutter, height: bottom - top
      ).fill()
    }
    let finds = decorations.approximatesFindMatches ? [] : decorations.findMatches
    let current =
      decorations.approximatesFindMatches ? (decorations.currentFindMatch.map { [$0] } ?? []) : []
    let inline: [(ranges: [NSRange], color: NSColor)] = [
      (current, style.findMatch), (finds, style.findMatch),
      (decorations.wordOccurrences, style.wordOccurrence),
    ]
    for (ranges, color) in inline {
      color.withAlphaComponent(color.alphaComponent * 0.5).setFill()
      for range in visible(ranges, layout: layout, index: index) {
        for row in Range(rows(of: range, index: index)).clamped(to: layout.lines) {
          guard highlighted.insert(row).inserted else { continue }
          NSRect(
            x: columns.gutter, y: layout.y(ofLine: row), width: bounds.width - columns.gutter,
            height: MinimapLayout.lineHeight
          ).fill()
        }
      }
    }
    fillRanges([selection], layout: layout, columns: columns, color: style.selection)
    for (ranges, color) in inline.reversed() {
      fillRanges(
        visible(ranges, layout: layout, index: index), layout: layout, columns: columns,
        color: color)
    }
    drawGitMarks(layout, document: document)
  }

  /// 区間の行（開始の行から終わりの位置の行まで。VS Code は範囲の終わりの行を含める——行を丸ごと選べば次の行まで）。
  private func rows(of range: NSRange, index: LineIndex) -> ClosedRange<Int> {
    let first = index.point(at: range.location).row
    return first...max(first, index.point(at: NSMaxRange(range)).row)
  }

  /// 描く行に掛かる区間だけ（昇順の列を二分探索で切る）。
  private func visible(_ ranges: [NSRange], layout: MinimapLayout, index: LineIndex) -> ArraySlice<
    NSRange
  > {
    guard !ranges.isEmpty else { return [] }
    let start = index.start(ofRow: layout.lines.lowerBound)
    let end = index.end(ofRow: layout.lines.upperBound - 1)
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

  /// 区間を行ごとに x（装飾の桁。タブは固定の桁数）で塗る。
  private func fillRanges(
    _ ranges: some Collection<NSRange>, layout: MinimapLayout, columns: DecorationColumns,
    color: NSColor
  ) {
    let index = columns.document.lineIndex
    color.setFill()
    for range in ranges where range.length > 0 {
      for row in Range(rows(of: range, index: index)).clamped(to: layout.lines) {
        let start = index.start(ofRow: row)
        let x1 = columns.x(row: row, at: max(range.location, start) - start)
        let x2 = columns.x(row: row, at: NSMaxRange(range) - start)
        NSRect(
          x: x1, y: layout.y(ofLine: row), width: max(0, x2 - x1), height: MinimapLayout.lineHeight
        ).fill()
      }
    }
  }

  /// git の印（x = 2 デバイス px、幅 2 デバイス px、1 行ぶんの高さ）。削除はその境の上の行に出る。
  private func drawGitMarks(_ layout: MinimapLayout, document: EditorDocument) {
    let marks = LineMarks(hunks: document.hunks)
    let x = 2 / CGFloat(scale)
    let width = 2 / CGFloat(scale)
    func fill(_ row: Int, _ color: NSColor) {
      guard layout.lines.contains(row) else { return }
      color.setFill()
      NSRect(x: x, y: layout.y(ofLine: row), width: width, height: MinimapLayout.lineHeight).fill()
    }
    for run in marks.runs {
      let color = run.kind == .added ? style.added : style.modified
      let rows = (run.lines.lowerBound - 1)..<(run.lines.upperBound - 1)
      for row in rows.clamped(to: layout.lines) { fill(row, color) }
    }
    for boundary in marks.deletionsBelow { fill(max(0, boundary - 1), style.removed) }
  }
}

/// 1 回の描画の中で、行ごとの「UTF-16 位置 → 装飾の x」を 1 度だけ作って共有する（VS Code の `lineOffsetMap`）。読むのは
/// 行の本文（改行を除く）のうち、ミニマップの幅に入る桁までの頭だけ——長い 1 行に一致が多数乗っても、区間ごとに行全体を
/// 読み直さない。
@MainActor
private final class DecorationColumns {
  let document: EditorDocument
  let gutter: CGFloat
  let width: CGFloat
  private var offsets: [Int: [CGFloat]] = [:]

  init(document: EditorDocument, gutter: CGFloat, width: CGFloat) {
    self.document = document
    self.gutter = gutter
    self.width = width
  }

  /// 行 `row` の UTF-16 位置 `index` の x（ミニマップの幅で止まる）。行の本文の終わりより右は本文の終わり。
  func x(row: Int, at index: Int) -> CGFloat {
    guard index > 0 else { return gutter }
    guard gutter + CGFloat(index) < width else { return width }
    let line = offsets[row] ?? read(row)
    return index < line.count ? line[index] : line[line.count - 1]
  }

  private func read(_ row: Int) -> [CGFloat] {
    let index = document.lineIndex
    let start = index.start(ofRow: row)
    let limit = max(0, Int(width - gutter))
    let length = min(index.end(ofRow: row) - start, limit + 2)
    var units = Array(
      document.surface.substring(in: NSRange(location: start, length: length)).utf16)
    if units.count < limit + 2 {
      if units.last == 0x0A { units.removeLast() }
      if units.last == 0x0D { units.removeLast() }
    }
    let line = MinimapLine.decorationColumns(
      units.prefix(limit + 1), tabSize: document.indentUnit, limit: limit
    ).map { gutter + CGFloat($0) }
    offsets[row] = line
    return line
  }
}
