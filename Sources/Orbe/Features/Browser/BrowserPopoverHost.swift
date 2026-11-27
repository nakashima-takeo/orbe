import AppKit
import SwiftUI

/// `BrowserLayerView.belowBar` 内に 1 つだけ表示されるビュー内ポップオーバーの状態。
/// `NSPopover` / `NSAlert` を使わず、`ScreenIsolation` と `visual-check` を構造上守る。
enum BrowserPopoverState: Equatable {
  case profile
  case createSpace
  case editSpace(UUID, confirmingDelete: Bool)
}

/// ビュー内ポップオーバーの観測モデルと一方向コールバック。
@Observable final class BrowserPopoverModel {
  var state: BrowserPopoverState?
  var onBeforeFormUnmount: () -> Void = {}
  var onDismiss: () -> Void = {}
  var onUpdateState: (BrowserPopoverState) -> Void = { _ in }
}

/// `belowBar` 全面を覆うポップオーバーオーバーレイ。
/// 外側クリックを透明背面層で吸収して閉じ、カード幅・高さを `belowBar` 内側へクランプする。
struct BrowserPopoverOverlayRoot: View {
  let model: BrowserPopoverModel
  let session: BrowserSession
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: alignment(for: model.state)) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { model.onDismiss() }

        if let state = model.state {
          popoverCard(for: state, in: proxy.size)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }

  private func alignment(for state: BrowserPopoverState?) -> Alignment {
    switch state {
    case .profile, nil: .topLeading
    case .createSpace, .editSpace: .bottomLeading
    }
  }

  @ViewBuilder
  private func popoverCard(for state: BrowserPopoverState, in container: CGSize) -> some View {
    let inset = Theme.Layout.browserPopoverInset
    switch state {
    case .profile:
      let width = min(
        Theme.Layout.browserPopoverProfileWidth, max(120, container.width - inset * 2))
      let maxH = max(120, container.height - Theme.Layout.browserPopoverHeaderY - inset)
      cardPanel(width: width, maxHeight: maxH) {
        BrowserProfilePopover(
          session: session, localization: localization,
          onBeforeFormUnmount: model.onBeforeFormUnmount, onDismiss: model.onDismiss)
      }
      .padding(.leading, inset)
      .padding(.top, Theme.Layout.browserPopoverHeaderY)

    case .createSpace:
      let width = min(Theme.Layout.browserPopoverSpaceWidth, max(120, container.width - inset * 2))
      let maxH = max(120, container.height - Theme.Layout.browserPopoverBottomOffset - inset)
      cardPanel(width: width, maxHeight: maxH) {
        BrowserSpacePopover(
          mode: .create, session: session, localization: localization,
          onBeforeFormUnmount: model.onBeforeFormUnmount, onRequestDeleteConfirm: { _ in },
          onDismiss: model.onDismiss)
      }
      .padding(.leading, inset)
      .padding(.bottom, Theme.Layout.browserPopoverBottomOffset)

    case .editSpace(let spaceId, let confirmingDelete):
      let width = min(Theme.Layout.browserPopoverSpaceWidth, max(120, container.width - inset * 2))
      let maxH = max(120, container.height - Theme.Layout.browserPopoverBottomOffset - inset)
      cardPanel(width: width, maxHeight: maxH) {
        BrowserSpacePopover(
          mode: .edit(spaceId: spaceId, confirmingDelete: confirmingDelete),
          session: session, localization: localization,
          onBeforeFormUnmount: model.onBeforeFormUnmount,
          onRequestDeleteConfirm: { id in
            model.onBeforeFormUnmount()
            model.onUpdateState(.editSpace(id, confirmingDelete: true))
          },
          onDismiss: model.onDismiss)
      }
      .padding(.leading, inset)
      .padding(.bottom, Theme.Layout.browserPopoverBottomOffset)
    }
  }

  private func cardPanel<Content: View>(
    width: CGFloat, maxHeight: CGFloat, @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    GlassPanel(level: .popup, cornerRadius: Theme.Layout.browserPopoverRadius) {
      BrowserMaxHeightLayout(maxHeight: maxHeight) {
        content()
      }
      .frame(width: width)
    }
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

/// 内容が収まる高さでは自然高さへぴったり合わせ、狭小高さでのみ縦スクロールへ切り替える。
struct BrowserPopoverScrollCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    ViewThatFits(in: .vertical) {
      content()
      ScrollView(.vertical, showsIndicators: false) {
        content()
      }
    }
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
