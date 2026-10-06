import Foundation
import OrbeEditorCore

/// 見えている縦の並び——文書の行（本文・装備・選択・強調・行番号・印）と差し込んだ行の字。区画は描かない（view が載る）。
extension FrameBuilder {
  /// 縦の並びで見えている項目を描く。
  func drawRows(
    _ source: Source, _ content: SurfaceContent, cache: LineLayoutCache, fonts: FontRegistry,
    _ c: Context
  ) {
    let g = c.g
    let rows = g.rows
    let bottom = g.scrollY + g.height - g.top
    drawInsertedLines(
      rows.blocks(from: g.scrollY, to: bottom, scale: g.scale), source, cache: cache, fonts: fonts,
      c)
    guard
      let visibleRows = rows.lines(
        from: g.scrollY, to: bottom, lineCount: content.text.lineCount, scale: g.scale)
    else { return cache.endFrame() }
    let baseline = (Double(c.config.baseline) * g.scale).rounded()
    let numberFont = fonts.id(c.config.gutterFont)
    let laid = layRows(visibleRows, source, text: content.text, cache: cache, fonts: fonts)
    var roles = content.roles.cursor(from: laid.first?.start ?? 0)
    for item in laid {
      let top = g.rowTop(item.row)
      let visible = visibleGlyphs(item.laid, c)
      drawDecor(item, rowTop: top, window: visible.offsets, c)
      drawOverlays(item.overlay, item.laid, rowTop: top, c)
      drawHighlights(item, source.material.highlights, rowTop: top, window: visible.offsets, c)
      let width = drawText(item, visible, baseline: top + baseline, roles: &roles, c)
      longestLine = max(longestLine, width)
      drawNumber(item.row + 1, rowTop: top, font: numberFont, c)
    }
    drawMarks(source.material.marks, rows: visibleRows, c)
  }

  /// 見えている塊 `blocks` のうち、差し込んだ行の字を置く（本文の色。役割・装備・強調の地・選択の地・キャレットは無い）。
  /// 組版は行の中身を鍵にした段で引く。
  private func drawInsertedLines(
    _ blocks: Range<Int>, _ source: Source, cache: LineLayoutCache, fonts: FontRegistry,
    _ c: Context
  ) {
    let g = c.g
    let baseline = (Double(c.config.baseline) * g.scale).rounded()
    let originX = g.column - g.scrollX
    for index in blocks {
      guard case .lines(let lines) = g.rows.contents[index] else { continue }
      for (offset, line) in lines.enumerated() {
        let top = g.insertedTop(block: index, line: offset)
        if top >= g.height { break }
        guard top + g.lineHeight > g.top else { continue }
        let laid = cache.line(
          LineShaper.source(line), tabColumns: source.material.tabColumns, config: c.config,
          fonts: fonts)
        for i in visibleGlyphs(laid, c).glyphs {
          let y = laid.ys.isEmpty ? top + baseline : top + baseline - Double(laid.ys[i]) * g.scale
          place(
            Glyph(
              font: laid.fonts[i], glyph: laid.glyphs[i],
              x: originX + Double(laid.xs[i]) * g.scale, baseline: y), c.palette.text, .text, c)
        }
        longestLine = max(longestLine, drawOmittedMark(laid, baseline: top + baseline, c))
      }
    }
  }

  /// 打ち切った行の末尾の「ほか N 字」を置き、行の幅（末尾の印を含む、pt）を返す。
  func drawOmittedMark(_ line: LaidOutLine, baseline: Double, _ c: Context) -> CGFloat {
    guard let mark = line.omittedMark else { return line.width }
    let g = c.g
    let markX = g.column - g.scrollX + Double(line.width + c.config.cell) * g.scale
    for j in mark.glyphs.indices {
      let x = markX + Double(mark.xs[j]) * g.scale
      if x > g.textRight { break }
      place(
        Glyph(font: mark.fonts[j], glyph: mark.glyphs[j], x: x, baseline: baseline),
        c.palette.gutterText, .text, c)
    }
    return line.width + c.config.cell + mark.width
  }
}
