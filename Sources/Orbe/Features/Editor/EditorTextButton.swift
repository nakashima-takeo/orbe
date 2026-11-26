import SwiftUI

/// 字のボタン（デザインの見本の `.gb`）。字の前に印、後ろにキーの札を任意で置く。幅は中身で決まり、縮まず・折り返さず・
/// 省略しない。押してもフォーカスを求めない（first responder を動かすかは `action` が決める）。ツールチップと VoiceOver の
/// 名前は、`help` を渡さなければ字から付く。
struct EditorTextButton: View {
  /// 素の姿は地なし、地つきの変種は地 `surfaceInk` の α .08（デザインの見本の `.gb.s`）。
  enum Style {
    case plain
    case filled
  }

  let title: String
  var glyph: EditorGlyphs.Glyph?
  var key: EditorKeyCap.Content?
  var style = Style.plain
  var isEnabled = true
  var help: String?
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    EditorTextButtonFace(
      title: title, glyph: glyph, key: key, style: style, isLit: hovering && isEnabled
    )
    .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture(perform: action)
    .disabled(!isEnabled)
    .help(help ?? title)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(help ?? title)
    .accessibilityAddTraits(.isButton)
  }
}

/// 字のボタンの姿。`isLit` が真ならホバーの姿（素の姿は地 `surfaceInk` の α .08・字 text.primary、地つきの変種は地 α .12）。
private struct EditorTextButtonFace: View {
  let title: String
  let glyph: EditorGlyphs.Glyph?
  let key: EditorKeyCap.Content?
  let style: EditorTextButton.Style
  let isLit: Bool

  var body: some View {
    HStack(spacing: 0) {
      if let glyph {
        EditorGlyphView(glyph: glyph, size: Theme.Layout.editorTextButtonGlyph, color: ink)
          .padding(.trailing, Theme.Layout.editorTextButtonGap)
      }
      Text(title)
        .font(Font.theme.editorTextButton)
        .foregroundStyle(ink)
      if let key {
        EditorKeyCap(content: key)
          .padding(.leading, Theme.Layout.editorTextButtonKeyGap)
      }
    }
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, Theme.Layout.editorTextButtonPadX)
    .frame(height: Theme.Layout.editorTextButton)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.editorTextButtonRadius).fill(ground))
  }

  private var ink: Color {
    style == .filled || isLit ? Color.theme.textPrimary : Color.theme.textSecondary
  }

  private var ground: Color {
    switch (style, isLit) {
    case (.plain, false): .clear
    case (.plain, true), (.filled, false):
      Color.theme.surfaceInk.opacity(Theme.Opacity.editorTextButtonFill)
    case (.filled, true): Color.theme.surfaceInk.opacity(Theme.Opacity.editorTextButtonFillHover)
    }
  }
}

/// 大きい字のボタン（高さ 30・角丸 8・左右 14・sans 12.5）。地は accent（字 onAccent・semibold）・中立（地 ink .08・字 primary）・
/// danger（字 白・semibold）・色の指定（字 onAccent・semibold）。後ろにキーの札を任意で置く（色の付いた地では、札の地は
/// 黒 .16・印は字と同じ色）。押せない間は disabled に薄め、押しても何もしない。押してもフォーカスを求めない。ツールチップと
/// VoiceOver の名前は、`help` を渡さなければ字から付く。
struct EditorLargeButton: View {
  enum Ground {
    case accent
    case neutral
    case danger
    case color(Color)
  }

  let title: String
  var key: EditorKeyCap.Content?
  var ground = Ground.neutral
  var isEnabled = true
  var help: String?
  let action: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Text(title)
        .font(isNeutral ? Font.theme.editorEmptyText : Font.theme.editorEmptyButton)
        .foregroundStyle(ink)
      if let key {
        Group {
          if isNeutral {
            EditorKeyCap(content: key)
          } else {
            EditorKeyCap(
              content: key, foreground: ink,
              ground: Color.black.opacity(Theme.Opacity.editorLargeButtonKeyCap))
          }
        }
        .padding(.leading, Theme.Layout.editorTextButtonKeyGap)
      }
    }
    .lineLimit(1)
    .padding(.horizontal, Theme.Layout.editorLargeButtonPadX)
    .frame(height: Theme.Layout.editorLargeButton)
    .background(RoundedRectangle(cornerRadius: Theme.Layout.editorLargeButtonRadius).fill(fill))
    .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
    .contentShape(Rectangle())
    .onTapGesture { if isEnabled { action() } }
    .help(help ?? title)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(help ?? title)
    .accessibilityAddTraits(.isButton)
  }

  private var isNeutral: Bool {
    if case .neutral = ground { return true }
    return false
  }

  private var ink: Color {
    switch ground {
    case .neutral: Color.theme.textPrimary
    case .danger: Color.theme.editorOnDanger
    case .accent, .color: Color.theme.onAccent
    }
  }

  private var fill: Color {
    switch ground {
    case .accent: Color.theme.accentPrimary
    case .neutral: Color.theme.surfaceInk.opacity(Theme.Opacity.editorTextButtonFill)
    case .danger: Color.theme.danger
    case .color(let color): color
    }
  }
}

#if DEBUG
  enum EditorTextButtonFixtures {
    /// 素の姿・地つきの変種のそれぞれで、字だけ・印つき・キーの札つき・ホバー・押せない姿を並べる。gallery が dark / light を撮る。
    @MainActor static func gallery() -> some View {
      VStack(alignment: .leading, spacing: 12) {
        row(.plain)
        row(.filled)
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase)
    }

    @MainActor private static func row(_ style: EditorTextButton.Style) -> some View {
      HStack(spacing: 8) {
        EditorTextButton(title: "ファイルを開く", style: style) {}
        EditorTextButton(title: "ファイルを開く", glyph: EditorGlyphs.openFile, style: style) {}
        EditorTextButton(title: "確認済みにする", key: .text("v"), style: style) {}
        EditorTextButton(title: "端末を表示", key: .glyph(EditorGlyphs.optionKey), style: style) {}
        EditorTextButtonFace(
          title: "確認済みにする", glyph: nil, key: .text("v"), style: style, isLit: true)
        EditorTextButton(
          title: "ファイルを開く", glyph: EditorGlyphs.openFile, style: style, isEnabled: false
        ) {}
      }
    }
  }

  #Preview("EditorTextButton") {
    EditorTextButtonFixtures.gallery().frame(width: 760, height: 120)
  }
#endif
