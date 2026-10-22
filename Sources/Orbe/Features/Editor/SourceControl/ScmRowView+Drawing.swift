import AppKit

/// 変更の列の行の描き方（寸法と色は見本 ScmPanel の値。子の区分の字下げと、それに合わせたファイル行の左は見本に無い〔人の
/// 決定 H20〕）。
extension ScmRowView {
  /// 子の見出し 22（padding 0 12 0 12——親の見出しの 4 から 1 段字下げ）: シェブロン 16・題 11 bold・右端に一括操作と件数
  /// バッジ。
  func draw(
    _ header: Header, _ colors: RowColors, _ scm: ScmRowColors, in context: CGContext
  ) {
    if isHovered, !isSelected {
      context.setFillColor(scm.headerHover)
      context.fill(bounds)
    }
    let chevron = Theme.Layout.editorChevron
    let indent = Theme.Space.tick + Theme.Layout.editorScmIndent
    (header.isOpen ? ScmGlyphShape.chevronOpen : .chevron).draw(
      in: NSRect(x: indent, y: bounds.midY - chevron / 2, width: chevron, height: chevron),
      scm.icon, in: context)
    let rects = buttonRects()
    let width = countWidth(header.count)
    let height = Theme.Layout.editorSearchCountHeight
    let badge = NSRect(
      x: bounds.width - 12 - width, y: snap(bounds.midY - height / 2), width: width,
      height: height)
    fill(badge, radius: height / 2, scm.countStrong, in: context)
    header.count.draw(
      at: snap(badge.midX - header.count.width / 2),
      top: snap(badge.midY - header.count.height / 2), colors.primary, context)
    let right = (rects.first?.1.minX ?? badge.minX) - Theme.Space.note
    drawButtons(rects, tool: true, colors, scm, in: context)
    let x = indent + chevron
    header.label.draw(
      at: x, top: top(header.label), width: max(0, right - x), colors.text, context)
  }

  /// ファイル行 22（padding 0 12 0 28——見本の 20 から子の区分の字下げぶん右。種別チップが子の題の真下に揃う・gap 6）:
  /// 種別チップ 16・名前 13（バッジの色）・ディレクトリ 11 tertiary・右端に行のボタン 18（常に出す）とバッジの字。名前を
  /// 先に取り、ディレクトリは残りに詰める（右のボタンとの間は、伸びる余白の両側の gap で 12）。
  func draw(_ file: File, _ colors: RowColors, _ scm: ScmRowColors, in context: CGContext) {
    if isHovered, !isSelected {
      context.setFillColor(scm.fileHover)
      context.fill(bounds)
    }
    let gap = Theme.Space.note
    var x: CGFloat = 20 + Theme.Layout.editorScmIndent
    drawChip(
      file.chipText, file.chip.tint, at: x, size: Theme.Layout.editorScmChip, colors, in: context)
    x += Theme.Layout.editorScmChip + gap
    let badgeX = bounds.width - 12 - snap(file.badge.width, .up)
    let color = scm.badge(file.badgeKind)
    file.badge.draw(at: badgeX, top: top(file.badge), color, context)
    let rects = buttonRects()
    drawButtons(rects, tool: false, colors, scm, in: context)
    let limit = (rects.first?.1.minX ?? badgeX) - gap * 2
    let nameWidth = min(snap(file.name.width, .up), max(0, limit - x))
    file.name.draw(at: x, top: top(file.name), width: nameWidth, color, context)
    x += nameWidth + gap
    file.directory.draw(
      at: x, top: top(file.directory), width: max(0, limit - x), colors.tertiary, context)
  }

  /// 行の中のボタン（見出しのツールは 20・radius 4・hover 地 fill .08 で字が上がる、行のボタンは 18・radius 3・hover 地
  /// fill .10）。押せない姿は地を付けず、字をツールは muted .35、行のボタンは editor.text .3 にする。
  private func drawButtons(
    _ rects: [(Button, NSRect)], tool: Bool, _ colors: RowColors, _ scm: ScmRowColors,
    in context: CGContext
  ) {
    for (button, rect) in rects {
      let hovered = button.isEnabled && pointer.map(rect.contains) == true
      if hovered {
        fill(
          rect, radius: tool ? Theme.Radius.sm : Theme.Radius.xs,
          tool ? scm.toolHover : scm.buttonHover, in: context)
      }
      let color =
        !button.isEnabled
        ? (tool ? scm.toolDisabled : scm.buttonDisabled)
        : tool ? (hovered ? colors.text : colors.muted) : colors.text
      let size = Theme.Layout.editorScmGlyph
      button.glyph.draw(
        in: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
        color, in: context)
    }
  }
}
