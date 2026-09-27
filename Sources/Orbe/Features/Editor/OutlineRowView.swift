import AppKit
import OrbeEditorCore

/// アウトラインの 1 行: 左 4 ＋ 深さ × 16・シェブロン 16（子があるときだけ。無ければ同じ幅を空ける）・シンボルチップ 14・
/// gap 6・名前（12.5 `editor.text`、選ばれた行は `text.primary`。絞り込みで一致した字は太字の `accent.bright`）。文字は
/// CoreText の行で持ち、中身が変わったときだけ組み直す。
final class OutlineRowView: ListRowView {
  private struct Content {
    let row: EditorOutline.Row
    let chip: SymbolChip
    let chipText: TextLine
    let name: TextLine
  }

  private var content: Content?
  private var emoji: NSFont?
  /// 一致の強調を入れた名前（絞り込み中だけ）と、それを組んだ外観（強調の色は組むときに解く）。
  private var highlighted: (line: TextLine, dark: Bool)?

  /// シェブロンの左端（深さ `depth` の行の中の横の位置）。
  static func chevronX(depth: Int) -> CGFloat {
    Theme.Layout.editorOutlineInset + CGFloat(depth) * Theme.Layout.editorOutlineIndent
  }

  /// 行の中の横の位置 `x` がシェブロンの上か。
  static func isOnChevron(_ x: CGFloat, depth: Int) -> Bool {
    let left = chevronX(depth: depth)
    return x >= left && x < left + Theme.Layout.editorChevron
  }

  /// 最初の行を描く前に 1 度だけ要る準備（色の解決・字体の読み込み）。
  static func prepare(for appearance: NSAppearance) {
    _ = RowColors.of(appearance)
    TextLine.prepare([
      Theme.Typography.editorOutlineName, Theme.Typography.editorOutlineMatch, chipFont,
    ])
  }

  private static let chipFont = Theme.Typography.editorChip(size: 8)

  func show(_ row: EditorOutline.Row, emoji: NSFont?) {
    guard row != content?.row || emoji !== self.emoji else { return }
    self.emoji = emoji
    let chip = SymbolChip.of(row.kind)
    content = Content(
      row: row, chip: chip, chipText: TextLine(chip.glyph, Self.chipFont),
      name: TextLine(row.name, Theme.Typography.editorOutlineName, glyphs: .chrome(emoji: emoji)))
    highlighted = nil
    setAccessibilityLabel(row.name)
    needsDisplay = true
  }

  /// 一致した字を太字の `accent.bright` にした名前（他の字の色は描くときに当てる）。
  private func highlightedName(_ row: EditorOutline.Row, dark: Bool) -> TextLine {
    if let highlighted, highlighted.dark == dark { return highlighted.line }
    var color = Theme.Color.accentBright.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance {
      color = Theme.Color.accentBright.cgColor
    }
    let name = NSMutableAttributedString(
      attributedString: TitleGlyphs.nsAttributed(
        row.name, base: Theme.Typography.editorOutlineName, emoji: emoji,
        attributes: [TextLine.contextColor: true]))
    for match in row.matches where match.upperBound <= name.length {
      name.addAttributes(
        [
          .font: Theme.Typography.editorOutlineMatch, TextLine.contextColor: false,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ], range: NSRange(match))
    }
    let line = TextLine(attributed: name, font: Theme.Typography.editorOutlineName)
    highlighted = (line, dark)
    return line
  }

  override func drawContent(_ colors: RowColors, in context: CGContext) {
    guard let content else { return }
    let row = content.row
    var x = Self.chevronX(depth: row.depth)
    if row.hasChildren {
      drawChevron(
        at: x, size: Theme.Layout.editorChevron, open: row.isExpanded, colors.muted, in: context)
    }
    x += Theme.Layout.editorChevron
    drawChip(content.chipText, content.chip.tint, at: x, radius: 2, colors, in: context)
    x += Theme.Layout.editorChip + Theme.Space.note
    let width = max(0, bounds.width - Theme.Space.step - x)
    let color = isSelected ? colors.primary : colors.text
    let name =
      row.matches.isEmpty
      ? content.name
      : highlightedName(
        row, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    name.draw(at: x, top: top(name), width: width, color, context)
  }
}
