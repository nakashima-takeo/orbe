import AppKit
import OrbeEditorCore

/// ミニマップの装飾——選択・検索の一致・語の出現・git の印（VS Code `InnerMinimap.renderDecorations`）。
extension EditorMinimapView {
  /// VS Code の描く順——選択の行の地 → 一致・語の出現の行の地 → 選択の範囲 → 語の出現・一致・現在の一致の範囲 →
  /// git の印。一致が多いときは現在の一致だけを出す。
  func drawDecorations(_ layout: MinimapLayout, document: EditorDocument) {
    let index = document.lineIndex
    let selection = document.surface.selectedRange
    let gutter = CGFloat(MinimapLine.gutter) / CGFloat(scale)
    let m = MinimapLayout.lineHeight
    let selectionRows = index.rows(of: selection)
    var highlighted = Set(selectionRows)
    if selectionRows.count > 1 {
      style.selection.withAlphaComponent(0.5).setFill()
      let top = layout.y(ofLine: selectionRows.lowerBound)
      let bottom = layout.y(ofLine: selectionRows.upperBound)
      NSRect(x: gutter, y: top, width: bounds.width - gutter, height: bottom - top).fill()
    }
    let finds = decorations.approximatesFindMatches ? [] : decorations.findMatches
    let current = decorations.currentFindMatch.map { [$0] } ?? []
    let inline: [(ranges: [NSRange], color: NSColor)] = [
      (current, style.findMatch), (finds, style.findMatch),
      (decorations.wordOccurrences, style.wordOccurrence),
    ]
    for (ranges, color) in inline {
      color.withAlphaComponent(color.alphaComponent * 0.5).setFill()
      for range in visible(ranges, layout: layout, index: index) {
        for row in index.rows(of: range) where layout.lines.contains(row) {
          guard highlighted.insert(row).inserted else { continue }
          NSRect(x: gutter, y: layout.y(ofLine: row), width: bounds.width - gutter, height: m)
            .fill()
        }
      }
    }
    fillRanges([selection], layout: layout, document: document, color: style.selection)
    for (ranges, color) in inline.reversed() {
      fillRanges(
        visible(ranges, layout: layout, index: index), layout: layout, document: document,
        color: color)
    }
    drawGitMarks(layout, document: document)
  }

  /// 描く行に掛かる区間だけ（昇順の列を二分探索で切る）。
  private func visible(_ ranges: [NSRange], layout: MinimapLayout, index: LineIndex) -> ArraySlice<
    NSRange
  > {
    guard !ranges.isEmpty, !layout.lines.isEmpty else { return [] }
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
    _ ranges: some Collection<NSRange>, layout: MinimapLayout, document: EditorDocument,
    color: NSColor
  ) {
    let index = document.lineIndex
    let gutter = CGFloat(MinimapLine.gutter) / CGFloat(scale)
    color.setFill()
    for range in ranges where range.length > 0 {
      for row in index.rows(of: range) where layout.lines.contains(row) {
        let start = index.start(ofRow: row)
        let units = Array(
          document.surface.substring(
            in: NSRange(location: start, length: index.end(ofRow: row) - start)
          ).utf16)
        let from = max(range.location, start) - start
        let to = min(NSMaxRange(range), start + units.count) - start
        let x1 =
          gutter
          + CGFloat(MinimapLine.decorationColumn(units, at: from, tabSize: document.indentUnit))
        let x2 =
          gutter
          + CGFloat(MinimapLine.decorationColumn(units, at: to, tabSize: document.indentUnit))
        NSRect(
          x: min(x1, bounds.width), y: layout.y(ofLine: row),
          width: max(0, min(x2, bounds.width) - min(x1, bounds.width)),
          height: MinimapLayout.lineHeight
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
