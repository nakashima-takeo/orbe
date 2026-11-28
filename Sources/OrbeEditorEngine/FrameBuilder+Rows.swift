import Foundation
import OrbeEditorCore

/// 見えている縦の並び——文書の行（行の型の地・本文・装備・選択・強調・行番号・記号・印・頭の線）と差し込んだ行（行の型の
/// 地・出どころの行の字と空白の点・番号・記号・頭の線）と絵の差し込み（→ `FrameBuilder+Zones`）。行の上書きか、引いている
/// 範囲の上書きのある行は、地と頭の線をその色で描く（記号は行の型のまま）。折り返した行では、行の地と頭の線は行の全部の
/// 段に、行番号と記号は 1 段目にだけ出し、字・装備・選択・強調は段ごとに描く。
extension FrameBuilder {
  /// 縦の並びで見えている項目を描く。
  func drawRows(_ source: Source, _ content: SurfaceContent, cache: LineLayoutCache, _ c: Context) {
    let g = c.g
    let rows = g.rows
    let bottom = g.scrollY + g.height - g.top
    drawZones(source, c)
    drawLeadingMark(source, c)
    drawInsertedLines(
      rows.blocks(from: g.scrollY, to: bottom, scale: g.scale), source, cache: cache, c)
    guard
      let visibleRows = rows.lines(
        from: g.scrollY, to: bottom, lineCount: content.text.lineCount, scale: g.scale)
    else { return cache.endFrame() }
    let baseline = (Double(c.config.baseline) * g.scale).rounded()
    let numberFont = c.fonts.id(c.config.gutterFont)
    let laid = layRows(visibleRows, source, text: content.text, cache: cache, c)
    var roles = content.roles.cursor(from: laid.first?.head ?? 0)
    var hovered: (row: Int, link: NSRange?)?
    let range = source.material.leadingMark?.range
    for item in laid {
      let top = g.segmentTop(item.row, item.segment)
      let bottom = g.segmentTop(item.row, item.segment + 1)
      let span = rows.lineSpan(ofLine: item.row)
      let style = c.palette.lineStyle(span?.style)
      let override = lineOverride(
        span?.override, row: .document(item.row), group: span?.markGroup, range: range, c)
      drawLineBackground(override?.background ?? style?.background, top: top, bottom: bottom, c)
      if span?.markGroup != nil { drawMarkLine(override?.mark, top: top, bottom: bottom, c) }
      if let style, item.segment == 0 {
        drawSign(style, baseline: top + baseline, cache: cache, source, c)
      }
      if c.linkPointer != nil, hovered?.row != item.row {
        hovered = (item.row, hoveredLink(in: laid, row: item.row, c))
      }
      drawSegment(item, link: hovered?.link, source, roles: &roles, c)
      guard item.segment == 0 else { continue }
      if source.material.arrangement.numbersOwnLines {
        drawNumber(item.row + 1, rowTop: top, inset: c.gutter.ownInset, font: numberFont, c)
      }
      if c.gutter.other != nil, let other = rows.otherNumber(ofLine: item.row) {
        drawNumber(other, rowTop: top, inset: c.gutter.otherInset, font: numberFont, c)
      }
    }
    if c.gutter.marks > 0 {
      drawMarks(source.material.marks, rows: visibleRows, lineCount: content.text.lineCount, c)
    }
  }

  /// 段 1 つの装備・⌘ を押したポインタの下の URL `link`（行の中の位置）の下線・重ねるもの・強調の地・字を、段の字下げの
  /// 分だけ右に描く。
  private func drawSegment(
    _ item: RowInFrame, link: NSRange?, _ source: Source, roles: inout RoleRuns.Cursor,
    _ c: Context
  ) {
    let top = c.g.segmentTop(item.row, item.segment)
    let line = c.indented(item.indent)
    let visible = visibleGlyphs(item.laid, line)
    drawWhitespace(item.laid, rowTop: top, window: visible.offsets, line)
    if let link { drawLinkUnderline(item, link: link, rowTop: top, window: visible.offsets, line) }
    overlays.draw(item.overlay, item.laid, rowTop: top, line.pen)
    drawHighlights(item, source.material.highlights, rowTop: top, window: visible.offsets, line)
    let width = drawText(item.laid, at: (item.head, top), visible, roles: &roles, line)
    if c.g.rows.wraps == nil { longestLine = max(longestLine, width) }
  }

  /// 行の上書き——引いている範囲（`range`）の、組 `group` を持つ行なら引いている範囲の上書き、そうでなければ行の上書き
  /// `override`（無ければ nil）。
  private func lineOverride(
    _ override: Int?, row: LeadingMarkRow, group: Int?,
    range: (first: LeadingMarkRow, last: LeadingMarkRow)?, _ c: Context
  ) -> OverrideInk? {
    if let range, group != nil, let drag = c.arrangement.leadingMark?.dragOverride,
      c.g.rows.contains(row, from: range.first, to: range.last)
    {
      return c.palette.lineOverride(drag)
    }
    return c.palette.lineOverride(override)
  }

  /// 行の地を、行番号の列の左端から面の右端（縦スクロールバーの列の下）まで塗る（切り取りは上端の余白の下）。
  func drawLineBackground(_ color: FrameColor?, top: Double, bottom: Double, _ c: Context) {
    guard let color else { return }
    lineBackgrounds.append(
      ShapeInstance(
        rect: SIMD4(0, Float(top), Float(c.g.width), Float(bottom - top)), color: color.packed,
        radius: 0, kind: 0))
  }

  /// 印を出せる行の頭の線を、頭の列の左端に行の上端から下端まで描く（色は `color`、無ければ頭の印の色。続く行の線は 1 本に
  /// 繋がる）。構成が頭の印を持たなければ描かない。
  func drawMarkLine(_ color: FrameColor?, top: Double, bottom: Double, _ c: Context) {
    guard let mark = c.arrangement.leadingMark, let ink = color ?? c.palette.leadingMark else {
      return
    }
    let width = (Double(mark.lineWidth) * c.g.scale).rounded()
    shapes.append(
      ShapeInstance(
        rect: SIMD4(0, Float(top), Float(width), Float(bottom - top)), color: ink.packed, radius: 0,
        kind: 0))
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

  /// 見えている塊 `blocks` のうち、差し込んだ行の行の型の地と記号と、出どころの行の字（出どころの役割の色）と空白の点と、
  /// 2 列の面の左の列の番号を置く（強調の地・選択の地・キャレット・URL の下線は無い——選べない行だから）。組版は行の中身を
  /// 鍵にした段で引く。
  private func drawInsertedLines(
    _ blocks: Range<Int>, _ source: Source, cache: LineLayoutCache, _ c: Context
  ) {
    let g = c.g
    let baseline = (Double(c.config.baseline) * g.scale).rounded()
    let numberFont = c.fonts.id(c.config.gutterFont)
    let origin = source.material.rowSourceContent
    let range = source.material.leadingMark?.range
    for index in blocks {
      guard case .lines(let lines) = g.rows.contents[index] else { continue }
      for (offset, line) in lines.enumerated() {
        let top = g.insertedTop(block: index, line: offset)
        if top >= g.height { break }
        guard top + g.lineHeight > g.top else { continue }
        let bottom = g.insertedTop(block: index, line: offset + 1)
        let style = c.palette.lineStyle(line.style)
        let group = line.line == nil ? nil : line.markGroup
        let override = lineOverride(
          line.override, row: .inserted(block: index, line: offset), group: group, range: range, c)
        drawLineBackground(override?.background ?? style?.background, top: top, bottom: bottom, c)
        if group != nil { drawMarkLine(override?.mark, top: top, bottom: bottom, c) }
        if let style { drawSign(style, baseline: top + baseline, cache: cache, source, c) }
        guard let row = line.line, let origin, row < origin.text.lineCount else { continue }
        if c.gutter.other != nil {
          drawNumber(row + 1, rowTop: top, inset: c.gutter.otherInset, font: numberFont, c)
        }
        let (lineSource, start) = LineShaper.source(row: row, in: origin.text)
        let laid = cache.line(
          lineSource, tabColumns: source.material.tabColumns, config: c.config, fonts: c.fonts)
        let visible = visibleGlyphs(laid, c)
        drawWhitespace(laid, rowTop: top, window: visible.offsets, c)
        var roles = origin.roles.cursor(from: start)
        let width = drawText(laid, at: (start, top), visible, roles: &roles, c)
        longestLine = max(longestLine, width)
      }
    }
  }

  /// 行の字を置き、行の幅（末尾の印を含む、pt）を返す。`at` は行頭の `roles` の座標のオフセットと行の上端の y。置くのは
  /// 横に見えている字だけで、役割は 1 つの読み口で引き、色は役割の連なりを出たときだけ引く。
  func drawText(
    _ line: LaidOutLine, at row: (start: Int, top: Double), _ visible: VisibleGlyphs,
    roles: inout RoleRuns.Cursor, _ c: Context
  ) -> CGFloat {
    let g = c.g
    let start = row.start
    let baseline = row.top + c.pen.baseline
    let originX = c.originX
    if visible.offsets != nil {
      var run = 0..<0
      var ink = c.palette.text
      for i in visible.glyphs {
        let offset = start + Int(line.offsets[i])
        if !run.contains(offset) {
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
    let markX = c.originX + Double(line.width + c.config.cell) * g.scale
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

extension FrameBuilder {
  /// このコマで描く段 1 つ。
  struct RowInFrame {
    let row: Int
    /// 行頭と次の行頭のオフセット。
    let start: Int
    let end: Int
    /// 行の中の段と、段の始まり（行頭からの描く単位）・字下げ（pt）。
    let segment: Int
    let base: Int
    let indent: Float
    /// 段を組んだ結果と、段に重ねるもの（どちらも位置は段の頭から）。
    let laid: LaidOutLine
    let overlay: RowOverlays

    /// 段の頭のオフセット。
    var head: Int { start + base }
  }

  /// 見えている行の、見えている段を組む（組版のキャッシュのコマはここで終える）。行頭はロープを 1 度辿って引き、前の
  /// コマで描いていない段のある行だけ中身を読む（行の中身・描く単位の列・装備は行ごとに 1 回）。
  func layRows(
    _ rows: ClosedRange<Int>, _ source: Source, text: TextRope, cache: LineLayoutCache,
    _ c: Context
  ) -> [RowInFrame] {
    let g = c.g
    let fonts = c.fonts
    var result: [RowInFrame] = []
    result.reserveCapacity(rows.count)
    let starts = text.lineStarts(rows.lowerBound..<(rows.upperBound + 1))
    var overlays = CaretOverlays(
      source.material.caret, drop: source.material.drop, caretVisible: source.caretVisible,
      text: text, from: starts[0])
    let highlights = source.material.highlights
    let lastRow = text.lineCount - 1
    let tabColumns = source.material.tabColumns
    for (index, row) in rows.enumerated() {
      let start = starts[index]
      let end = starts[index + 1]
      let overlay = overlays.next(row: row, line: start..<end)
      let needsCarets = overlay.needsCarets || highlights.touches(start..<max(end, start + 1))
      let wrap = g.rows.wrap(ofLine: row)
      let count = wrap?.segments ?? 1
      var read: (shown: LineShaper.Displayed, decor: LineDecor)?
      for segment in 0..<count {
        let top = g.segmentTop(row, segment)
        if top >= g.height { break }
        guard top + g.lineHeight > g.top else { continue }
        let key = LineLayoutCache.Segment(row: row, segment: segment)
        let base = wrap?.start(of: segment) ?? 0
        var laid = cache.drawn(key, carets: needsCarets)
        if laid == nil {
          if read == nil {
            read = cache.read(
              LineShaper.source(start: start, next: row < lastRow ? end : nil, in: text))
          }
          let (shown, decor) = read!
          let range =
            base..<(segment + 1 < count ? wrap!.start(of: segment + 1) : shown.units.count)
          let piece = decor.segment(range)
          var shaped = cache.line(
            shown.segment(range, last: segment + 1 == count), tabColumns: tabColumns,
            config: source.config, fonts: fonts, carets: needsCarets || piece.needsCarets)
          shaped.decor = piece
          laid = shaped
        }
        cache.keep(key, laid!)
        result.append(
          RowInFrame(
            row: row, start: start, end: end, segment: segment, base: base,
            indent: segment > 0 ? wrap?.indent ?? 0 : 0, laid: laid!,
            overlay: overlay.segment(
              base: base, end: segment + 1 < count ? wrap!.start(of: segment + 1) : nil)))
      }
    }
    cache.endFrame()
    return result
  }
}
