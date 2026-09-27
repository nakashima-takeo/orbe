import AppKit
import OrbeEditorCore

/// 結果の 1 行（見出しか一致）。地（選択は selectionFill。焦点の有無で色を変えず、表の選択の強調は使わない）と中身を行の
/// view が自分で描く（列ごとの view を置かない——行を入れ替えるたびの view と layer の出し入れを半分にする）。文字は CoreText
/// の行で持ち、中身が変わったときだけ組み直して描き直す。VoiceOver には行の中身の文字列を渡す。
final class SearchResultRowView: NSTableRowView {
  static let identifier = NSUserInterfaceItemIdentifier("searchResultRow")
  static let fileHeight = Theme.Layout.editorSearchFileRow
  static let matchHeight = Theme.Layout.editorSearchMatchRow

  /// 描いている中身の同一性（同じなら組み直さない）。
  private enum Key: Equatable {
    case file(ProjectSearch.RowID, count: Int, isCollapsed: Bool)
    case match(ProjectSearch.RowID, SearchPreview)
  }

  private enum Content {
    case file(FileContent)
    case match(MatchContent)
  }

  private struct FileContent {
    let isCollapsed: Bool
    let chip: FileChip
    let chipText: TextLine
    let name: TextLine
    let directory: TextLine
    let count: TextLine
  }

  private struct MatchContent {
    /// 前（行末の空白を除く）と、その空白の幅。行末の空白は省略の計算で幅に入らないので、間として別に取っておく。
    let before: TextLine
    let beforeGap: CGFloat
    let match: TextLine
    let after: TextLine
  }

  private var key: Key?
  private var emoji: NSFont?
  private var content: Content?

  private static let countFill = EditorStyle.fill(0.10)
  private static let hitFill = Theme.Color.editorModified.withAlphaComponent(0.30)
  private static let hitRadius: CGFloat = 2
  private static let countPadding: CGFloat = 5
  private static let matchEllipsisWidth = TextLine.ellipsisWidth(
    Theme.Typography.editorSearchMatch)

  override init(frame: NSRect) {
    super.init(frame: frame)
    identifier = Self.identifier
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override var isSelected: Bool {
    didSet { if isSelected != oldValue { needsDisplay = true } }
  }

  override func drawBackground(in dirtyRect: NSRect) {
    guard isSelected else { return }
    Theme.Color.selectionFill.setFill()
    bounds.fill()
  }

  func show(_ row: ProjectSearch.Row, emoji: NSFont?) {
    let key: Key
    switch row {
    case .file(let file, let isCollapsed):
      key = .file(row.id, count: file.count, isCollapsed: isCollapsed)
    case .match(_, _, let match):
      key = .match(row.id, match.preview)
    }
    guard key != self.key || emoji !== self.emoji else { return }
    self.key = key
    self.emoji = emoji
    switch row {
    case .file(let file, let isCollapsed):
      let name = (file.path as NSString).lastPathComponent
      let directory = (file.path as NSString).deletingLastPathComponent
      let chip = FileChip.resolve(URL(fileURLWithPath: file.path))
      content = .file(
        FileContent(
          isCollapsed: isCollapsed, chip: chip,
          chipText: TextLine(
            chip.glyph,
            Theme.Typography.editorChip(size: chip.fontSize(for: Theme.Layout.editorChip)),
            chip.hue?.color ?? Theme.Color.textPrimary),
          name: TextLine(
            name, Theme.Typography.editorSearchFile, Theme.Color.textPrimary, emoji: emoji),
          directory: TextLine(
            directory, Theme.Typography.editorSearchDirectory, Theme.Color.editorTertiary,
            emoji: emoji),
          count: TextLine(
            file.count.formatted(), Theme.Typography.editorSearchCount,
            Theme.Color.textSecondary)))
      setAccessibilityLabel(
        [name, directory, "\(file.count)"].filter { !$0.isEmpty }.joined(separator: ", "))
    case .match(_, _, let match):
      let font = Theme.Typography.editorSearchMatch
      let preview = match.preview
      let bodyEnd =
        preview.before.lastIndex { $0 != " " }.map { preview.before.index(after: $0) }
        ?? preview.before.startIndex
      let beforeBody = String(preview.before[..<bodyEnd])
      let beforeSpaces = String(preview.before[bodyEnd...])
      content = .match(
        MatchContent(
          before: TextLine(beforeBody, font, Theme.Color.editorTertiary),
          beforeGap: TextLine(beforeSpaces, font, Theme.Color.editorTertiary).width,
          match: TextLine(preview.match, font, Theme.Color.textPrimary),
          after: TextLine(preview.after, font, Theme.Color.textMuted)))
      setAccessibilityLabel(preview.before + preview.match + preview.after)
    }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    switch content {
    case .file(let file): draw(file, in: context)
    case .match(let match): draw(match, in: context)
    case nil: break
    }
  }

  /// 見出し 22: シェブロン（畳むと右向き）・種別チップ 14・ファイル名 12・ディレクトリ 10.5 tertiary・右端の件数。間は 6。
  /// 列が狭いときはファイル名を先に取り、ディレクトリは頭を省略して残りに詰める。
  private func draw(_ file: FileContent, in context: CGContext) {
    let gap = Theme.Space.note
    var x = Theme.Space.beat
    drawChevron(at: x, open: !file.isCollapsed, in: context)
    x += Theme.Layout.editorSearchChevron + gap
    drawChip(file, at: x, in: context)
    x += Theme.Layout.editorChip + gap

    let badgeWidth = max(
      Theme.Layout.editorSearchCountWidth, snap(file.count.width, .up) + Self.countPadding * 2)
    let badgeHeight = max(Theme.Layout.editorSearchCountHeight, snap(file.count.height))
    let badge = NSRect(
      x: bounds.width - Theme.Space.beat - badgeWidth, y: snap((bounds.height - badgeHeight) / 2),
      width: badgeWidth, height: badgeHeight)
    Self.countFill.setFill()
    NSBezierPath(roundedRect: badge, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()
    file.count.draw(
      at: snap(badge.midX - file.count.width / 2), top: snap(badge.midY - file.count.height / 2),
      context)

    // 名前とディレクトリの間、ディレクトリと件数の間（伸びる余白の両側）にも間を置く。
    let limit = badge.minX - gap * 2
    let nameWidth = min(snap(file.name.width, .up), max(0, limit - x))
    file.name.draw(at: x, top: top(file.name), width: nameWidth, truncating: .end, context)
    x += nameWidth + gap
    let directoryWidth = min(snap(file.directory.width, .up), limit - x)
    file.directory.draw(
      at: x, top: top(file.directory), width: directoryWidth, truncating: .start, context)
  }

  /// 一致の行 20（左 40・mono 11）: 前 tertiary、ヒット（地 tint(modified, .30) 角 2・文字 primary）、後ろ muted。
  /// 列が狭いときは、前と後ろに省略記号 1 つぶんを残して、後ろ → 前（頭を省略）→ ヒットの順に詰める。
  private func draw(_ match: MatchContent, in context: CGContext) {
    let ellipsis = Self.matchEllipsisWidth
    let x = Theme.Layout.editorSearchMatchIndent
    let room = max(0, bounds.width - Theme.Space.beat - x)
    let before = snap(match.before.width + match.beforeGap, .up)
    let after = snap(match.after.width, .up)
    let afterMin = min(after, ellipsis)
    let matchWidth = min(
      snap(match.match.width, .up), max(0, room - min(before, ellipsis) - afterMin))
    let beforeWidth = min(before, max(0, room - matchWidth - afterMin))

    let top = top(match.match)
    var beforeUsed = beforeWidth
    if let body = match.before.fitted(beforeWidth - match.beforeGap, truncating: .start) {
      match.before.draw(body, at: x, top: top, context)
      // 頭を省いた前は省いた後の幅だけを取り、余りは後ろへ回す（SwiftUI の Text と同じ）。
      beforeUsed = snap(TextLine.width(of: body) + match.beforeGap, .up)
    }
    let afterWidth = min(after, room - beforeUsed - matchWidth)
    let hitLeft = x + beforeUsed
    let hitRight = hitLeft + matchWidth
    let hit = NSRect(
      x: hitLeft, y: top, width: hitRight - hitLeft, height: snap(match.match.height))
    Self.hitFill.setFill()
    NSBezierPath(roundedRect: hit, xRadius: Self.hitRadius, yRadius: Self.hitRadius).fill()
    match.match.draw(at: hitLeft, top: top, width: matchWidth, truncating: .end, context)
    match.after.draw(at: hitRight, top: top, width: afterWidth, truncating: .end, context)
  }

  /// 装置の画素へ揃える（SwiftUI が view の枠を揃えるのと同じ。字と地が半画素ずれない）。
  private func snap(
    _ value: CGFloat, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
  ) -> CGFloat {
    let scale = window?.backingScaleFactor ?? 2
    return (value * scale).rounded(rule) / scale
  }

  /// 行の縦の中央に置いたときの上端。
  private func top(_ text: TextLine) -> CGFloat {
    snap((bounds.height - text.height) / 2)
  }

  /// シェブロンの線（`EditorGlyphs.chevron` を `editorSearchChevron` 角へ）と線の幅。
  private static let chevron: (path: CGPath, lineWidth: CGFloat) = {
    let glyph = EditorGlyphs.chevron
    let k = Theme.Layout.editorSearchChevron / glyph.viewBox
    let path = CGMutablePath()
    for part in glyph.parts(k) { path.addPath(part.path.cgPath) }
    return (path, glyph.stroke * k)
  }()

  /// シェブロン（開いていると 90° 回す）。
  private func drawChevron(at x: CGFloat, open: Bool, in context: CGContext) {
    let size = Theme.Layout.editorSearchChevron
    context.saveGState()
    context.translateBy(x: x + size / 2, y: bounds.height / 2)
    if open { context.rotate(by: .pi / 2) }
    context.translateBy(x: -size / 2, y: -size / 2)
    context.setStrokeColor(Theme.Color.textMuted.cgColor)
    context.setLineWidth(Self.chevron.lineWidth)
    context.addPath(Self.chevron.path)
    context.strokePath()
    context.restoreGState()
  }

  /// 種別チップ 14（`FileChipView` と同じ規則を AppKit で描く）。
  private func drawChip(_ file: FileContent, at x: CGFloat, in context: CGContext) {
    let size = Theme.Layout.editorChip
    let rect = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
    let ground =
      file.chip.hue.map { $0.color.withAlphaComponent(FileChipView.groundAlpha) }
      ?? EditorStyle.fill(FileChipView.groundAlpha)
    ground.setFill()
    NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.xs, yRadius: Theme.Radius.xs).fill()
    file.chipText.draw(
      at: snap(rect.midX - file.chipText.width / 2),
      top: snap(rect.midY - file.chipText.height / 2), context)
  }
}

/// 1 行の文字列（CoreText の行と寸法）。色は描くときに文脈の塗りから当てる（外観で解ける動的な色のまま持つ）。
private struct TextLine {
  let line: CTLine
  let font: NSFont
  let color: NSColor
  let width: CGFloat
  /// 箱の上端から基線まで。
  let ascent: CGFloat
  /// 行の箱の高さ。縦の中央に置くときの箱。
  let height: CGFloat

  init(_ text: String, _ font: NSFont, _ color: NSColor, emoji: NSFont? = nil) {
    let attributed = TitleGlyphs.nsAttributed(
      text, base: font, emoji: emoji, attributes: Self.drawing)
    line = CTLineCreateWithAttributedString(attributed)
    self.font = font
    self.color = color
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    // 行の箱は TextKit（SwiftUI の Text）と同じ丸め——基線は ascent を丸めた位置、高さはそこへ descent の切り上げを足す。
    // 字の位置が SwiftUI で描いていた他の面の字と半画素ずれない。
    self.ascent = ascent.rounded()
    height = self.ascent + descent.rounded(.up) + leading
  }

  private static let drawing: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
  ]

  static func ellipsisWidth(_ font: NSFont) -> CGFloat {
    TextLine("…", font, .clear).width
  }

  /// 省略記号の行（省くことのある字体ごと）。
  private static let ellipses: [NSFont: CTLine] = Dictionary(
    uniqueKeysWithValues: [
      Theme.Typography.editorSearchFile, Theme.Typography.editorSearchDirectory,
      Theme.Typography.editorSearchMatch,
    ].map { font in
      (
        font,
        CTLineCreateWithAttributedString(
          NSAttributedString(string: "…", attributes: drawing.merging([.font: font]) { $1 }))
      )
    })

  static func width(of line: CTLine) -> CGFloat {
    CTLineGetTypographicBounds(line, nil, nil, nil)
  }

  /// 幅 `width` に収めた行（溢れは `truncating` の側を省略記号で省く。何も入らなければ nil）。
  func fitted(_ width: CGFloat, truncating: CTLineTruncationType) -> CTLine? {
    guard width > 0 else { return nil }
    guard self.width > width else { return line }
    return CTLineCreateTruncatedLine(line, Double(width), truncating, Self.ellipses[font])
  }

  /// 幅 `width` に収めて描く。
  func draw(
    at x: CGFloat, top: CGFloat, width: CGFloat, truncating: CTLineTruncationType,
    _ context: CGContext
  ) {
    if let fitted = fitted(width, truncating: truncating) { draw(fitted, at: x, top: top, context) }
  }

  /// 省かずに描く。
  func draw(at x: CGFloat, top: CGFloat, _ context: CGContext) {
    draw(line, at: x, top: top, context)
  }

  /// この文字列の行（か、それを省いた行）を、上端 `top` の箱に描く。
  func draw(_ line: CTLine, at x: CGFloat, top: CGFloat, _ context: CGContext) {
    context.saveGState()
    context.setFillColor(color.cgColor)
    // 反転した view の座標（y が下向き）で字を正立させる。
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: x, y: top + ascent)
    CTLineDraw(line, context)
    context.restoreGState()
  }
}
