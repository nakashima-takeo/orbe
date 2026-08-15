import SwiftUI

/// 主 CTA（カード 1 枚に 1 つ＝作成・再起動して更新・開始）。塗り accent.primary・文字 on.accent（hover で accent を ~8% 明るく）。§5.3
/// サイズは type.caption・階層は weight(semibold) で付ける（4 サイズ固定の原則）。
/// padding 7/16 は design 指示書の寸法（16=Space.bar、7 は off-grid 指定値）。
struct DSPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    PrimaryBody(configuration: configuration)
  }

  struct PrimaryBody: View {
    let configuration: Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(Font.theme.caption.weight(.semibold))
        .foregroundStyle(Color.theme.onAccent)
        .padding(.horizontal, Theme.Space.bar)
        .padding(.vertical, 7)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.md)
            .fill(Color.theme.accentPrimary)
            .brightness(hovering ? 0.08 : 0)  // hover=accent を ~8% 明るく（§5.3）
        )
        .opacity(
          isEnabled ? (configuration.isPressed ? Theme.Opacity.pressed : 1) : Theme.Opacity.disabled
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
  }
}

/// secondary（キャンセル・閉じる・再試行）。塗りなし・文字 accent・枠 surface.1（hover で accent＋hoverFill）。§5.3
struct DSSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    SecondaryBody(configuration: configuration)
  }

  struct SecondaryBody: View {
    let configuration: Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(Font.theme.caption.weight(.medium))
        .foregroundStyle(Color.theme.accentPrimary)
        .padding(.horizontal, 14)  // design 指示書の寸法（off-grid）
        .padding(.vertical, 7)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.md)
            .fill(hovering ? Color.theme.hoverFill : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(
              hovering ? Color.theme.accentPrimary : Color.theme.surface1,
              lineWidth: Theme.Stroke.hairline)
        )
        .opacity(
          isEnabled ? (configuration.isPressed ? Theme.Opacity.pressed : 1) : Theme.Opacity.disabled
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
  }
}

#Preview("Buttons") {
  VStack(alignment: .leading, spacing: Theme.Space.bar) {
    HStack(spacing: Theme.Space.beat) {
      Button("作成") {}.buttonStyle(DSPrimaryButtonStyle())
      Button("作成") {}.buttonStyle(DSPrimaryButtonStyle()).disabled(true)
    }
    HStack(spacing: Theme.Space.beat) {
      Button("キャンセル") {}.buttonStyle(DSSecondaryButtonStyle())
      Button("再試行") {}.buttonStyle(DSSecondaryButtonStyle())
      Button("キャンセル") {}.buttonStyle(DSSecondaryButtonStyle()).disabled(true)
    }
  }
  .padding(Theme.Space.phrase)
  .background(Color.theme.bgBase)
}
