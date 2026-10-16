import AppKit

/// 行の種類ごとの描き方（寸法と色は見本 ScmPanel の値）。
extension ScmRowView {
  /// 区分見出し 22（padding 0 12 0 4。グラフは 0 8 0 4）: シェブロン 16・題 11 bold・右端に一括操作と件数バッジ。
  func draw(
    _ header: Header, _ colors: RowColors, _ scm: ScmRowColors, in context: CGContext
  ) {
    let band = self.band
    if isHovered, !isSelected {
      context.setFillColor(scm.headerHover)
      context.fill(band)
    }
    let chevron = Theme.Layout.editorChevron
    drawGlyph(
      header.isOpen ? .chevronOpen : .chevron,
      in: NSRect(x: Theme.Space.tick, y: band.midY - chevron / 2, width: chevron, height: chevron),
      scm.icon, in: context)
    let rects = buttonRects()
    var right = (rects.first?.1.minX ?? bounds.width - 12) - Theme.Space.note
    if let count = header.count {
      let width = countWidth(count)
      let height = Theme.Layout.editorSearchCountHeight
      let badge = NSRect(
        x: bounds.width - 12 - width, y: snap(band.midY - height / 2), width: width, height: height)
      fill(badge, radius: height / 2, scm.countStrong, in: context)
      count.draw(
        at: snap(badge.midX - count.width / 2), top: snap(badge.midY - count.height / 2),
        colors.primary, context)
      if rects.isEmpty { right = badge.minX - Theme.Space.note }
    }
    drawButtons(rects, tool: true, scm, in: context)
    let x = Theme.Space.tick + chevron
    header.label.draw(
      at: x, top: snap(band.midY - header.label.height / 2), width: max(0, right - x),
      colors.text, context)
  }

  /// ファイル行 22（padding 0 12 0 20・gap 6）: 種別チップ 16・名前 13（バッジの色）・ディレクトリ 11 tertiary・右端に行の
  /// ボタン 18（常に出す）とバッジの字。名前を先に取り、ディレクトリは残りに詰める。
  func draw(_ file: File, _ colors: RowColors, _ scm: ScmRowColors, in context: CGContext) {
    if isHovered, !isSelected {
      context.setFillColor(scm.fileHover)
      context.fill(bounds)
    }
    let gap = Theme.Space.note
    var x: CGFloat = 20
    drawChip(
      file.chipText, file.chip.tint, at: x, size: Theme.Layout.editorScmChip, colors, in: context)
    x += Theme.Layout.editorScmChip + gap
    let badgeX = bounds.width - 12 - snap(file.badge.width, .up)
    let color = scm.badge(file.badgeKind)
    file.badge.draw(at: badgeX, top: top(file.badge), color, context)
    let rects = buttonRects()
    drawButtons(rects, tool: false, scm, in: context)
    let limit = (rects.first?.1.minX ?? badgeX) - gap
    let nameWidth = min(snap(file.name.width, .up), max(0, limit - x))
    file.name.draw(at: x, top: top(file.name), width: nameWidth, color, context)
    x += nameWidth + gap
    file.directory.draw(
      at: x, top: top(file.directory), width: max(0, limit - x), colors.tertiary, context)
  }

  /// ブランチの器（padding 0 12 6 の箱 24・radius 3・地 sunk .35・枠 hairline .10、中は padding 0 8・gap 6）: ブランチの印 9
  /// （accentBright）・名前と先行/遅れ（mono 11。数は tertiary）。
  func draw(_ branch: Branch, _ scm: ScmRowColors, in context: CGContext) {
    let box = NSRect(
      x: 12, y: 0, width: max(0, bounds.width - 24), height: Theme.Layout.editorScmBranch)
    fill(box, radius: Theme.Radius.xs, scm.branchGround, in: context)
    context.setStrokeColor(scm.branchBorder)
    context.setLineWidth(Theme.Stroke.hairline)
    context.addPath(
      CGPath(
        roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Theme.Radius.xs - 0.5,
        cornerHeight: Theme.Radius.xs - 0.5, transform: nil))
    context.strokePath()
    let gap = Theme.Space.note
    var x = box.minX + Theme.Space.step
    let glyph: CGFloat = 9
    drawGlyph(
      .branch, in: NSRect(x: x, y: box.midY - glyph / 2, width: glyph, height: glyph), scm.accent,
      in: context)
    x += glyph + gap
    let limit = box.maxX - Theme.Space.step
    let nameWidth = min(snap(branch.name.width, .up), max(0, limit - x))
    branch.name.draw(
      at: x, top: snap(box.midY - branch.name.height / 2), width: nameWidth, scm.text, context)
    x += nameWidth + gap
    if let divergence = branch.divergence {
      divergence.draw(
        at: x, top: snap(box.midY - divergence.height / 2), width: max(0, limit - x), scm.tertiary,
        context)
    }
  }

  /// コミット 22（padding 0 12 0 20・gap 6）: 点の列 16（未 push は塗り accentBright と地の輪、push 済みは中抜き tertiary）と
  /// 縦の線・題 12（push 済みは muted）・右端に ref の札（local は accent、remote は無彩）。札が入らなければ末尾から省く。
  func draw(
    _ commit: Commit, _ colors: RowColors, _ scm: ScmRowColors, in context: CGContext
  ) {
    let column = Theme.Layout.editorScmDotColumn
    let lineX: CGFloat = 27
    let top = commit.isFirst ? Theme.Space.step : 0
    let bottom = commit.isLast ? bounds.height - Theme.Space.step : bounds.height
    if bottom > top {
      context.setFillColor(scm.graphLine)
      context.fill(NSRect(x: lineX, y: top, width: Theme.Stroke.hairline, height: bottom - top))
    }
    let dot = Theme.Layout.editorScmDot
    let center = NSPoint(x: 20 + column / 2, y: bounds.height / 2)
    let dotRect = NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)
    if commit.isPushed {
      context.setFillColor(scm.ground)
      context.fillEllipse(in: dotRect)
      context.setStrokeColor(scm.tertiary)
      context.setLineWidth(1.5)
      context.strokeEllipse(in: dotRect.insetBy(dx: 0.75, dy: 0.75))
    } else {
      context.setFillColor(scm.ground)
      context.fillEllipse(in: dotRect.insetBy(dx: -2, dy: -2))
      context.setFillColor(scm.accent)
      context.fillEllipse(in: dotRect)
    }
    let gap = Theme.Space.note
    let x = 20 + column + gap
    let limit = bounds.width - 12
    var refs = commit.refs
    var widths = refs.map { refWidth($0.label) }
    let minimumSubject: CGFloat = 48
    while !refs.isEmpty,
      limit - widths.reduce(0, +) - CGFloat(refs.count) * Theme.Space.tick - x < minimumSubject
    {
      refs.removeLast()
      widths.removeLast()
    }
    var right = limit
    for (ref, width) in zip(refs, widths).reversed() {
      drawRef(
        ref.label, isLocal: ref.isLocal,
        in: NSRect(
          x: right - width, y: snap((bounds.height - Theme.Layout.editorScmRef) / 2), width: width,
          height: Theme.Layout.editorScmRef), scm, in: context)
      right -= width + Theme.Space.tick
    }
    commit.subject.draw(
      at: x, top: self.top(commit.subject), width: max(0, right + Theme.Space.tick - gap - x),
      commit.isPushed ? colors.muted : colors.text, context)
  }

  private func refWidth(_ label: TextLine) -> CGFloat {
    5 + 8 + 3 + snap(label.width, .up) + 5
  }

  /// ref の札 15（radius 3・padding 0 5・枠 1px）: ブランチの印 8 と名前（mono 9）。
  private func drawRef(
    _ label: TextLine, isLocal: Bool, in rect: NSRect, _ scm: ScmRowColors, in context: CGContext
  ) {
    let color = isLocal ? scm.accent : scm.muted
    fill(
      rect, radius: Theme.Radius.xs, isLocal ? scm.localRefGround : scm.remoteRefGround, in: context
    )
    context.setStrokeColor(isLocal ? scm.localRefBorder : scm.remoteRefBorder)
    context.setLineWidth(Theme.Stroke.hairline)
    context.addPath(
      CGPath(
        roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Theme.Radius.xs - 0.5,
        cornerHeight: Theme.Radius.xs - 0.5, transform: nil))
    context.strokePath()
    let glyph: CGFloat = 8
    drawGlyph(
      .branch, in: NSRect(x: rect.minX + 5, y: rect.midY - glyph / 2, width: glyph, height: glyph),
      color, in: context)
    label.draw(
      at: rect.minX + 5 + glyph + 3, top: snap(rect.midY - label.height / 2), color, context)
  }

  /// 行の中のボタン（見出しのツールは 20・radius 4・hover 地 fill .08 で字が上がる、行のボタンは 18・radius 3・hover 地
  /// fill .10）。押せない姿は字を薄くし、地を付けない。
  private func drawButtons(
    _ rects: [(Button, NSRect)], tool: Bool, _ scm: ScmRowColors, in context: CGContext
  ) {
    for (button, rect) in rects {
      let hovered = button.isEnabled && pointer.map(rect.contains) == true
      if hovered {
        fill(
          rect, radius: tool ? Theme.Radius.sm : Theme.Radius.xs,
          tool ? scm.toolHover : scm.buttonHover, in: context)
      }
      let color =
        !button.isEnabled ? scm.disabled : tool ? (hovered ? scm.text : scm.muted) : scm.text
      let size = Theme.Layout.editorScmGlyph
      drawGlyph(
        button.glyph,
        in: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
        color, in: context)
    }
  }

  private func drawGlyph(
    _ shape: ScmGlyphShape, in rect: NSRect, _ color: CGColor, in context: CGContext
  ) {
    let path = shape.path(size: rect.width)
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.minY)
    if path.fills {
      context.setFillColor(color)
      context.addPath(path.path)
      context.fillPath()
    } else {
      context.setStrokeColor(color)
      context.setLineWidth(path.lineWidth)
      context.addPath(path.path)
      context.strokePath()
    }
    context.restoreGState()
  }
}
