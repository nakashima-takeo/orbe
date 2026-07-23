import SwiftUI

/// フルウィンドウ overlay。help scrim（最暗幕）＋中央配置のヘルプカード。
/// scrim タップで閉じる（⌘H トグルの閉じ側は WindowController のキー経路が担う）。
struct HelpOverlay: View {
  @Bindable var model: HelpModel

  /// カードの基準寸法（デザイン見本のモーダル上限 760×656。窓が狭ければ −32 マージンで縮む）。
  private let cardWidth: CGFloat = 760
  private let cardHeight: CGFloat = 656

  var body: some View {
    GeometryReader { geo in
      ZStack {
        Scrim(strength: .help)
          .contentShape(Rectangle())
          .onTapGesture { model.onDismiss() }
        HelpCard(model: model)
          .frame(
            width: min(cardWidth, geo.size.width - Theme.Space.bar * 2),
            height: min(cardHeight, geo.size.height - Theme.Space.bar * 2))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .ignoresSafeArea()
  }
}

/// ヘルプのカード本体。縦構成＝ヘッダ（検索）/ 本文 / フッター。
/// 外郭は `GlassPanel(.help)`（面 α.92・radius16・panel 級 blur・help 影）。
/// キーは検索欄（常時フォーカス）に集約し、esc で閉じる（1段。デザイン見本の2段挙動は採らない）。
struct HelpCard: View {
  @Bindable var model: HelpModel
  @Environment(\.localization) private var l10n
  @FocusState private var fieldFocused: Bool

  var body: some View {
    GlassPanel(level: .help) {
      VStack(spacing: 0) {
        header
        divider
        Spacer(minLength: 0)
      }
    }
    .onChange(of: model.focusToken, initial: true) { fieldFocused = true }
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  // MARK: - ヘッダ（検索欄）

  private var header: some View {
    HStack(spacing: 10) {
      Text("❯")
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(Color.theme.accentPrimary)
      queryField
      Text("⌘H")
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color.theme.textMuted)
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.hair)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .fill(Color.theme.surfaceInk.opacity(0.04)))
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.beat)
  }

  /// 検索欄。開いた瞬間から入力可能（そのままタイプで検索）。esc は常に閉じる。
  private var queryField: some View {
    TextField("", text: $model.query)
      .textFieldStyle(.plain)
      .font(.system(size: 13, design: .monospaced))
      .foregroundStyle(Color.theme.textPrimary)
      .tint(Color.theme.accentPrimary)
      .focused($fieldFocused)
      .imePlaceholder(
        l10n.string(.helpSearchPlaceholder), showWhenEmpty: model.query.isEmpty,
        focused: fieldFocused, font: .system(size: 13, design: .monospaced),
        color: Color.theme.textMuted
      )
      .frame(maxWidth: .infinity)
      .onKeyPress(.escape) {
        model.onDismiss()
        return .handled
      }
  }
}
