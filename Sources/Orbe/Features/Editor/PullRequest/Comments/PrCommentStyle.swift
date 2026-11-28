import AppKit
import OrbeEditorCore

/// PR のコメントの絵の見え方——返信欄の見え方・行の頭のコメントの印・短い字の幅の覚え。
@MainActor
enum PrCommentStyle {
  static let field = ZoneTextField.Style(
    font: Theme.Typography.editorPrReplyField, lineHeight: Theme.Typography.editorPrReplyFieldLine,
    textColor: Theme.Color.textPrimary, caretColor: Theme.Color.accentBright,
    selectionColor: Theme.Color.editorPrFieldSelection,
    inactiveSelectionColor: Theme.Color.editorPrFieldSelectionInactive)

  /// 行の頭のコメントの印——頭の列 24・線 3（accent の α .55）と、ポインタの下の行の ＋（16×16・角丸 4・地 accent・中の ＋
  /// 10、線 1.5）。引いている範囲は、書いている範囲の上書き。
  nonisolated(unsafe) static let leadingMark: LeadingMark = {
    let size = Theme.Layout.editorPrMarkButton
    return LeadingMark(
      width: Theme.Layout.editorPrMarkColumn, lineWidth: Theme.Layout.editorPrMarkLineWidth,
      lineColor: Theme.Color.editorPrMarkLine, size: CGSize(width: size, height: size),
      image: markImage(), dragOverride: DiffStyle.draftOverride)
  }()

  private nonisolated static func markImage() -> NSImage {
    let size = Theme.Layout.editorPrMarkButton
    return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
      Theme.Color.accentPrimary.setFill()
      let radius = Theme.Layout.editorPrMarkButtonRadius
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      let half = Theme.Layout.editorPrMarkPlus / 2
      let path = NSBezierPath()
      path.move(to: CGPoint(x: rect.midX, y: rect.midY - half))
      path.line(to: CGPoint(x: rect.midX, y: rect.midY + half))
      path.move(to: CGPoint(x: rect.midX - half, y: rect.midY))
      path.line(to: CGPoint(x: rect.midX + half, y: rect.midY))
      path.lineWidth = Theme.Layout.editorPrMarkPlusStroke
      path.lineCapStyle = .round
      Theme.Color.accentCheckStroke.setStroke()
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
