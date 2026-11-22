import SwiftUI

/// キーの札（デザインの見本の `kbd`）。中身は字（`⌘P`・`esc`・`v`）か印（`EditorGlyphs` の印）。寸法・地の濃さ・字の大きさと
/// 太さは `Theme` のトークンで、AppKit の描画も同じトークンを読む。地と中身の色は使う側が替えられる（既定は地 `surfaceInk`
/// .07・中身 `text.secondary`）。
struct EditorKeyCap: View {
  enum Content {
    case text(String)
    case glyph(EditorGlyphs.Glyph)
  }

  let content: Content
  var foreground = Color.theme.textSecondary
  var ground = Color.theme.surfaceInk.opacity(Theme.Opacity.editorKeyCap)

  var body: some View {
    label
      .padding(.horizontal, Theme.Layout.editorKeyCapPadX)
      .frame(minWidth: Theme.Layout.editorKeyCap, minHeight: Theme.Layout.editorKeyCap)
      .background(RoundedRectangle(cornerRadius: Theme.Layout.editorKeyCapRadius).fill(ground))
  }

  @ViewBuilder private var label: some View {
    switch content {
    case .text(let text):
      Text(text)
        .font(Font.theme.editorKeyCap)
        .foregroundStyle(foreground)
    case .glyph(let glyph):
      EditorGlyphView(glyph: glyph, size: Theme.Layout.editorKeyCapGlyph, color: foreground)
    }
  }
}
