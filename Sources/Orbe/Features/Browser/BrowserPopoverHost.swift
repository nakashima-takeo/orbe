import AppKit
import SwiftUI

/// `BrowserLayerView.belowBar` 内に 1 つだけ表示されるビュー内ポップオーバーの状態。
/// `NSPopover` / `NSAlert` を使わず、`ScreenIsolation` と `visual-check` を構造上守る。
enum BrowserPopoverState: Equatable, Hashable {
  case profile
  case createSpace
  case editSpace(UUID, confirmingDelete: Bool)
}

/// ビュー内ポップオーバーの観測モデルと一方向コールバック。
@Observable final class BrowserPopoverModel {
  var state: BrowserPopoverState?
  var onBeforeFormUnmount: () -> Void = {}
  var onDismiss: () -> Void = {}
}

/// `belowBar` 全面を覆うポップオーバーオーバーレイ。
/// 外側クリックを透明背面層で吸収して閉じ、カード幅・高さを `belowBar` 内側へクランプする。
struct BrowserPopoverOverlayRoot: View {
  let model: BrowserPopoverModel
  let session: BrowserSession
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver

  private struct Placement {
    let alignment: Alignment
    let inset: CGFloat
    let width: CGFloat
    let maxHeight: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat

    init(for state: BrowserPopoverState, in container: CGSize) {
      inset = Theme.Layout.browserPopoverInset
      let maxWidth = max(0, container.width - inset * 2)
      switch state {
      case .profile:
        alignment = .topLeading
        width = min(Theme.Layout.browserPopoverProfileWidth, maxWidth)
        topPadding = Theme.Layout.browserPopoverHeaderY
        bottomPadding = 0
        maxHeight = max(0, container.height - topPadding - inset)
      case .createSpace, .editSpace:
        alignment = .bottomLeading
        width = min(Theme.Layout.browserPopoverSpaceWidth, maxWidth)
        topPadding = 0
        bottomPadding = Theme.Layout.browserPopoverBottomOffset
        maxHeight = max(0, container.height - bottomPadding - inset)
      }
    }
  }

  var body: some View {
    GeometryReader { proxy in
      let placement = model.state.map { Placement(for: $0, in: proxy.size) }
      ZStack(alignment: placement?.alignment ?? .topLeading) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { model.onDismiss() }

        if let state = model.state, let placement {
          popoverCard(for: state, placement: placement)
            .id(state)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }

  @ViewBuilder
  private func popoverCard(for state: BrowserPopoverState, placement: Placement) -> some View {
    switch state {
    case .profile:
      cardPanel(placement: placement) {
        BrowserProfilePopover(
          session: session, localization: localization,
          onBeforeFormUnmount: model.onBeforeFormUnmount, onDismiss: model.onDismiss)
      }

    case .createSpace:
      cardPanel(placement: placement) {
        BrowserSpacePopover(
          mode: .create, session: session, localization: localization,
          onDismiss: model.onDismiss)
      }

    case .editSpace(let spaceId, let confirmingDelete):
      cardPanel(placement: placement) {
        BrowserSpacePopover(
          mode: .edit(spaceId: spaceId, confirmingDelete: confirmingDelete),
          session: session, localization: localization,
          onRequestDeleteConfirm: { id in
            model.onBeforeFormUnmount()
            model.state = .editSpace(id, confirmingDelete: true)
          },
          onDismiss: model.onDismiss)
      }
    }
  }

  /// 単一ツリーの `ScrollView` を `BrowserMaxHeightLayout` 直下へ置き、
  /// 高さ境界跨ぎでのフォーム破棄・IME 消失を防ぎつつ自然高さフィットと狭小スクロールを両立する。
  private func cardPanel<Content: View>(
    placement: Placement, @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    GlassPanel(level: .popup, cornerRadius: Theme.Layout.browserPopoverRadius) {
      BrowserMaxHeightLayout(maxHeight: placement.maxHeight) {
        ScrollView(.vertical) {
          content()
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
      }
      .frame(width: placement.width)
    }
    .padding(.leading, placement.inset)
    .padding(.top, placement.topPadding)
    .padding(.bottom, placement.bottomPadding)
  }
}

/// 子の自然高さを保ちつつ最大高さのみ `maxHeight` で上限するレイアウト。
/// `.frame(maxHeight:)` と異なり余剰スペースへ貪欲に膨張せず、超過時のみ `maxHeight` を提案する。
private struct BrowserMaxHeightLayout: Layout {
  let maxHeight: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    let cap = proposal.height.map { min($0, maxHeight) } ?? maxHeight
    let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    if ideal.height <= cap { return ideal }
    return subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: cap))
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

/// プロファイル選択・付け替え候補の共通行（識別色ドット・名前・MCP 非公開鍵アイコン・選択チェック）。
struct BrowserPopoverProfileOptionRow: View {
  let profile: BrowserProfile
  let isSelected: Bool
  var usePrimaryTextWhenUnselected = false
  let action: () -> Void
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      Circle()
        .fill(profile.color.themeColor)
        .frame(width: Theme.Layout.browserSidebarDot, height: Theme.Layout.browserSidebarDot)
      fontResolver.text(profile.name, base: Theme.Typography.browserSidebarTab)
        .font(Font.theme.browserSidebarTab)
        .foregroundStyle(
          isSelected || usePrimaryTextWhenUnselected
            ? Color.theme.textPrimary : Color.theme.textSecondary
        )
        .lineLimit(1)
        .truncationMode(.tail)
      if !profile.mcpAllowed {
        BrowserGlyphView(glyph: BrowserGlyphs.lock, size: 10, color: Color.theme.textMuted)
      }
      Spacer(minLength: 0)
      if isSelected {
        BrowserGlyphView(glyph: BrowserGlyphs.check, size: 12, color: Color.theme.accentBright)
      }
    }
    .padding(.horizontal, Theme.Space.step)
    .frame(height: 28)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(isSelected ? Color.theme.selectionFill : Color.theme.surfaceInk.opacity(0.04))
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
  }
}

/// ポップオーバー用トグルスイッチ（幅 34×高さ 19pt）。
struct BrowserTogglePill: View {
  let isOn: Bool

  var body: some View {
    ZStack(alignment: isOn ? .trailing : .leading) {
      Capsule()
        .fill(
          isOn
            ? Color.theme.accentPrimary
            : Color.theme.surfaceInk.opacity(Theme.Opacity.browserToggleOff))
      Circle()
        .fill(Color.white)
        .frame(width: Theme.Layout.browserToggleKnob, height: Theme.Layout.browserToggleKnob)
        .padding(2)
    }
    .frame(width: Theme.Layout.browserToggleWidth, height: Theme.Layout.browserToggleHeight)
    .animation(.easeOut(duration: Theme.Motion.quick), value: isOn)
  }
}

/// ポップオーバー内のラベル付きテキスト入力ボックス（`BrowserInlineTextField` 共有）。
struct BrowserPopoverTextFieldBox: View {
  let label: String
  @Binding var text: String
  let placeholder: String
  let focusToken: Int
  let onCommit: (String) -> Bool
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      Text(label)
        .font(Font.theme.browserPopoverSection)
        .foregroundStyle(Color.theme.textMuted)
      BrowserInlineTextField(
        text: $text,
        placeholder: placeholder,
        font: Theme.Typography.browserSidebarTab,
        focusToken: focusToken,
        selectAllOnFocus: true,
        onCommit: onCommit,
        onCancel: onCancel
      )
      .padding(.horizontal, Theme.Space.step)
      .frame(height: 30)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .fill(Color.theme.surfaceInk.opacity(Theme.Opacity.browserURLFill))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .strokeBorder(
            Color.theme.surfaceInk.opacity(Theme.Opacity.browserURLBorder),
            lineWidth: Theme.Stroke.hairline)
      )
    }
  }
}

/// ポップオーバーのサブ画面見出し（戻るボタン＋タイトル）。
struct BrowserPopoverSubHeader: View {
  let title: String
  let backTooltip: String
  let onBack: () -> Void

  var body: some View {
    HStack(spacing: Theme.Space.note) {
      BrowserGlyphView(glyph: BrowserGlyphs.back, size: 13, color: Color.theme.textSecondary)
        .frame(width: 22, height: 22)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .fill(Color.theme.surfaceInk.opacity(Theme.Opacity.browserSidebarPillFill))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onBack)
        .help(backTooltip)
      Text(title)
        .font(Font.theme.browserPopoverTitle)
        .foregroundStyle(Color.theme.textPrimary)
      Spacer(minLength: 0)
    }
  }
}

/// ポップオーバー内のアイコン付き操作行（作成・削除など）。
struct BrowserPopoverMenuRow: View {
  let glyph: BrowserGlyphs.Glyph
  let title: String
  var isDanger = false
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      BrowserGlyphView(
        glyph: glyph,
        size: 13,
        color: isDanger
          ? Color.theme.danger : (isHovered ? Color.theme.textPrimary : Color.theme.textMuted)
      )
      Text(title)
        .font(Font.theme.browserSidebarTab)
        .foregroundStyle(
          isDanger
            ? Color.theme.danger
            : (isHovered ? Color.theme.textPrimary : Color.theme.textSecondary)
        )
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 9)
    .frame(height: Theme.Layout.browserSidebarRow)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(hoverBackground)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(perform: action)
  }

  private var hoverBackground: Color {
    guard isHovered else { return .clear }
    return isDanger ? Color.theme.danger.opacity(0.14) : Color.theme.selectionFill
  }
}

/// ポップオーバー内の汎用アクションボタン（主・副・危険の 3 態）。
struct BrowserPopoverActionButton: View {
  enum Style {
    case primary
    case secondary
    case danger
  }

  let title: String
  let style: Style
  var isEnabled = true
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Text(title)
      .font(style == .secondary ? Font.theme.browserSidebarAction : Font.theme.browserPopoverTitle)
      .foregroundStyle(foregroundColor)
      .padding(.horizontal, Theme.Space.beat)
      .frame(height: 28)
      .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(backgroundColor))
      .opacity(isEnabled ? 1 : Theme.Opacity.browserButtonDisabled)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .onTapGesture {
        guard isEnabled else { return }
        action()
      }
  }

  private var foregroundColor: Color {
    switch style {
    case .primary: Color.theme.onAccent
    case .secondary: Color.theme.textPrimary
    case .danger: Color.theme.danger
    }
  }

  private var backgroundColor: Color {
    switch style {
    case .primary:
      Color.theme.accentPrimary.opacity(isHovered && isEnabled ? 0.9 : 1)
    case .secondary:
      Color.theme.surfaceInk.opacity(isHovered && isEnabled ? 0.12 : 0.07)
    case .danger:
      Color.theme.danger.opacity(isHovered && isEnabled ? 0.22 : 0.14)
    }
  }
}

/// ビュー内ポップオーバーの host。閉じている間は `isHidden = true` で `hitTest` に参加せず、
/// 表示中は背面余白での右クリック・スクロールが下層 WebView へ貫通するのを防ぐ。
final class BrowserPopoverHost: NSHostingView<BrowserPopoverOverlayRoot> {
  override var acceptsFirstResponder: Bool { false }
  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
}
