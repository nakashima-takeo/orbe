import AppKit
import OrbeEditorCore

/// PR のコメントの絵の見え方——返信欄の見え方・コメント追加の印の絵・短い字の幅の覚え。
@MainActor
enum PrCommentStyle {
  static let field = ZoneTextField.Style(
    font: Theme.Typography.editorPrReplyField, lineHeight: Theme.Typography.editorPrReplyFieldLine,
    textColor: Theme.Color.textPrimary, caretColor: Theme.Color.accentBright,
    selectionColor: Theme.Color.editorPrFieldSelection,
    inactiveSelectionColor: Theme.Color.editorPrFieldSelectionInactive)

  /// 行の右端のコメント追加の印（18×18・角丸 3・中の ＋ 11、線 1.4）。通常は tertiary の ＋ を不透明度 .6、ポインタが印の
  /// 上にあれば tint(accent, .16) の地に accentBright の ＋。
  nonisolated(unsafe) static let trailingMark: TrailingMark = {
    let size = Theme.Layout.editorPrMark
    return TrailingMark(
      size: CGSize(width: size, height: size), inset: Theme.Layout.editorPrMarkInset,
      image: markImage(ground: nil, glyph: Theme.Color.editorTertiary.withAlphaComponent(0.6)),
      hoveredImage: markImage(
        ground: Theme.Color.editorPrMarkHover, glyph: Theme.Color.accentBright))
  }()

  private nonisolated static func markImage(ground: NSColor?, glyph: NSColor) -> NSImage {
    let size = Theme.Layout.editorPrMark
    return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
      if let ground {
        ground.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
      }
      let glyphSize = Theme.Layout.editorPrMarkGlyph
      let k = glyphSize / 16
      let origin = CGPoint(x: rect.midX - glyphSize / 2, y: rect.midY - glyphSize / 2)
      let path = NSBezierPath()
      path.move(to: CGPoint(x: origin.x + 8 * k, y: origin.y + 4 * k))
      path.line(to: CGPoint(x: origin.x + 8 * k, y: origin.y + 12 * k))
      path.move(to: CGPoint(x: origin.x + 4 * k, y: origin.y + 8 * k))
      path.line(to: CGPoint(x: origin.x + 12 * k, y: origin.y + 8 * k))
      path.lineWidth = 1.4 * k
      path.lineCapStyle = .round
      glyph.setStroke()
      path.stroke()
      return true
    }
  }

  /// 字の連なり 1 つの幅（行末の空白を除く）。字体ごとに覚える——頭の文言・書いた人・時刻は数が限られ、ホバーの描き直しの
  /// たびに字を組まない。
  static func width(_ string: String, _ font: NSFont) -> CGFloat {
    let key = WidthKey(string: string, font: font.fontName, size: font.pointSize)
    if let width = widths[key] { return width }
    let width = ZoneTextLayout.width([ZoneTextRun(string, font: font, color: .black)])
    widths[key] = width
    return width
  }

  private struct WidthKey: Hashable {
    let string: String
    let font: String
    let size: CGFloat
  }

  private static var widths: [WidthKey: CGFloat] = [:]

  /// 高さ `height` の行の中で、字を縦の中央に置く基線（CSS の行の半分の余白と同じ）。
  nonisolated static func baseline(top: CGFloat, height: CGFloat, font: NSFont) -> CGFloat {
    top + (height - (font.ascender - font.descender)) / 2 + font.ascender
  }
}
