import AppKit

/// PR のパネルの列の行の描き方（寸法と色は見本 PrReviewPanel の値）。
extension PrRowView {
  /// 区分の見出し 22（padding 0 12 0 4）: シェブロン 16・題 11 bold・右端にコミットの件数バッジか、「N/M 確認済み」と
  /// ツリー / リストの印。
  func draw(
    _ section: Section, _ colors: RowColors, _ scm: ScmRowColors, _ pr: PrRowColors,
    in context: CGContext
  ) {
    if isHovered, !isSelected {
      context.setFillColor(scm.headerHover)
      context.fill(bounds)
    }
    let chevron = Theme.Layout.editorChevron
    let x = Theme.Space.tick
    drawChevron(at: x, size: chevron, open: section.isOpen, scm.icon, in: context)
    var right = bounds.width - 12
    if let count = section.count {
      let width = max(Theme.Layout.editorSearchCountWidth, snap(count.width, .up) + 10)
      let height = Theme.Layout.editorSearchCountHeight
      let badge = NSRect(
        x: right - width, y: snap(bounds.midY - height / 2), width: width, height: height)
      fill(badge, radius: height / 2, pr.toggleOn, in: context)
      count.draw(
        at: snap(badge.midX - count.width / 2), top: snap(badge.midY - count.height / 2),
        colors.secondary, context)
      right = badge.minX
    }
    if let asTree = section.asTree {
      for (control, rect) in toggleRects() {
        let on = (control == .tree) == asTree
        let hovered = pointer.map(rect.contains) == true
        if on || hovered { fill(rect, radius: 3, pr.toggleOn, in: context) }
        let glyph: RowGlyphShape = control == .tree ? .viewAsTree : .viewAsList
        let size: CGFloat = 13
        glyph.draw(
          in: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
          on ? pr.toggleOnGlyph : colors.tertiary, in: context)
        right = min(right, rect.minX)
      }
      right -= Theme.Space.note
    }
    if let viewed = section.viewed {
      right -= snap(viewed.width, .up)
      viewed.draw(at: right, top: top(viewed), colors.muted, context)
      right -= Theme.Space.note
    }
    let labelX = x + chevron
    section.label.draw(
      at: labelX, top: top(section.label), width: max(0, right - labelX), colors.text, context)
  }

  /// コミットの行 22（padding 0 12 0 20・gap 6）: 点の列 16（点 7）・題の 1 行目（12）・右端に短い sha（mono 10.5 tertiary）。
  /// 押せない（地も付けない）。
  func draw(
    message: TextLine, sha: TextLine, _ colors: RowColors, _ pr: PrRowColors, in context: CGContext
  ) {
    let column = Theme.Layout.editorScmDotColumn
    let dot = Theme.Layout.editorScmDot
    context.setFillColor(pr.dot)
    context.fillEllipse(
      in: NSRect(
        x: 20 + (column - dot) / 2, y: snap(bounds.midY - dot / 2), width: dot, height: dot))
    let shaX = bounds.width - 12 - snap(sha.width, .up)
    sha.draw(at: shaX, top: top(sha), colors.tertiary, context)
    let x = 20 + column + Theme.Space.note
    message.draw(
      at: x, top: top(message), width: max(0, shaX - Theme.Space.note * 2 - x), colors.text,
      context)
  }

  /// フォルダの行 22（padding 0 12・gap 6）: チェック・字下げの線・シェブロン・名前（13）・右端に「済/全」（mono 10.5
  /// tertiary）。配下が全部確認済みなら全体を薄くする。
  func draw(
    _ folder: Folder, _ colors: RowColors, _ scm: ScmRowColors, _ pr: PrRowColors,
    in context: CGContext
  ) {
    if isHovered, !isSelected {
      context.setFillColor(scm.fileHover)
      context.fill(bounds)
    }
    dimming(folder.dimmed, in: context) {
      var x = drawCheck(folder.check, pr, in: context)
      x = drawGuides(folder.depth, from: x, pr, in: context)
      drawChevron(
        at: x, size: Theme.Layout.editorChevron, open: folder.isOpen, scm.icon, in: context)
      x += Theme.Layout.editorChevron + Theme.Space.note
      let countX = bounds.width - 12 - snap(folder.count.width, .up)
      folder.count.draw(at: countX, top: top(folder.count), colors.tertiary, context)
      folder.name.draw(
        at: x, top: top(folder.name), width: max(0, countX - Theme.Space.note - x), colors.text,
        context)
    }
  }

  /// ファイルの行 22（padding 0 12・gap 6）: チェック・字下げの線・種別チップ 16・名前（13・バッジの色）・リストなら
  /// ディレクトリ（11 tertiary）・右端にバッジの字（mono 11）。確認済みなら全体を薄くする。
  func draw(
    _ file: File, _ colors: RowColors, _ scm: ScmRowColors, _ pr: PrRowColors,
    in context: CGContext
  ) {
    if isHovered, !isSelected {
      context.setFillColor(scm.fileHover)
      context.fill(bounds)
    }
    dimming(file.dimmed, in: context) {
      var x = drawCheck(file.check, pr, in: context)
      x = drawGuides(file.depth, from: x, pr, in: context)
      drawChip(
        file.chipText, file.chip.tint, at: x, size: Theme.Layout.editorScmChip, colors,
        in: context)
      x += Theme.Layout.editorScmChip + Theme.Space.note
      let color = scm.badge(file.badgeKind)
      let badgeX = bounds.width - 12 - snap(file.badge.width, .up)
      file.badge.draw(at: badgeX, top: top(file.badge), color, context)
      let limit = badgeX - Theme.Space.note * 2
      let nameWidth = min(snap(file.name.width, .up), max(0, limit - x))
      file.name.draw(at: x, top: top(file.name), width: nameWidth, color, context)
      x += nameWidth + Theme.Space.note
      file.directory?.draw(
        at: x, top: top(file.directory!), width: max(0, limit - x), colors.tertiary, context)
    }
  }

  // MARK: - 小道具

  /// 確認済みのチェック 14（radius 3・枠 1）を描き、その右の位置を返す。付いていれば accent の地にレ点、一部なら薄めた
  /// accent の地に横線、付いていなければ沈んだ地と淡い枠。
  private func drawCheck(_ check: Check, _ pr: PrRowColors, in context: CGContext) -> CGFloat {
    guard let rect = checkRect() else { return 12 }
    let on = check != .off
    context.saveGState()
    if check == .partial { context.setAlpha(0.7) }
    fill(rect, radius: 3, on ? pr.checkOn : pr.checkGround, in: context)
    if !on {
      context.setStrokeColor(pr.checkBorder)
      context.setLineWidth(1)
      context.addPath(
        CGPath(
          roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2.5, cornerHeight: 2.5,
          transform: nil))
      context.strokePath()
    }
    switch check {
    case .on:
      let size: CGFloat = 10
      RowGlyphShape.check.draw(
        in: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
        pr.checkMark, in: context)
    case .partial:
      fill(
        NSRect(x: rect.midX - 3, y: rect.midY - 1, width: 6, height: 2), radius: 1, pr.checkMark,
        in: context)
    case .off: break
    }
    context.restoreGState()
    return rect.maxX + Theme.Space.note
  }

  /// 字下げの線（1 段 8・右に hairline・その後 6 の空き）を `depth` 段描き、その右の位置を返す。
  private func drawGuides(_ depth: Int, from x: CGFloat, _ pr: PrRowColors, in context: CGContext)
    -> CGFloat
  {
    var x = x
    for _ in 0..<depth {
      context.setFillColor(pr.guide)
      context.fill(
        NSRect(x: x + Theme.Layout.editorPrGuide - 1, y: 0, width: 1, height: bounds.height))
      x += Theme.Layout.editorPrGuide + Theme.Layout.editorPrGuideGap
    }
    return x
  }

  /// `dimmed` なら中身を .55 に薄めて描く。
  private func dimming(_ dimmed: Bool, in context: CGContext, _ body: () -> Void) {
    guard dimmed else { return body() }
    context.saveGState()
    context.setAlpha(0.55)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    context.endTransparencyLayer()
    context.restoreGState()
  }
}
