import Foundation
import OrbeEditorCore

/// 見えている縦の並び——文書の行（行の型の地・本文・装備・選択・強調・行番号・記号・印）と差し込んだ行（行の型の地・字・
/// 番号・記号）と区画（→ `FrameBuilder+Zones`）。
extension FrameBuilder {
  /// 縦の並びで見えている項目を描く。
  func drawRows(_ source: Source, _ content: SurfaceContent, cache: LineLayoutCache, _ c: Context) {
    let g = c.g
    let rows = g.rows
    let bottom = g.scrollY + g.height - g.top
    drawZones(source, c)
    drawInsertedLines(
      rows.blocks(from: g.scrollY, to: bottom, scale: g.scale), source, cache: cache, c)
    guard
      let visibleRows = rows.lines(
        from: g.scrollY, to: bottom, lineCount: content.text.lineCount, scale: g.scale)
    else { return cache.endFrame() }
    let baseline = (Double(c.config.baseline) * g.scale).rounded()
    let numberFont = c.fonts.id(c.config.gutterFont)
    let laid = layRows(visibleRows, source, text: content.text, cache: cache, fonts: c.fonts)
    var roles = content.roles.cursor(from: laid.first?.start ?? 0)
    let styled = !rows.spans.isEmpty
    for var item in laid {
      let top = g.rowTop(item.row)
      let style = styled ? c.palette.lineStyle(rows.style(ofLine: item.row)) : nil
      item.ink = style?.text
      if let style {
        drawLineBackground(style, top: top, bottom: g.rowBottom(item.row), c)
        drawSign(style, baseline: top + baseline, cache: cache, source, c)
      }
      let visible = visibleGlyphs(item.laid, c)
      drawDecor(item, rowTop: top, window: visible.offsets, c)
      overlays.draw(item.overlay, item.laid, rowTop: top, c.pen)
      drawHighlights(item, source.material.highlights, rowTop: top, window: visible.offsets, c)
      let width = drawText(item, visible, baseline: top + baseline, roles: &roles, c)
      longestLine = max(longestLine, width)
      drawNumber(item.row + 1, rowTop: top, inset: c.gutter.ownInset, font: numberFont, c)
      if c.numberColumns == 2, let other = rows.otherNumber(ofLine: item.row) {
        drawNumber(other, rowTop: top, inset: c.gutter.otherInset, font: numberFont, c)
      }
    }
    if c.gutter.marks > 0 { drawMarks(source.material.marks, rows: visibleRows, c) }
  }

  /// 行の型の地を、行番号の列の左端から本文の区画の右端まで塗る（切り取りは上端の余白の下）。
  func drawLineBackground(_ style: LineInk, top: Double, bottom: Double, _ c: Context) {
    guard let color = style.background else { return }
    lineBackgrounds.append(
      ShapeInstance(
        rect: SIMD4(0, Float(top), Float(c.g.textRight), Float(bottom - top)), color: color.packed,
        radius: 0, kind: 0))
  }

  /// 行の型の記号を、記号の列の中央に置く（本文の字体）。
  func drawSign(
    _ style: LineInk, baseline: Double, cache: LineLayoutCache, _ source: Source, _ c: Context
  ) {
    guard let sign = style.sign, c.gutter.sign > 0 else { return }
    let g = c.g
    let laid = cache.line(
      LineShaper.source(sign), tabColumns: source.material.tabColumns, config: c.config,
      fonts: c.fonts)
    let left = g.column - Double(c.gutter.sign) * g.scale
    let x0 = (left + (Double(c.gutter.sign) - Double(laid.width)) / 2 * g.scale).rounded()
    for i in laid.glyphs.indices {
      let y = laid.ys.isEmpty ? baseline : baseline - Double(laid.ys[i]) * g.scale
      place(
        Glyph(
          font: laid.fonts[i], glyph: laid.glyphs[i], x: x0 + Double(laid.xs[i]) * g.scale,
          baseline: y), style.signInk, .gutter, c)
    }
  }

  /// 見えている塊 `blocks` のうち、差し込んだ行の字（行の型の字の色か本文の色。役割・装備・強調の地・選択の地・キャレット
  /// は無い）と、行の型の地と記号と、2 列の面の左の列の番号を置く。組版は行の中身を鍵にした段で引く。
  private func drawInsertedLines(
    _ blocks: Range<Int>, _ source: Source, cache: LineLayoutCache, _ c: Context
  ) {
    let g = c.g
    let baseline = (Double(c.config.baseline) * g.scale).rounded()
    let originX = g.column - g.scrollX
    let numberFont = c.fonts.id(c.config.gutterFont)
    for index in blocks {
      guard case .lines(let lines) = g.rows.contents[index] else { continue }
      for (offset, line) in lines.enumerated() {
        let top = g.insertedTop(block: index, line: offset)
        if top >= g.height { break }
        guard top + g.lineHeight > g.top else { continue }
        let style = c.palette.lineStyle(line.style)
        if let style {
          drawLineBackground(
            style, top: top, bottom: g.insertedTop(block: index, line: offset + 1), c)
          drawSign(style, baseline: top + baseline, cache: cache, source, c)
        }
        if c.numberColumns == 2, let number = line.number {
          drawNumber(number, rowTop: top, inset: c.gutter.otherInset, font: numberFont, c)
        }
        let laid = cache.line(
          LineShaper.source(line.text), tabColumns: source.material.tabColumns, config: c.config,
          fonts: c.fonts)
        let ink = style?.text ?? c.palette.text
        for i in visibleGlyphs(laid, c).glyphs {
          let y = laid.ys.isEmpty ? top + baseline : top + baseline - Double(laid.ys[i]) * g.scale
          place(
            Glyph(
              font: laid.fonts[i], glyph: laid.glyphs[i],
              x: originX + Double(laid.xs[i]) * g.scale, baseline: y), ink, .text, c)
        }
        longestLine = max(longestLine, drawOmittedMark(laid, baseline: top + baseline, c))
      }
    }
  }

  /// 行の字を置き、行の幅（末尾の印を含む、pt）を返す。置くのは横に見えている字だけで、役割は見えている行を通して 1 つの
  /// 読み口で引き、色は役割の連なりを出たときだけ引く。行の型が字の色を持てば、行の字をすべてその色で描く。
  func drawText(
    _ row: RowInFrame, _ visible: VisibleGlyphs, baseline: Double, roles: inout RoleRuns.Cursor,
    _ c: Context
  ) -> CGFloat {
    let override = row.ink
    let line = row.laid
    let start = row.start
    let g = c.g
    let originX = g.column - g.scrollX
    if let offsets = visible.offsets {
      var run = 0..<0
      var ink = override ?? c.palette.text
      for i in visible.glyphs {
        let offset = start + Int(line.offsets[i])
        if override == nil, !run.contains(offset) {
          let found = roles.run(at: offset)
          run = found.range
          ink = c.palette.ink(found.role)
        }
        let x = originX + Double(line.xs[i]) * g.scale
        let y = line.ys.isEmpty ? baseline : baseline - Double(line.ys[i]) * g.scale
        let glyph = Glyph(font: line.fonts[i], glyph: line.glyphs[i], x: x, baseline: y)
        place(glyph, ink, .text, c)
      }
    }
    return drawOmittedMark(line, baseline: baseline, c)
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
