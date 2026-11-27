import AppKit
import SwiftUI

/// サイドバーから `BrowserLayerView` への一方向操作コールバック束。
final class BrowserSidebarActions {
  var onToggleProfilePopover: () -> Void = {}
  var onSelectTab: (UUID) -> Void = { _ in }
  var onCloseTab: (UUID) -> Void = { _ in }
  var onTabMenuAction: (BrowserContextMenu.TabAction, UUID) -> Void = { _, _ in }
  var onClearToday: (UUID) -> Void = { _ in }
  var onOpenNewTab: () -> Void = {}
  var onSelectSpace: (BrowserActiveSpaceSelection) -> Void = { _ in }
  var onOpenCreateSpace: () -> Void = {}
  var onOpenEditSpace: (UUID, Bool) -> Void = { _, _ in }
}

/// Arc 式の 256px 左サイドバー骨格。
/// ヘッダ（スペース名＋プロファイルピル）・最上部スロット（自由: Favorites 4 列 / ローカル: 将来 LIVE 枠）・
/// スクロール領域（`PINNED` → `TODAY` → `+ 新しいタブ`）・下端スペース切替バーで構成する。
struct BrowserSidebarRoot: View {
  let store: BrowserStore
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver
  let actions: BrowserSidebarActions

  var body: some View {
    let activeSpace = store.activeSpace
    let activeTabId = activeSpace.flatMap { store.activeTabId(in: $0.id) }

    VStack(spacing: 0) {
      if let activeSpace {
        header(space: activeSpace)
        tabList(space: activeSpace, activeTabId: activeTabId)
      } else {
        Spacer(minLength: 0)
      }
      switcherBar
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }

  // MARK: - ヘッダ

  private func header(space: BrowserSpace) -> some View {
    let localFallback = localization.string(.browserSidebarLocalFallback)
    let spaceName = store.displayName(for: space, fallbackLocalName: localFallback)
    let profile = store.profile(id: space.profileId)

    return HStack(spacing: Theme.Layout.browserSidebarHeaderGap) {
      if space.kind == .local {
        BrowserLocalBadgeView(workspaceName: spaceName)
      } else {
        BrowserGlyphView(
          glyph: BrowserGlyphs.spaceIcon(space.icon),
          size: Theme.Layout.browserIconSize,
          color: Color.theme.textPrimary)
      }

      fontResolver.text(spaceName, base: Theme.Typography.browserSidebarSpaceTitle)
        .font(Font.theme.browserSidebarSpaceTitle)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .truncationMode(.tail)

      if space.kind == .local {
        Text(localization.string(.browserSidebarLocalTag))
          .font(Font.theme.browserSidebarMeta)
          .foregroundStyle(Color.theme.textMuted)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
              .fill(Color.theme.surfaceInk.opacity(Theme.Opacity.browserSidebarPillFill))
          )
          .fixedSize()
      }

      Spacer(minLength: Theme.Space.tick)

      if let profile {
        BrowserProfilePillButton(
          profile: profile,
          tooltip: localization.string(.browserSidebarProfileTooltip),
          action: actions.onToggleProfilePopover)
      }
    }
    .padding(.leading, Theme.Layout.browserSidebarHeaderLeading)
    .padding(.trailing, Theme.Layout.browserSidebarHeaderTrailing)
    .frame(height: Theme.Layout.browserSidebarHeader)
  }

  // MARK: - 最上部スロット（.free = Favorites / .local = u6 LIVE 用余地）

  @ViewBuilder
  private func topSlot(space: BrowserSpace, activeTabId: UUID?) -> some View {
    switch space.kind {
    case .free:
      let favorites = store.tabs(in: space.id, section: .favorite)
      if !favorites.isEmpty {
        let columns = Array(
          repeating: GridItem(.flexible(), spacing: Theme.Space.note), count: 4)
        LazyVGrid(columns: columns, spacing: Theme.Space.note) {
          ForEach(favorites) { tab in
            BrowserFavoriteTile(
              tab: tab,
              isActive: tab.id == activeTabId,
              localization: localization,
              onSelect: { actions.onSelectTab(tab.id) },
              onMenuAction: { actions.onTabMenuAction($0, tab.id) })
          }
        }
        .padding(.top, 2)
        .padding(.horizontal, 10)
        .padding(.bottom, Theme.Space.step)
      }
    case .local:
      EmptyView()
    }
  }

  // MARK: - スクロール領域（最上部スロット / PINNED / TODAY / + 新しいタブ）

  private func tabList(space: BrowserSpace, activeTabId: UUID?) -> some View {
    let pinned = store.tabs(in: space.id, section: .pinned)
    let today = store.tabs(in: space.id, section: .today)

    return ScrollView(.vertical) {
      VStack(spacing: 0) {
        topSlot(space: space, activeTabId: activeTabId)
        VStack(spacing: 1) {
          if !pinned.isEmpty {
            sectionHeader(
              title: localization.string(.browserSidebarSectionPinned), trailing: { EmptyView() })
            ForEach(pinned) { tab in
              tabRow(tab, spaceKind: space.kind, activeTabId: activeTabId, showsClose: false)
            }
          }
          sectionHeader(
            title: localization.string(.browserSidebarSectionToday),
            topPadding: pinned.isEmpty ? Theme.Space.note : 10,
            trailing: {
              BrowserClearTodayButton(
                title: localization.string(.browserSidebarClearToday),
                tooltip: localization.string(.browserSidebarClearTodayTooltip),
                isEnabled: !today.isEmpty,
                action: { actions.onClearToday(space.id) })
            })
          ForEach(today) { tab in
            tabRow(tab, spaceKind: space.kind, activeTabId: activeTabId, showsClose: true)
          }
          BrowserNewTabSidebarRow(
            title: localization.string(.browserSidebarNewTab), action: actions.onOpenNewTab
          )
          .padding(.top, Theme.Space.tick)
        }
        .padding(.horizontal, Theme.Space.step)
        .padding(.bottom, Theme.Space.step)
      }
    }
    .scrollIndicators(.never)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func tabRow(
    _ tab: BrowserTab, spaceKind: BrowserSpaceKind, activeTabId: UUID?, showsClose: Bool
  ) -> some View {
    BrowserSidebarTabRow(
      tab: tab, spaceKind: spaceKind, isActive: tab.id == activeTabId,
      showsCloseOnHover: showsClose, localization: localization,
      onSelect: { actions.onSelectTab(tab.id) }, onClose: { actions.onCloseTab(tab.id) },
      onMenuAction: { actions.onTabMenuAction($0, tab.id) })
  }

  private func sectionHeader<Trailing: View>(
    title: String,
    topPadding: CGFloat = Theme.Space.note,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: 7) {
      Text(title)
        .font(Font.theme.browserSidebarMeta)
        .foregroundStyle(Color.theme.textMuted)
        .tracking(0.4)
      Rectangle()
        .fill(Color.theme.browserBarBorder)
        .frame(height: Theme.Stroke.hairline)
      trailing()
    }
    .padding(.horizontal, Theme.Space.note)
    .frame(height: Theme.Layout.browserSidebarSectionHeight)
    .padding(.top, topPadding)
  }

  // MARK: - 下端スペース切替バー

  private var resolvedLocalSpaceName: String {
    let fallback = localization.string(.browserSidebarLocalFallback)
    if let local = store.currentLocalSpace {
      return store.displayName(for: local, fallbackLocalName: fallback)
    }
    let trimmed = store.currentWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private var switcherBar: some View {
    let freeSpaces = store.freeSpaces
    let localName = resolvedLocalSpaceName

    return VStack(spacing: 0) {
      Rectangle()
        .fill(Color.theme.browserBarBorder)
        .frame(height: Theme.Stroke.hairline)

      HStack(spacing: Theme.Space.tick) {
        ScrollView(.horizontal) {
          HStack(spacing: Theme.Space.tick) {
            ForEach(freeSpaces) { space in
              BrowserFreeSpaceButton(
                space: space,
                profile: store.profile(id: space.profileId),
                isActive: store.activeSpaceSelection == .free(space.id),
                localization: localization,
                onSelect: { actions.onSelectSpace(.free(space.id)) },
                onEdit: { actions.onOpenEditSpace(space.id, false) },
                onDelete: { actions.onOpenEditSpace(space.id, true) })
            }
            BrowserAddSpaceButton(
              tooltip: localization.string(.browserSidebarAddSpaceTooltip),
              action: actions.onOpenCreateSpace)
          }
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)

        Rectangle()
          .fill(Color.theme.browserBarBorder)
          .frame(
            width: Theme.Stroke.hairline,
            height: Theme.Layout.browserSidebarSwitcherDividerH
          )
          .padding(.horizontal, 2)

        BrowserLocalSpaceButton(
          workspaceName: localName,
          isActive: store.activeSpaceSelection == .local,
          localization: localization,
          onSelect: { actions.onSelectSpace(.local) })
      }
      .padding(.horizontal, Theme.Space.step)
      .frame(height: Theme.Layout.browserSidebarSwitcher - Theme.Stroke.hairline)
    }
    .frame(height: Theme.Layout.browserSidebarSwitcher)
  }
}

private struct BrowserProfilePillButton: View {
  let profile: BrowserProfile
  let tooltip: String
  let action: () -> Void
  @State private var isHovered = false
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(profile.color.themeColor)
        .frame(width: Theme.Layout.browserSidebarDot, height: Theme.Layout.browserSidebarDot)
      fontResolver.text(profile.name, base: Theme.Typography.browserSidebarProfilePill)
        .font(Font.theme.browserSidebarProfilePill)
        .foregroundStyle(isHovered ? Color.theme.textPrimary : Color.theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
      if !profile.mcpAllowed {
        BrowserGlyphView(
          glyph: BrowserGlyphs.lock,
          size: 10,
          color: Color.theme.textMuted)
      }
    }
    .padding(.horizontal, 7)
    .frame(height: Theme.Layout.browserSidebarProfilePillHeight)
    .browserMaxWidth(Theme.Layout.browserSidebarProfilePillMaxWidth)
    .background(
      Capsule()
        .fill(
          Color.theme.surfaceInk.opacity(
            isHovered ? Theme.Opacity.browserSidebarPillHover : Theme.Opacity.browserSidebarPillFill
          ))
    )
    .contentShape(Capsule())
    .onHover { isHovered = $0 }
    .onTapGesture(perform: action)
    .help(tooltip)
  }
}

private struct BrowserClearTodayButton: View {
  let title: String
  let tooltip: String
  let isEnabled: Bool
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Text(title)
      .font(Font.theme.browserSidebarMeta)
      .foregroundStyle(isHovered && isEnabled ? Color.theme.textPrimary : Color.theme.textMuted)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
          .fill(
            isHovered && isEnabled
              ? Color.theme.surfaceInk.opacity(Theme.Opacity.browserButtonHover) : .clear)
      )
      .opacity(isEnabled ? 1 : Theme.Opacity.browserButtonDisabled)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .onTapGesture {
        guard isEnabled else { return }
        action()
      }
      .help(tooltip)
  }
}

private struct BrowserNewTabSidebarRow: View {
  let title: String
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      BrowserGlyphView(
        glyph: BrowserGlyphs.plus,
        size: 12,
        color: isHovered ? Color.theme.textPrimary : Color.theme.textMuted)
      Text(title)
        .font(Font.theme.browserSidebarAction)
        .foregroundStyle(isHovered ? Color.theme.textPrimary : Color.theme.textMuted)
        .lineLimit(1)
      Spacer(minLength: 0)
      EditorKeyCap(content: .text("⌘T"))
    }
    .padding(.horizontal, Theme.Space.step)
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
  }
}

private struct BrowserAddSpaceButton: View {
  let tooltip: String
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    BrowserGlyphView(
      glyph: BrowserGlyphs.plus,
      size: 12,
      color: isHovered ? Color.theme.textPrimary : Color.theme.textMuted
    )
    .frame(
      width: Theme.Layout.browserSidebarSwitcherAddW,
      height: Theme.Layout.browserSidebarSwitcherIconH
    )
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarRowRadius)
        .fill(isHovered ? Color.theme.surfaceInk.opacity(0.08) : .clear)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(perform: action)
    .help(tooltip)
  }
}

/// サイドバーの host。押下時に host 自身が first responder を奪わない。
final class BrowserSidebarHost: NSHostingView<BrowserSidebarRoot> {
  override var acceptsFirstResponder: Bool { false }
}
