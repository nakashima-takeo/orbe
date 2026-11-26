import Foundation
import OrbeEditorCore

/// 縦横のスクロールバーと印・影。どれもこのコマの本文の位置（端を越えている間は端）から出す。
extension FrameBuilder {
  /// 上端の影（先頭の行が隠れている間。行番号の列から本文の区画の右端まで。絵の差し込みの上に重なる）と、ミニマップの
  /// 左の影（ミニマップがあり、本文が右に続くとき。本文の区画の上、影の帯の外側）。濃さは CSS のぼかし（σ 3 のガウスの
  /// 縁）を 9 点で写した勾配で、画素の中心で引く。
  func drawShadows(
    _ layout: SurfaceLayout, lines: (first: CGFloat, visible: CGFloat), clipsRight: Bool,
    _ c: Context
  ) {
    let g = c.g
    let depth = 6.0
    if lines.first > 0 {
      let rows = Int((depth * g.scale).rounded())
      for y in 0..<rows {
        let strength = Self.shadowStrength((Double(y) + 0.5) / g.scale, length: depth)
        shadowShapes.append(
          ShapeInstance(
            rect: SIMD4(0, Float(y), Float(g.textRight), 1),
            color: c.palette.overview.topShadow.scaled(alpha: strength), radius: 0, kind: 0))
      }
    }
    guard clipsRight, layout.minimapWidth > 0 else { return }
    let band = (Double(layout.minimap.minX) - depth) * g.scale
    let columns = Int((2 * depth * g.scale).rounded())
    for step in 0..<columns {
      let x = band.rounded() - Double(step + 1)
      guard x >= 0 else { break }
      let strength = Self.shadowStrength((band - (x + 0.5)) / g.scale, length: 2 * depth)
      shadowShapes.append(
        ShapeInstance(
          rect: SIMD4(Float(x), 0, 1, Float(g.height)),
          color: c.palette.overview.minimapShadow.scaled(alpha: strength), radius: 0, kind: 0))
    }
  }

  /// 影の縁から `distance` pt の濃さ——`0.5·erfc(d / (σ√2))`（σ 3）を長さ `length` に 9 点で置いた折れ線。
  static func shadowStrength(_ distance: Double, length: Double) -> Double {
    let t = min(max(distance / length, 0), 1) * 8
    let k = min(Int(t), 7)
    let a = 0.5 * erfc(Double(k) / 8 * length / (3 * 2.0.squareRoot()))
    let b = 0.5 * erfc(Double(k + 1) / 8 * length / (3 * 2.0.squareRoot()))
    return a + (b - a) * (t - Double(k))
  }

  /// 縦スクロールバー——印（左 git・中央 検索の一致と語の出現・全幅 キャレット）→ 縁（左と上に 1 デバイス px）→ つまみ。
  func drawVerticalScrollbar(
    _ layout: SurfaceLayout, lines: (first: CGFloat, visible: CGFloat), _ source: Source,
    _ content: SurfaceContent, _ c: Context
  ) {
    let area = layout.verticalScrollbar
    guard area.width > 0, area.height > 0 else { return }
    let g = c.g
    let s = g.scale
    let x0 = (Double(area.minX) * s).rounded()
    let text = content.text
    let rows = source.material.rows
    let ruler = OverviewRuler(
      contentLines: source.limits.contentLines(rows: rows, lineCount: text.lineCount),
      visibleLines: lines.visible, height: area.height, scale: CGFloat(s))
    let palette = c.palette.overview
    updateRulerSpans(ruler, area: area, lines: lines, source, text: text)
    for group in rulerSpans.groups {
      let lane = OverviewRuler.lane(group.kind.lane, width: area.width, scale: CGFloat(s))
      let ink: FrameColor =
        switch group.kind {
        case .added: palette.rulerAdded
        case .modified: palette.rulerModified
        case .removed: palette.rulerRemoved
        case .word: palette.rulerWord
        case .find: palette.rulerFind
        }
      for span in group.spans {
        rect(
          x0 + Double(lane.x), Double(span.y1), Double(lane.width), Double(span.y2 - span.y1), ink)
      }
    }
    updateCaretSpans(ruler, area: area, lines: lines, source, content: content)
    let full = OverviewRuler.lane(.full, width: area.width, scale: CGFloat(s))
    for span in rulerSpans.caretSpans {
      rect(
        x0 + Double(full.x), Double(span.y1), Double(full.width), Double(span.y2 - span.y1),
        palette.rulerCaret)
    }
    let width = (Double(area.width) * s).rounded()
    rect(x0, 0, 1, (Double(area.height) * s).rounded(), palette.border)
    rect(x0 + 1, 0, width - 1, 1, palette.border)
  }

  /// 図形を 1 つ足す（px）。
  private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ ink: FrameColor)
  {
    guard width > 0, height > 0 else { return }
    overviewShapes.append(
      ShapeInstance(
        rect: SIMD4(Float(x), Float(y), Float(width), Float(height)), color: ink.packed, radius: 0,
        kind: 0))
  }

  /// 全キャレットの印の縦の区間を、キャレット・本文・寸法が変わったときだけ作り直す（`OverviewRuler.carets`）。
  private func updateCaretSpans(
    _ ruler: OverviewRuler, area: CGRect, lines: (first: CGFloat, visible: CGFloat),
    _ source: Source, content: SurfaceContent
  ) {
    let carets = source.material.caret.carets
    let rows = source.material.rows
    let key = RulerSpans.CaretKey(
      carets: carets, upstream: source.material.caret.upstream, version: content.version,
      rows: rows.version,
      scrollLines: ruler.scrollLines, visibleLines: lines.visible, height: area.height,
      scale: ruler.scale)
    guard key != rulerSpans.caretKey else { return }
    rulerSpans.caretKey = key
    let text = content.text
    let upstream = Set(source.material.caret.upstream)
    let points = carets.map { NSRange(location: min($0, text.length), length: 0) }
    rulerSpans.caretSpans = ruler.carets(
      at: zip(text.rows(ofAscending: points), carets).map { lines, caret in
        let row = lines.lowerBound
        let segment =
          rows.wrap(ofLine: row).map {
            $0.segment(
              containing: min(caret, text.length) - text.lineStart(row),
              upstream: upstream.contains(caret))
          } ?? 0
        return CGFloat(rows.unit(ofLine: row) + Double(segment))
      })
  }

  /// 印の縦の区間を、元が変わったときだけ作り直す。検索の一致が多いときは近い行をまとめ、現在の一致を加える。
  private func updateRulerSpans(
    _ ruler: OverviewRuler, area: CGRect, lines: (first: CGFloat, visible: CGFloat),
    _ source: Source, text: TextRope
  ) {
    let highlights = source.material.highlights
    let find = source.rulerRows.find(highlights, text: text)
    let word = source.rulerRows.word(highlights, text: text)
    // 印の列を持たない構成の面（diff）は、スクロールバーにも git の印を描かない。
    let marks = source.material.arrangement.showsMarks ? source.material.marks : .empty
    let rows = source.material.rows
    let key = RulerSpans.Key(
      find: find.generation, word: word.generation, marks: marks, lineCount: text.lineCount,
      rows: rows.version, scrollLines: ruler.scrollLines, visibleLines: lines.visible,
      height: area.height, scale: ruler.scale,
      current: highlights.crowded ? highlights.current.first : nil)
    guard key != rulerSpans.key else { return }
    rulerSpans.key = key
    var findRows = find.rows
    var findRanges = find.ranges
    if highlights.crowded {
      findRanges = []
      findRows = OverviewRuler.approximate(findRows, lineCount: text.lineCount, height: area.height)
      if let current = highlights.current.first {
        findRows.append(text.rows(of: current))
        findRows.sort { $0.lowerBound < $1.lowerBound }
      }
    }
    let removed = marks.deletions.map { boundary -> ClosedRange<Int> in
      let row = max(0, boundary - 1)
      return row...row
    }
    let groups: [(RulerSpans.Kind, RulerRows.Mapped)] = [
      (.added, RulerRows.Mapped(rows: marks.bars.filter { $0.kind == .added }.map(\.rows))),
      (.modified, RulerRows.Mapped(rows: marks.bars.filter { $0.kind == .modified }.map(\.rows))),
      (.removed, RulerRows.Mapped(rows: removed)),
      (.word, word),
      (.find, RulerRows.Mapped(ranges: findRanges, rows: findRows)),
    ]
    rulerSpans.groups = groups.compactMap { kind, mapped in
      mapped.rows.isEmpty
        ? nil : (kind, ruler.spans(Self.unitSpans(mapped, rows, text: text)))
    }
  }

  /// 行の区間の列を、表示の単位の縦の区間の列に写す。行と同じ順の本文の区間があれば、折り返した行では区間の先頭の段から
  /// 終わりの段まで、無ければ（区間の数が行の数と違えば）行の全部の段。
  private static func unitSpans(_ mapped: RulerRows.Mapped, _ rows: RowLayout, text: TextRope)
    -> [Range<CGFloat>]
  {
    let lines = mapped.rows
    let ranges = mapped.ranges.count == lines.count ? mapped.ranges : nil
    return lines.indices.map { index in
      let span = lines[index]
      guard rows.wraps != nil else {
        return CGFloat(
          rows.unit(ofLine: span.lowerBound))..<CGFloat(
            rows.unit(ofLine: span.upperBound) + 1)
      }
      guard let range = ranges?[index] else {
        return CGFloat(
          rows.unit(ofLine: span.lowerBound))..<CGFloat(
            rows.unit(endOfLine: span.upperBound))
      }
      let first = rows.wrap(ofLine: span.lowerBound).map {
        $0.segment(containing: range.location - text.lineStart(span.lowerBound))
      }
      let last = rows.wrap(ofLine: span.upperBound).map {
        $0.segment(
          containing: NSMaxRange(range) - text.lineStart(span.upperBound),
          upstream: range.length > 0)
      }
      return CGFloat(
        rows.unit(ofLine: span.lowerBound) + Double(first ?? 0))..<CGFloat(
          rows.unit(ofLine: span.upperBound) + Double(last ?? 0) + 1)
    }
  }
}

extension FrameBuilder {
  /// ミニマップの帯と縦横のスクロールバーのつまみ。濃さはこのコマの時刻から、色は「ドラッグ中・上にポインタ・普段」で、
  /// 上かはこのコマの配置で決める。
  func drawSliders(
    _ layout: SurfaceLayout, lines: (first: CGFloat, visible: CGFloat), _ source: Source,
    contentLines: CGFloat, _ c: Context
  ) {
    let input = source.material.overview
    let motion = source.motion
    let palette = c.palette.overview
    let limits = source.limits
    let x = min(max(0, source.position.x), limits.maximum.x)
    let thumb = motion.thumbOpacity(
      at: source.time,
      state: OverviewMotion.ScrollState(
        first: lines.first, visible: lines.visible, contentLines: contentLines, x: x,
        width: limits.viewport.x, range: limits.maximum.x),
      baselines: source.baselines, input: input, motion: c.config.overview)
    let pointer = input.pointer
    if let placement = minimap.placement {
      let area = layout.minimap
      let over = pointer.map { area.contains($0) } ?? false
      let opacity = motion.sliderOpacity(
        at: source.time, shown: (over || input.drag == .minimap) && placement.sliderNeeded,
        input: input, motion: c.config.overview)
      let hover = pointer.map { over && placement.sliderContains(y: $0.y - area.minY) } ?? false
      let ink =
        input.drag == .minimap
        ? palette.minimapSliderActive : hover ? palette.minimapSliderHover : palette.minimapSlider
      slider(
        CGRect(
          x: area.minX, y: area.minY + placement.sliderTop, width: area.width,
          height: placement.sliderHeight), ink, opacity, c)
    }
    let vertical = layout.verticalScrollbar
    let geometry = ScrollbarGeometry(
      contentLines: contentLines, firstLine: lines.first, visibleLines: lines.visible,
      height: vertical.height)
    if geometry.isNeeded {
      let hover = pointer.map { vertical.contains($0) && geometry.sliderContains($0.y) } ?? false
      slider(
        CGRect(
          x: vertical.minX, y: geometry.sliderPosition, width: vertical.width,
          height: geometry.sliderLength), thumbInk(.vertical, hover, input, palette), thumb, c)
    }
    let horizontal = layout.horizontalScrollbar
    let across = ScrollbarGeometry(
      visible: limits.viewport.x, total: limits.viewport.x + limits.maximum.x, position: x,
      trackLength: horizontal.width)
    if across.isNeeded {
      let hover =
        pointer.map { horizontal.contains($0) && across.sliderContains($0.x - horizontal.minX) }
        ?? false
      slider(
        CGRect(
          x: horizontal.minX + across.sliderPosition, y: horizontal.minY,
          width: across.sliderLength, height: horizontal.height),
        thumbInk(.horizontal, hover, input, palette), thumb, c)
    }
  }

  private func thumbInk(
    _ drag: OverviewInput.Drag, _ hover: Bool, _ input: OverviewInput, _ palette: OverviewPalette
  ) -> FrameColor {
    input.drag == drag ? palette.sliderActive : hover ? palette.sliderHover : palette.slider
  }

  /// 帯・つまみを 1 つ足す（pt の矩形、濃さ `opacity`）。
  private func slider(_ rect: CGRect, _ ink: FrameColor, _ opacity: Double, _ c: Context) {
    guard opacity > 0 else { return }
    let s = c.g.scale
    let left = (Double(rect.minX) * s).rounded()
    let top = (Double(rect.minY) * s).rounded()
    let right = (Double(rect.maxX) * s).rounded()
    let bottom = (Double(rect.maxY) * s).rounded()
    guard right > left, bottom > top else { return }
    overviewShapes.append(
      ShapeInstance(
        rect: SIMD4(Float(left), Float(top), Float(right - left), Float(bottom - top)),
        color: ink.scaled(alpha: opacity), radius: 0, kind: 0))
  }
}

extension FrameColor {
  /// α に `factor` を掛けた色（詰めた値）。
  func scaled(alpha factor: Double) -> UInt32 {
    let alpha = Double(packed >> 24) * min(max(factor, 0), 1)
    return packed & 0x00FF_FFFF | UInt32(alpha.rounded()) << 24
  }
}
