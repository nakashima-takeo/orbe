import AppKit
import SwiftUI

/// 新しいタブ画面の入力状態モデル。`BrowserLayerView` が所有し、`BrowserNewTabView` が監視する。
@Observable final class BrowserNewTabModel {
  var inputText = ""
  /// `openNewTab()`（`⌘T` / `+ 新しいタブ`）またはボックスクリック時に進めて入力欄へ焦点を当てる。
  var focusToken = 0
  var isInputFocused = false
}

/// 新しいタブ画面から `BrowserLayerView` への一方向コールバック束。
final class BrowserNewTabActions {
  var canFocusInput: () -> Bool = { true }
  var onCommitURL: (String) -> Bool = { _ in false }
  var onCancelInput: () -> Void = {}
  var onSelectQuickAccess: (UUID) -> Void = { _ in }
  var onReopenClosedTab: (Int64) -> Void = { _ in }
  var onTapBackground: () -> Void = {}
}

/// 未遷移タブまたはタブ 0 枚時に表示する新しいタブ画面。
/// 背景は常に不透明度 100% の `Theme.Color.bgBase`（`ChromeTranslucency` 非適用）で、外部通信を行わない。
struct BrowserNewTabView: View {
  @Bindable var model: BrowserNewTabModel
  let session: BrowserSession
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver
  let actions: BrowserNewTabActions

  private var store: BrowserStore { session.store }

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color.theme.bgBase
          .contentShape(Rectangle())
          .onTapGesture(perform: actions.onTapBackground)

        ScrollView(.vertical, showsIndicators: false) {
          VStack(spacing: Theme.Space.phrase) {
            brandHeader
            urlInputBox
            quickAccessSection
            recentlyClosedSection
          }
          .padding(.horizontal, Theme.Space.span)
          .padding(.vertical, Theme.Space.phrase)
          .frame(maxWidth: .infinity)
          .frame(minHeight: proxy.size.height, alignment: .center)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .background(Color.theme.bgBase)
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }

  // MARK: - ブランドと現在スペース／プロファイル表示

  private var brandHeader: some View {
    let activeSpace = store.activeSpace
    let profile = activeSpace.flatMap { store.profile(id: $0.profileId) }
    let localFallback = localization.string(.browserSidebarLocalFallback)
    let spaceName = activeSpace.map {
      store.displayName(for: $0, fallbackLocalName: localFallback)
    }

    return VStack(spacing: Theme.Space.beat) {
      OrbeMarkShape()
        .fill(Color.theme.glyphGradient, style: FillStyle(eoFill: true))
        .frame(
          width: Theme.Layout.browserNewTabMarkSize,
          height: Theme.Layout.browserNewTabMarkSize)

      if let spaceName {
        HStack(spacing: Theme.Space.note) {
          if let profile {
            Circle()
              .fill(profile.color.themeColor)
              .frame(width: Theme.Layout.browserSidebarDot, height: Theme.Layout.browserSidebarDot)
          }
          Text(spaceName)
            .font(Font.theme.browserSidebarAction)
            .foregroundStyle(Color.theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
          if let profile {
            Text("·")
              .font(Font.theme.browserSidebarProfilePill)
              .foregroundStyle(Color.theme.textMuted)
            Text(profile.name)
              .font(Font.theme.browserSidebarProfilePill)
              .foregroundStyle(Color.theme.textMuted)
              .lineLimit(1)
          }
        }
      }
    }
  }

  // MARK: - URL 入力ボックス（URL 遷移のみ受理）

  private var urlInputBox: some View {
    HStack(spacing: 10) {
      BrowserGlyphView(
        glyph: BrowserGlyphs.forward,
        size: 13,
        color: Color.theme.accentBright)
      BrowserInlineTextField(
        text: $model.inputText,
        placeholder: localization.string(.browserBarURLPlaceholder),
        font: Theme.Typography.browserNewTabInput,
        focusToken: model.focusToken,
        selectAllOnFocus: true,
        canFocus: actions.canFocusInput,
        onFocusChange: { model.isInputFocused = $0 },
        onCommit: actions.onCommitURL,
        onCancel: actions.onCancelInput
      )
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: Theme.Layout.browserNewTabMaxWidth)
    .frame(height: Theme.Layout.browserNewTabInputHeight)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserNewTabInputRadius)
        .fill(Color.theme.surfaceInk.opacity(Theme.Opacity.browserURLFill))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Layout.browserNewTabInputRadius)
        .strokeBorder(
          model.isInputFocused
            ? Color.theme.accentPrimary.opacity(Theme.Opacity.browserURLFocusBorder)
            : Color.theme.accentPrimary.opacity(0.32),
          lineWidth: 1.5)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      guard !model.isInputFocused else { return }
      model.focusToken = max(1, model.focusToken &+ 1)
    }
  }

  // MARK: - クイックアクセス（Favorites＋PINNED 最大 8 件）

  @ViewBuilder
  private var quickAccessSection: some View {
    let items = quickAccessTabs()
    if !items.isEmpty {
      VStack(spacing: Theme.Space.step) {
        Text(localization.string(.browserNewTabQuickAccess))
          .font(Font.theme.browserSidebarMeta)
          .foregroundStyle(Color.theme.textMuted)
          .tracking(0.4)
        BrowserCenteredWrapLayout(spacing: 10) {
          ForEach(items) { tab in
            BrowserNewTabQuickTile(
              tab: tab,
              localization: localization,
              action: { actions.onSelectQuickAccess(tab.id) })
          }
        }
        .frame(maxWidth: Theme.Layout.browserNewTabMaxWidth)
      }
    }
  }

  private func quickAccessTabs() -> [BrowserTab] {
    guard let space = store.activeSpace else { return [] }
    let favorites = store.tabs(in: space.id, section: .favorite)
    let pinned = store.tabs(in: space.id, section: .pinned)
    return Array((favorites + pinned).prefix(8))
  }

  // MARK: - 最近閉じたタブ（最大 5 件）

  @ViewBuilder
  private var recentlyClosedSection: some View {
    let closed = store.reopenableClosedTabs(limit: 5)
    if !closed.isEmpty {
      let activeSpaceId = store.activeSpace?.id
      let localFallback = localization.string(.browserSidebarLocalFallback)
      let currentTime = session.now()

      VStack(spacing: Theme.Space.tick) {
        HStack(spacing: 7) {
          Text(localization.string(.browserNewTabRecentlyClosed))
            .font(Font.theme.browserSidebarMeta)
            .foregroundStyle(Color.theme.textMuted)
            .tracking(0.4)
          Rectangle()
            .fill(Color.theme.browserBarBorder)
            .frame(height: Theme.Stroke.hairline)
          EditorKeyCap(content: .text("⌘⇧T"))
        }
        .padding(.horizontal, Theme.Space.tick)
        .frame(height: Theme.Layout.browserSidebarSectionHeight)

        VStack(spacing: 2) {
          ForEach(closed) { item in
            let originSpaceName: String? =
              if item.originalSpaceId != activeSpaceId,
                let origin = store.space(id: item.originalSpaceId)
              {
                store.displayName(for: origin, fallbackLocalName: localFallback)
              } else {
                nil
              }
            BrowserRecentlyClosedRow(
              item: item,
              originSpaceName: originSpaceName,
              relativeTime: ElapsedText.ago(
                item.closedAt, now: currentTime, language: localization.language),
              fallbackTitle: localization.string(.browserNewTabTitle),
              action: { actions.onReopenClosedTab(item.id) })
          }
        }
      }
      .frame(maxWidth: Theme.Layout.browserNewTabMaxWidth)
    }
  }
}

private struct BrowserNewTabQuickTile: View {
  let tab: BrowserTab
  let localization: LocalizationStore
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    let fallback = localization.string(.browserNewTabTitle)
    let label = BrowserTabDisplay.shortLabel(url: tab.url, title: tab.title, fallback: fallback)
    let tooltip = BrowserTabDisplay.title(url: tab.url, title: tab.title, fallback: fallback)

    VStack(spacing: Theme.Space.note) {
      BrowserFaviconChip(
        url: tab.url,
        title: tab.title,
        size: Theme.Layout.browserNewTabTileChip,
        font: Font.theme.browserSidebarFavChip)
      Text(label)
        .font(Font.theme.browserNewTabTile)
        .foregroundStyle(isHovered ? Color.theme.textPrimary : Color.theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, Theme.Space.tick)
    }
    .frame(
      width: Theme.Layout.browserNewTabTileWidth,
      height: Theme.Layout.browserNewTabTileHeight
    )
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserNewTabInputRadius)
        .fill(
          Color.theme.surfaceInk.opacity(
            isHovered ? Theme.Opacity.browserNewTabTileHover : Theme.Opacity.browserNewTabTileFill))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Layout.browserNewTabInputRadius)
        .strokeBorder(Color.theme.browserBarBorder, lineWidth: Theme.Stroke.hairline)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(perform: action)
    .help(tooltip)
  }
}

private struct BrowserRecentlyClosedRow: View {
  let item: BrowserClosedTab
  let originSpaceName: String?
  let relativeTime: String
  let fallbackTitle: String
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    let title = BrowserTabDisplay.title(url: item.url, title: item.title, fallback: fallbackTitle)

    HStack(spacing: 9) {
      BrowserFaviconChip(url: item.url, title: item.title)
      Text(title)
        .font(Font.theme.browserSidebarTab)
        .foregroundStyle(isHovered ? Color.theme.textPrimary : Color.theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Space.tick)
      if let originSpaceName {
        Text(originSpaceName)
          .font(Font.theme.browserSidebarMeta)
          .foregroundStyle(Color.theme.textMuted)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
              .fill(Color.theme.surfaceInk.opacity(Theme.Opacity.browserSidebarPillFill))
          )
          .lineLimit(1)
      }
      Text(relativeTime)
        .font(Font.theme.browserSidebarProfilePill)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize()
    }
    .padding(.horizontal, 10)
    .frame(height: Theme.Layout.browserSidebarRow)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarRowRadius)
        .fill(
          isHovered
            ? Color.theme.surfaceInk.opacity(Theme.Opacity.browserSidebarItemHover) : .clear)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(perform: action)
    .help(title)
  }
}

/// クイックアクセスタイルを各行ごとに中央揃えして折り返す軽量レイアウト。
private struct BrowserCenteredWrapLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    let rows = arrangeRows(subviews: subviews, maxWidth: maxWidth)
    let width = rows.map(\.width).max() ?? 0
    let height =
      rows.reduce(CGFloat(0)) { $0 + $1.height }
      + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(
      width: maxWidth.isFinite ? min(maxWidth, max(width, 0)) : width,
      height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let rows = arrangeRows(subviews: subviews, maxWidth: bounds.width)
    var y = bounds.minY
    for row in rows {
      var x = bounds.minX + (bounds.width - row.width) / 2
      for entry in row.items {
        entry.subview.place(
          at: CGPoint(x: x, y: y + (row.height - entry.size.height) / 2),
          anchor: .topLeading,
          proposal: ProposedViewSize(entry.size))
        x += entry.size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct RowItem {
    let subview: LayoutSubview
    let size: CGSize
  }

  private struct Row {
    var items: [RowItem] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrangeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let added = current.items.isEmpty ? size.width : spacing + size.width
      if !current.items.isEmpty && current.width + added > maxWidth {
        rows.append(current)
        current = Row()
      }
      current.items.append(RowItem(subview: subview, size: size))
      current.width += current.items.count == 1 ? size.width : spacing + size.width
      current.height = max(current.height, size.height)
    }
    if !current.items.isEmpty { rows.append(current) }
    return rows
  }
}

/// 新しいタブ画面の host。host 自身は first responder を奪わず、子孫の入力欄のみフォーカスを受ける。
final class BrowserNewTabHost: NSHostingView<BrowserNewTabView> {
  override var acceptsFirstResponder: Bool { false }
}
