import SwiftUI

extension BrowserProfileColor {
  var themeColor: Color {
    switch self {
    case .green: Color.theme.browserProfileGreen
    case .blue: Color.theme.browserProfileBlue
    case .amber: Color.theme.browserProfileAmber
    case .purple: Color.theme.browserProfilePurple
    case .pink: Color.theme.browserProfilePink
    case .teal: Color.theme.browserProfileTeal
    }
  }
}

/// タブ・閉じたタブの表示タイトル・短縮ラベル・モノグラム 1 文字・チップ配色を決定論的に導く。
enum BrowserTabDisplay {
  static func title(url: URL?, title: String, fallback: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    if let host = BrowserURLInput.display(url)?.host, !host.isEmpty { return host }
    return fallback
  }

  static func shortLabel(url: URL?, title: String, fallback: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    return strippedHost(for: url) ?? fallback
  }

  static func monogram(url: URL?, title: String) -> String? {
    if let host = strippedHost(for: url), let first = host.first {
      return String(first).uppercased()
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.first.map { String($0).uppercased() }
  }

  static func localBadgeLetter(workspaceName: String) -> String {
    let trimmed = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.first.map { String($0).uppercased() } ?? "O"
  }

  /// プロセス再起動をまたいでも同じ色になるよう FNV-1a でホストから決定論的に色を選ぶ。
  static func chipTint(url: URL?, title: String) -> Color? {
    let seed = strippedHost(for: url) ?? title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !seed.isEmpty else { return nil }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in seed.lowercased().utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let colors: [Color?] = [
      nil, Color.theme.browserProfileBlue, Color.theme.browserProfileTeal,
      Color.theme.browserProfilePurple, Color.theme.browserProfileAmber,
      Color.theme.browserProfilePink, Color.theme.browserProfileGreen,
    ]
    return colors[Int(hash % UInt64(colors.count))]
  }

  private static func strippedHost(for url: URL?) -> String? {
    guard let rawHost = url?.host?.lowercased(), !rawHost.isEmpty else { return nil }
    return rawHost.hasPrefix("www.") && rawHost.count > 4 ? String(rawHost.dropFirst(4)) : rawHost
  }
}

/// 外部通信なしでホスト名から決定論的に描くモノグラムチップ。
struct BrowserFaviconChip: View {
  let url: URL?
  let title: String
  var size: CGFloat = Theme.Layout.browserSidebarChip
  var font: Font = Font.theme.browserSidebarChip

  var body: some View {
    let tint = BrowserTabDisplay.chipTint(url: url, title: title)
    ZStack {
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarChipRadius)
        .fill(
          tint?.opacity(Theme.Opacity.browserSidebarChipFill)
            ?? Color.theme.surfaceInk.opacity(0.10))
      if let letter = BrowserTabDisplay.monogram(url: url, title: title) {
        Text(letter).font(font).foregroundStyle(tint ?? Color.theme.textPrimary)
      } else {
        BrowserGlyphView(
          glyph: BrowserGlyphs.spaceGlobe, size: size * 0.65, color: Color.theme.textMuted)
      }
    }
    .frame(width: size, height: size)
  }
}

/// ローカルスペースのティール角丸バッジ。
struct BrowserLocalBadgeView: View {
  let workspaceName: String
  var size: CGFloat = Theme.Layout.browserSidebarLocalBadge

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Color.theme.browserLocalBadge)
      Text(BrowserTabDisplay.localBadgeLetter(workspaceName: workspaceName))
        .font(Font.theme.browserLocalBadge)
        .foregroundStyle(Color.theme.browserLocalBadgeInk)
    }
    .frame(width: size, height: size)
  }
}

/// 自由スペース最上部の 4 列 Favorites タイル（高さ 44pt）。
struct BrowserFavoriteTile: View {
  let tab: BrowserTab
  let isActive: Bool
  let localization: LocalizationStore
  let onSelect: () -> Void
  let onMenuAction: (BrowserContextMenu.TabAction) -> Void
  @State private var isHovered = false

  var body: some View {
    let fallback = localization.string(.browserNewTabTitle)
    let label = BrowserTabDisplay.shortLabel(url: tab.url, title: tab.title, fallback: fallback)
    let tooltip = BrowserTabDisplay.title(url: tab.url, title: tab.title, fallback: fallback)
    VStack(spacing: 3) {
      BrowserFaviconChip(
        url: tab.url, title: tab.title,
        size: Theme.Layout.browserSidebarFavChip, font: Font.theme.browserSidebarFavChip)
      Text(label)
        .font(Font.theme.browserSidebarFavLabel)
        .foregroundStyle(isActive ? Color.theme.textPrimary : Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, Theme.Space.tick)
    }
    .frame(maxWidth: .infinity)
    .frame(height: Theme.Layout.browserSidebarFavHeight)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarFavRadius).fill(fillColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarFavRadius)
        .strokeBorder(borderColor, lineWidth: isActive ? 1.5 : Theme.Stroke.hairline)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(perform: onSelect)
    .contextMenu {
      BrowserTabContextMenuItems(
        entries: BrowserContextMenu.tabItems(for: tab, in: .free),
        localization: localization, onAction: onMenuAction)
    }
    .help(tooltip)
  }

  private var fillColor: Color {
    if isActive { return Color.theme.selectionFill }
    if isHovered { return Color.theme.surfaceInk.opacity(Theme.Opacity.browserSidebarFavHover) }
    return Color.theme.surfaceInk.opacity(Theme.Opacity.browserSidebarFavFill)
  }

  private var borderColor: Color {
    isActive
      ? Color.theme.accentPrimary.opacity(Theme.Opacity.browserSidebarFavActiveBorder)
      : Color.theme.surfaceInk.opacity(Theme.Opacity.browserSidebarFavBorder)
  }
}

/// `PINNED` / `TODAY` タブ 1 行（高さ 30pt）。`TODAY` 行のみホバー時に右端 `×` を出す。
struct BrowserSidebarTabRow: View {
  let tab: BrowserTab
  let spaceKind: BrowserSpaceKind
  let isActive: Bool
  let showsCloseOnHover: Bool
  let localization: LocalizationStore
  let onSelect: () -> Void
  let onClose: () -> Void
  let onMenuAction: (BrowserContextMenu.TabAction) -> Void
  @State private var isHovered = false
  @State private var isCloseHovered = false

  var body: some View {
    let title = BrowserTabDisplay.title(
      url: tab.url, title: tab.title, fallback: localization.string(.browserNewTabTitle))
    let textColor = isActive || isHovered ? Color.theme.textPrimary : Color.theme.textSecondary

    HStack(spacing: Theme.Space.step) {
      HStack(spacing: Theme.Space.step) {
        BrowserFaviconChip(url: tab.url, title: tab.title)
        Text(title)
          .font(Font.theme.browserSidebarTab)
          .foregroundStyle(textColor)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .onTapGesture(perform: onSelect)

      if showsCloseOnHover && isHovered {
        BrowserGlyphView(
          glyph: BrowserGlyphs.close, size: 10,
          color: isCloseHovered ? Color.theme.textPrimary : Color.theme.textMuted
        )
        .frame(
          width: Theme.Layout.browserSidebarCloseButton,
          height: Theme.Layout.browserSidebarCloseButton
        )
        .background(
          RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarChipRadius)
            .fill(isCloseHovered ? Color.theme.surfaceInk.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isCloseHovered = $0 }
        .onTapGesture(perform: onClose)
        .help(localization.string(.browserSidebarCloseTabTooltip))
      }
    }
    .padding(.horizontal, Theme.Space.step)
    .frame(height: Theme.Layout.browserSidebarRow)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarRowRadius).fill(rowBackground)
    )
    .onHover { hovered in
      isHovered = hovered
      if !hovered { isCloseHovered = false }
    }
    .contextMenu {
      BrowserTabContextMenuItems(
        entries: BrowserContextMenu.tabItems(for: tab, in: spaceKind),
        localization: localization, onAction: onMenuAction)
    }
    .help(title)
  }

  private var rowBackground: Color {
    if isActive { return Color.theme.selectionFill }
    if isHovered { return Color.theme.surfaceInk.opacity(Theme.Opacity.browserSidebarItemHover) }
    return .clear
  }
}

/// 下端スペース切替バーの自由スペースアイコンボタン（30×28pt＋右下 6pt プロファイル色ドット）。
struct BrowserFreeSpaceButton: View {
  let space: BrowserSpace
  let profile: BrowserProfile?
  let isActive: Bool
  let localization: LocalizationStore
  let onSelect: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void
  @State private var isHovered = false

  var body: some View {
    let tooltip =
      profile.map { localization.format(.browserSidebarSpaceTooltip, space.name, $0.name) }
      ?? space.name
    let iconColor = isActive || isHovered ? Color.theme.textPrimary : Color.theme.textMuted

    ZStack(alignment: .bottomTrailing) {
      BrowserGlyphView(
        glyph: BrowserGlyphs.spaceIcon(space.icon),
        size: Theme.Layout.browserIconSize, color: iconColor
      )
      .frame(
        width: Theme.Layout.browserSidebarSwitcherIconW,
        height: Theme.Layout.browserSidebarSwitcherIconH)

      if let profile {
        Circle()
          .fill(profile.color.themeColor)
          .frame(
            width: Theme.Layout.browserSidebarSwitcherDot,
            height: Theme.Layout.browserSidebarSwitcherDot
          )
          .overlay(Circle().stroke(Color.theme.browserSidebarBg, lineWidth: 1.5))
          .offset(x: -3, y: -3)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarRowRadius).fill(switcherBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarRowRadius)
        .strokeBorder(
          isActive
            ? Color.theme.accentPrimary.opacity(Theme.Opacity.browserSidebarSwitcherBorder)
            : .clear,
          lineWidth: Theme.Stroke.hairline)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(perform: onSelect)
    .contextMenu {
      ForEach(BrowserContextMenu.freeSpaceItems()) { item in
        Button(localization.string(item.titleKey)) {
          switch item.action {
          case .edit: onEdit()
          case .delete: onDelete()
          }
        }
      }
    }
    .help(tooltip)
  }

  private var switcherBg: Color {
    if isActive { return Color.theme.selectionFill }
    return isHovered ? Color.theme.surfaceInk.opacity(0.08) : .clear
  }
}

/// 下端スペース切替バー右端のローカルスペースボタン（最大幅 112pt、将来の LIVE 件数ピル用スロット付き）。
struct BrowserLocalSpaceButton: View {
  let workspaceName: String
  let isActive: Bool
  let localization: LocalizationStore
  let onSelect: () -> Void
  @State private var isHovered = false

  var body: some View {
    let textColor = isActive || isHovered ? Color.theme.textPrimary : Color.theme.textSecondary
    HStack(spacing: Theme.Space.note) {
      BrowserLocalBadgeView(
        workspaceName: workspaceName, size: Theme.Layout.browserSidebarSwitcherLocalBadge)
      Text(workspaceName)
        .font(Font.theme.browserSwitcherLocal)
        .foregroundStyle(textColor)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.leading, 7)
    .padding(.trailing, 9)
    .frame(height: Theme.Layout.browserSidebarSwitcherIconH)
    .browserMaxWidth(Theme.Layout.browserSidebarSwitcherLocalMaxW)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarRowRadius).fill(switcherBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarRowRadius)
        .strokeBorder(
          isActive
            ? Color.theme.accentPrimary.opacity(Theme.Opacity.browserSidebarSwitcherBorder)
            : .clear,
          lineWidth: Theme.Stroke.hairline)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(perform: onSelect)
    .help(localization.format(.browserSidebarLocalTooltip, workspaceName))
  }

  private var switcherBg: Color {
    if isActive { return Color.theme.selectionFill }
    return isHovered ? Color.theme.surfaceInk.opacity(0.08) : .clear
  }
}

/// `BrowserContextMenu.TabMenuEntry` を SwiftUI 標準 `.contextMenu` 項目へ投影する。
struct BrowserTabContextMenuItems: View {
  let entries: [BrowserContextMenu.TabMenuEntry]
  let localization: LocalizationStore
  let onAction: (BrowserContextMenu.TabAction) -> Void

  var body: some View {
    ForEach(entries) { entry in
      switch entry {
      case .action(let action, let key): Button(localization.string(key)) { onAction(action) }
      case .separator: Divider()
      }
    }
  }
}

/// 子の自然幅を保ちつつ最大幅のみ `maxWidth` で上限するレイアウト。
/// `.frame(maxWidth:)` と異なり余剰スペースへ貪欲に膨張しない。
struct BrowserMaxWidthLayout: Layout {
  let maxWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    let cap = proposal.width.map { min($0, maxWidth) } ?? maxWidth
    let ideal = subview.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
    if ideal.width <= cap { return ideal }
    return subview.sizeThatFits(ProposedViewSize(width: cap, height: proposal.height))
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

extension View {
  func browserMaxWidth(_ maxWidth: CGFloat) -> some View {
    BrowserMaxWidthLayout(maxWidth: maxWidth) { self }
  }
}
