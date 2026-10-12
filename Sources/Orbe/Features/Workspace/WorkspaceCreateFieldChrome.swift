import SwiftUI

/// 入力欄のラベル（見本: 11px muted ラベル・letterSpacing 0.08em ≒ tracking 1）。folder/clone で共用。
func workspaceFieldLabel(_ text: String) -> some View {
  Text(text)
    .font(Font.theme.chrome)
    .tracking(Theme.Typography.trackingLabel)
    .foregroundStyle(Color.theme.textMuted)
}

/// 入力欄の共通装飾（inputWash 地・角丸・focus で accent 半透明枠／非 focus で border トークン枠）。
/// α が外観で切れない `.opacity()` は focus 枠のみ（accent は動的色で uniform に効く）。地・枠色は
/// `DesignSystem` トークンへ写像し、生 hex を直書きしない。folder/clone の入力欄で共用。
struct FieldChrome: ViewModifier {
  let focused: Bool

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, Theme.Space.beat)
      .padding(.vertical, 11)  // 見本の入力欄高（padding 11px・off-grid の指定値）
      .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.theme.inputWash))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.md)
          .strokeBorder(
            focused ? Color.theme.accentPrimary.opacity(0.5) : Color.theme.inputBorder,
            lineWidth: Theme.Stroke.hairline)
      )
  }
}
