import AppKit

/// 一覧の器の 1 行（見出し・ファイル・操作）を描く。文字は CoreText の行で持ち、中身が変わったときだけ組み直す。選択と
/// ホバーの地は角丸。ファイルの行の右の印の枠は押せる部品（×）で、未保存・ディスクが変わったの丸は、枠をホバーしている
/// 間だけ × に替わる。選べない操作の行は、題とキーの札を design-system の押せない姿に薄める。
final class EditorItemListRowView: ListRowView {
  private enum Content {
    case heading(title: TextLine, count: TextLine, key: TextLine?)
    case file(FileContent)
    case action(title: TextLine, key: TextLine?)
  }

  private struct FileContent {
    let chip: FileChip
    let chipText: TextLine
    let name: TextLine
    let isDimmed: Bool
    let directory: TextLine
    let tags: [TextLine]
    let mark: EditorItemListRow.Mark
    let badge: (text: TextLine, kind: GitStatus.Badge)?
    let closeLabel: String?
  }

  private var key: EditorItemListRow?
  private var emoji: NSFont?
  private var content: Content?
  /// 選べる行か（選べない行にはホバーの地を付けない）。
  private var isSelectable = false

  /// 最初の行を描く前に 1 度だけ要る準備（色の解決・字体の初回の字組み）。
  static func prepare(for appearance: NSAppearance) {
    _ = RowColors.of(appearance)
    _ = ScmRowColors.of(appearance)
    _ = ItemListColors.of(appearance)
    TextLine.prepare([
      Theme.Typography.editorItemListHeading, Theme.Typography.editorItemListCount,
      Theme.Typography.editorItemListName, italicName, Theme.Typography.editorItemListDirectory,
      Theme.Typography.editorItemListBadge, Theme.Typography.editorItemListAction,
      Theme.Typography.editorTag, Theme.Typography.editorKeyCap,
    ])
  }

  private static let italicName = NSFontManager.shared.convert(
    Theme.Typography.editorItemListName, toHaveTrait: .italicFontMask)

  func show(_ row: EditorItemListRow, selectable: Bool, emoji: NSFont?) {
    if selectable != isSelectable {
      isSelectable = selectable
      needsDisplay = true
    }
    guard row != key || emoji !== self.emoji else { return }
    key = row
    self.emoji = emoji
    switch row {
    case .heading(let title, let count, let key):
      content = .heading(
        title: TextLine(title, Theme.Typography.editorItemListHeading),
        count: TextLine(count.formatted(), Theme.Typography.editorItemListCount),
        key: key.map { TextLine($0, Theme.Typography.editorKeyCap) })
      setAccessibilityLabel("\(title) \(count)")
    case .file(let file):
      content = .file(Self.content(file, emoji: emoji))
      setAccessibilityLabel(
        ([file.name, file.directory] + file.tags + [file.markLabel ?? ""])
          .filter { !$0.isEmpty }.joined(separator: ", "))
    case .action(let title, let key):
      content = .action(
        title: TextLine(title, Theme.Typography.editorItemListAction),
        key: key.map { TextLine($0, Theme.Typography.editorKeyCap) })
      setAccessibilityLabel(title)
    }
    needsDisplay = true
  }

  private static func content(_ file: EditorItemListRow.File, emoji: NSFont?) -> FileContent {
    let chipFont = Theme.Typography.editorChip(
      size: file.chip.fontSize(for: Theme.Layout.editorChip))
    return FileContent(
      chip: file.chip, chipText: TextLine(file.chip.glyph, chipFont),
      name: TextLine(
        file.name, file.isItalic ? italicName : Theme.Typography.editorItemListName,
        glyphs: .chrome(emoji: emoji)),
      isDimmed: file.isDimmed,
      directory: TextLine(
        file.directory, Theme.Typography.editorItemListDirectory, glyphs: .chrome(emoji: emoji),
        truncating: .start),
      tags: file.tags.map { TextLine($0, Theme.Typography.editorTag) }, mark: file.mark,
      badge: file.badge.map { (TextLine($0.label, Theme.Typography.editorItemListBadge), $0) },
      closeLabel: file.closeLabel)
  }

  // MARK: - 寸法

  /// 右の印の枠（ファイルの行だけ）。
  var markRect: NSRect? {
    guard case .file = content else { return nil }
    let size = Theme.Layout.editorItemListMark
    let right =
      bounds.width - Theme.Layout.editorItemListRowPadX - Theme.Layout.editorItemListBadge
      - Theme.Layout.editorItemListRowGap
    return NSRect(x: right - size, y: (bounds.height - size) / 2, width: size, height: size)
  }

  private var isMarkHovered: Bool {
    guard let pointer, let markRect else { return false }
    return markRect.contains(pointer)
  }

  override func control(at point: NSPoint) -> ListRowControl? {
    guard case .file(let file) = content, file.mark != .none, let markRect,
      markRect.contains(point)
    else { return nil }
    return ListRowControl(id: 0, frame: markRect, isEnabled: true)
  }

  override func help(at point: NSPoint) -> String? {
    guard control(at: point) != nil, case .file(let file) = content else { return nil }
    return file.closeLabel
  }

  /// ポインタが乗っている部分（行・印の枠）が変わったときだけ描き直す。
  override func pointerDidChange(from old: NSPoint?) {
    let hovered = { (point: NSPoint?) -> (row: Bool, mark: Bool) in
      guard let point else { return (false, false) }
      return (self.bounds.contains(point), self.markRect?.contains(point) == true)
    }
    if hovered(old) != hovered(pointer) { needsDisplay = true }
  }

  // MARK: - 描画

  override func drawSelection(_ color: CGColor, in context: CGContext) {
    fill(bounds, radius: Theme.Layout.editorItemListRowRadius, color, in: context)
  }

  override func drawContent(_ colors: RowColors, in context: CGContext) {
    let item = ItemListColors.of(effectiveAppearance)
    if isSelectable, !isSelected, pointer.map(bounds.contains) == true {
      fill(bounds, radius: Theme.Layout.editorItemListRowRadius, item.hover, in: context)
    }
    switch content {
    case .heading(let title, let count, let key):
      drawHeading(title, count, key, colors, in: context)
    case .file(let file):
      draw(file, colors, item, in: context)
    case .action(let title, let key):
      drawAction(title, key, colors, in: context)
    case nil:
      break
    }
  }

  /// 見出し: 題（sans 10.5 semibold・muted）・数（mono 10.5）・右端にキーの札。
  private func drawHeading(
    _ title: TextLine, _ count: TextLine, _ key: TextLine?, _ colors: RowColors,
    in context: CGContext
  ) {
    var x = Theme.Layout.editorItemListRowPadX
    title.draw(at: x, top: top(title), colors.muted, context)
    x += snap(title.width, .up) + Theme.Space.note
    count.draw(at: x, top: top(count), colors.muted, context)
    if let key { drawKeyCap(key, right: Theme.Layout.editorItemListRowPadX, colors, in: context) }
  }

  /// 操作: 題（左右の余白 10）・右端にキーの札。題は札の手前で省く。
  private func drawAction(
    _ title: TextLine, _ key: TextLine?, _ colors: RowColors, in context: CGContext
  ) {
    let padX = Theme.Layout.editorItemListActionPadX
    context.saveGState()
    defer { context.restoreGState() }
    if !isSelectable { context.setAlpha(Theme.Opacity.disabled) }
    let capWidth =
      key.map {
        drawKeyCap($0, right: padX, colors, in: context) + Theme.Layout.editorItemListRowGap
      } ?? 0
    title.draw(
      at: padX, top: top(title), width: max(0, bounds.width - padX * 2 - capWidth),
      colors.primary, context)
  }

  /// キーの札を、行の右端から `right` の位置に右寄せで描き、札の幅を返す。
  @discardableResult
  private func drawKeyCap(
    _ key: TextLine, right: CGFloat, _ colors: RowColors, in context: CGContext
  ) -> CGFloat {
    let size = Theme.Layout.editorKeyCap
    let width = max(size, snap(key.width, .up) + Theme.Layout.editorKeyCapPadX * 2)
    let cap = NSRect(
      x: bounds.width - right - width, y: snap((bounds.height - size) / 2), width: width,
      height: size)
    fill(
      cap, radius: Theme.Layout.editorKeyCapRadius, ItemListColors.of(effectiveAppearance).keyCap,
      in: context)
    key.draw(
      at: snap(cap.midX - key.width / 2), top: snap(cap.midY - key.height / 2), colors.secondary,
      context)
    return width
  }

  /// ファイル: 種別のチップ・名前（先に幅を取る）・ディレクトリ（残りの幅で頭から省く）・札・右に印の枠と状態の字。
  private func draw(
    _ file: FileContent, _ colors: RowColors, _ item: ItemListColors, in context: CGContext
  ) {
    let gap = Theme.Layout.editorItemListRowGap
    var x = Theme.Layout.editorItemListRowPadX
    drawChip(file.chipText, file.chip.tint, at: x, colors, in: context)
    x += Theme.Layout.editorChip + gap
    let markRect = markRect ?? .zero
    drawMark(file, in: markRect, colors, item, in: context)
    if let badge = file.badge {
      let column = NSRect(
        x: markRect.maxX + gap, y: 0, width: Theme.Layout.editorItemListBadge, height: bounds.height
      )
      badge.text.draw(
        at: snap(column.midX - badge.text.width / 2), top: top(badge.text),
        ScmRowColors.of(effectiveAppearance).badge(badge.kind), context)
    }
    let tagWidths = file.tags.map(tagWidth)
    let tagsWidth = tagWidths.reduce(0) { $0 + $1 + gap }
    let limit = markRect.minX - gap
    let nameWidth = min(snap(file.name.width, .up), max(0, limit - x - tagsWidth))
    file.name.draw(
      at: x, top: top(file.name), width: nameWidth, file.isDimmed ? colors.muted : colors.primary,
      context)
    x += nameWidth + gap
    let directoryWidth = min(snap(file.directory.width, .up), max(0, limit - x - tagsWidth))
    if directoryWidth > 0 {
      file.directory.draw(
        at: x, top: top(file.directory), width: directoryWidth, colors.muted, context)
      x += directoryWidth + gap
    }
    for (tag, width) in zip(file.tags, tagWidths) where x + width <= limit {
      drawTag(tag, at: x, width: width, colors, in: context)
      x += width + gap
    }
  }

  private func tagWidth(_ tag: TextLine) -> CGFloat {
    snap(tag.width, .up) + Theme.Layout.editorTagPadX * 2
  }

  /// 札（字 sans 10.5 secondary・1px の枠 `surfaceInk` .2・角丸 4・余白 1 6）。
  private func drawTag(
    _ tag: TextLine, at x: CGFloat, width: CGFloat, _ colors: RowColors, in context: CGContext
  ) {
    let height = snap(tag.height) + Theme.Layout.editorTagPadY * 2
    let rect = NSRect(x: x, y: snap((bounds.height - height) / 2), width: width, height: height)
    let line = Theme.Stroke.hairline
    context.setStrokeColor(ItemListColors.of(effectiveAppearance).tagBorder)
    context.setLineWidth(line)
    let radius = Theme.Layout.editorTagRadius
    context.addPath(
      CGPath(
        roundedRect: rect.insetBy(dx: line / 2, dy: line / 2), cornerWidth: radius,
        cornerHeight: radius, transform: nil))
    context.strokePath()
    tag.draw(at: x + Theme.Layout.editorTagPadX, top: top(tag), colors.secondary, context)
  }

  /// 右の印: × か丸。丸は枠をホバーしている間だけ × に替わる。× はホバーで枠に地が付く。
  private func drawMark(
    _ file: FileContent, in rect: NSRect, _ colors: RowColors, _ item: ItemListColors,
    in context: CGContext
  ) {
    let hovered = isMarkHovered
    let showsClose: Bool
    switch file.mark {
    case .none: return
    case .close: showsClose = true
    case .unsaved, .diskChanged: showsClose = hovered
    }
    guard showsClose else {
      let dot = Theme.Layout.editorItemDot
      context.setFillColor(file.mark == .diskChanged ? item.caution : colors.primary)
      context.fillEllipse(
        in: NSRect(x: rect.midX - dot / 2, y: rect.midY - dot / 2, width: dot, height: dot))
      return
    }
    if hovered {
      fill(rect, radius: Theme.Radius.sm, item.markHover, in: context)
    }
    let size = Theme.Layout.editorItemListMarkGlyph
    RowGlyphShape.close.draw(
      in: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
      hovered ? colors.text : colors.muted, in: context)
  }
}

/// 一覧の器の行だけが使う色（行に共通の色は `RowColors`）。外観ごとに 1 度だけ解いて使い回す。
struct ItemListColors {
  /// 行のホバーの地と、右の印の枠のホバーの地。
  let hover: CGColor
  let markHover: CGColor
  /// キーの札の地。
  let keyCap: CGColor
  /// 札の枠。
  let tagBorder: CGColor
  /// ディスクが変わったの丸。
  let caution: CGColor

  @MainActor private static let resolved = PerAppearance { ItemListColors() }

  @MainActor static func of(_ appearance: NSAppearance) -> ItemListColors { resolved(appearance) }

  private init() {
    hover = EditorStyle.fill(Theme.Opacity.editorItemListHover).cgColor
    markHover = EditorStyle.fill(Theme.Opacity.editorItemListMarkHover).cgColor
    keyCap = Theme.Color.surfaceInk.withAlphaComponent(Theme.Opacity.editorKeyCap).cgColor
    tagBorder = Theme.Color.surfaceInk.withAlphaComponent(Theme.Opacity.editorTag).cgColor
    caution = Theme.Color.editorCaution.cgColor
  }
}
