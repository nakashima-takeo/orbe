import SwiftUI

/// プロファイル管理ポップオーバー（MCP 権限切替・プロファイル付け替え・作成／編集・付け替え削除確認）。
struct BrowserProfilePopover: View {
  enum Screen: Equatable {
    case main
    case form(editingId: UUID?)
    case confirmDelete(targetId: UUID)
  }

  let session: BrowserSession
  let localization: LocalizationStore
  let onBeforeFormUnmount: () -> Void
  let onDismiss: () -> Void

  @State private var screen: Screen = .main
  @State private var draftName = ""
  @State private var draftColor: BrowserProfileColor = .purple
  @State private var draftMCPAllowed = false
  @State private var nameFocusToken = 0
  @State private var reassignProfileId: UUID?
  @Environment(\.chromeFontResolver) private var fontResolver

  private var store: BrowserStore { session.store }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch screen {
      case .main:
        mainScreen
      case .form(let editingId):
        BrowserProfileFormSection(
          editingId: editingId,
          canDelete: editingId != nil && store.profiles.count > 1,
          draftName: $draftName,
          draftColor: $draftColor,
          draftMCPAllowed: $draftMCPAllowed,
          nameFocusToken: nameFocusToken,
          localization: localization,
          onBack: { switchScreen(.main) },
          onSave: { saveForm(editingId: editingId) },
          onCancelEsc: onDismiss,
          onRequestDelete: { id in openDeleteConfirm(targetId: id) })
      case .confirmDelete(let targetId):
        if let target = store.profile(id: targetId) {
          BrowserProfileDeleteSection(
            target: target,
            candidates: store.profiles.filter { $0.id != targetId },
            hasReferencingSpaces: store.spaces.contains { $0.profileId == targetId },
            reassignProfileId: $reassignProfileId,
            localization: localization,
            onBack: { openForm(editing: target) },
            onCancel: { switchScreen(.main) },
            onDelete: { fallbackId in
              if session.deleteProfile(targetId, reassigningTo: fallbackId) {
                switchScreen(.main)
              }
            })
        } else {
          mainScreen
        }
      }
    }
    .padding(Theme.Space.note)
  }

  @ViewBuilder
  private var mainScreen: some View {
    let activeSpace = store.activeSpace
    let activeProfile = activeSpace.flatMap { store.profile(id: $0.profileId) }

    if let activeProfile {
      activeProfileHeader(activeProfile)
      dividerLine
      BrowserProfileMCPToggleRow(
        isAllowed: activeProfile.mcpAllowed,
        localization: localization,
        action: {
          _ = session.updateProfile(
            activeProfile.id, name: activeProfile.name,
            color: activeProfile.color, mcpAllowed: !activeProfile.mcpAllowed)
        })
      dividerLine
    }

    Text(localization.string(.browserProfileSectionSpace))
      .font(Font.theme.browserPopoverSection)
      .foregroundStyle(Color.theme.textMuted)
      .padding(.horizontal, 9)
      .padding(.top, 5)
      .padding(.bottom, 3)

    ForEach(store.profiles) { profile in
      BrowserProfileListRow(
        profile: profile,
        isSelected: activeSpace?.profileId == profile.id,
        editTooltip: localization.string(.browserProfileEditTooltip),
        onSelect: {
          if let spaceId = activeSpace?.id {
            _ = session.setSpaceProfile(spaceId, profileId: profile.id)
          }
        },
        onEdit: { openForm(editing: profile) })
    }

    dividerLine

    BrowserPopoverMenuRow(
      glyph: BrowserGlyphs.plus,
      title: localization.string(.browserProfileCreateAction),
      action: { openForm(editing: nil) })
  }

  private func activeProfileHeader(_ profile: BrowserProfile) -> some View {
    HStack(spacing: Theme.Space.step) {
      Circle()
        .fill(profile.color.themeColor)
        .frame(
          width: Theme.Layout.browserSidebarPopoverDot,
          height: Theme.Layout.browserSidebarPopoverDot)
      VStack(alignment: .leading, spacing: 2) {
        fontResolver.text(
          localization.format(.browserProfileHeading, profile.name),
          base: Theme.Typography.browserPopoverTitle
        )
        .font(Font.theme.browserPopoverTitle)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        Text(localization.string(.browserProfileCookieNote))
          .font(Font.theme.browserSidebarProfilePill)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Space.step)
    .padding(.top, Theme.Space.note)
    .padding(.bottom, Theme.Space.step)
  }

  private var dividerLine: some View {
    Rectangle()
      .fill(Color.theme.browserBarBorder)
      .frame(height: Theme.Stroke.hairline)
      .padding(.horizontal, Theme.Space.note)
      .padding(.vertical, Theme.Space.tick)
  }

  private func openForm(editing profile: BrowserProfile?) {
    if let profile {
      draftName = profile.name
      draftColor = profile.color
      draftMCPAllowed = profile.mcpAllowed
      switchScreen(.form(editingId: profile.id))
    } else {
      draftName = ""
      draftColor = .purple
      draftMCPAllowed = false
      switchScreen(.form(editingId: nil))
    }
    nameFocusToken = max(1, nameFocusToken &+ 1)
  }

  private func openDeleteConfirm(targetId: UUID) {
    let target = store.profile(id: targetId)
    let candidates = store.profiles.filter { $0.id != targetId }
    reassignProfileId = Self.defaultReassignProfileId(for: target, candidates: candidates)
    switchScreen(.confirmDelete(targetId: targetId))
  }

  /// 非公開プロファイルの削除時は fail-open を避け、他に非公開候補があればそれを既定付け替え先とする。
  static func defaultReassignProfileId(
    for target: BrowserProfile?, candidates: [BrowserProfile]
  ) -> UUID? {
    if target?.mcpAllowed == false,
      let privateCandidate = candidates.first(where: { !$0.mcpAllowed })
    {
      return privateCandidate.id
    }
    return candidates.first?.id
  }

  private func saveForm(editingId: UUID?) -> Bool {
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if let editingId {
      guard
        session.updateProfile(
          editingId, name: trimmed, color: draftColor, mcpAllowed: draftMCPAllowed) != nil
      else { return false }
    } else {
      guard
        session.createProfile(
          name: trimmed, color: draftColor, mcpAllowed: draftMCPAllowed) != nil
      else { return false }
    }
    switchScreen(.main)
    return true
  }

  private func switchScreen(_ next: Screen) {
    if case .form = screen {
      onBeforeFormUnmount()
    }
    screen = next
  }
}

/// プロファイルポップオーバーの MCP 読み取り許可トグル行。
struct BrowserProfileMCPToggleRow: View {
  let isAllowed: Bool
  let localization: LocalizationStore
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      BrowserGlyphView(glyph: BrowserGlyphs.shield, size: 13, color: Color.theme.textMuted)
      VStack(alignment: .leading, spacing: 2) {
        Text(
          localization.string(isAllowed ? .browserProfileMCPAllowed : .browserProfileMCPBlocked)
        )
        .font(Font.theme.browserSidebarTab)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        Text(
          localization.string(
            isAllowed ? .browserProfileMCPAllowedNote : .browserProfileMCPBlockedNote)
        )
        .font(Font.theme.browserSidebarProfilePill)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(2)
      }
      Spacer(minLength: Theme.Space.tick)
      BrowserTogglePill(isOn: isAllowed)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(isHovered ? Color.theme.selectionFill : .clear)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(perform: action)
  }
}

private struct BrowserProfileListRow: View {
  let profile: BrowserProfile
  let isSelected: Bool
  let editTooltip: String
  let onSelect: () -> Void
  let onEdit: () -> Void
  @State private var isHovered = false
  @State private var isEditHovered = false
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      HStack(spacing: Theme.Space.step) {
        Circle()
          .fill(profile.color.themeColor)
          .frame(width: Theme.Layout.browserSidebarDot, height: Theme.Layout.browserSidebarDot)
        fontResolver.text(profile.name, base: Theme.Typography.browserSidebarTab)
          .font(Font.theme.browserSidebarTab)
          .foregroundStyle(
            isSelected || isHovered ? Color.theme.textPrimary : Color.theme.textSecondary
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
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .onTapGesture(perform: onSelect)

      BrowserGlyphView(
        glyph: BrowserGlyphs.pencil,
        size: 12,
        color: isEditHovered ? Color.theme.textPrimary : Color.theme.textMuted
      )
      .frame(width: 22, height: 22)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
          .fill(isEditHovered ? Color.theme.surfaceInk.opacity(0.12) : .clear)
      )
      .contentShape(Rectangle())
      .onHover { isEditHovered = $0 }
      .onTapGesture(perform: onEdit)
      .help(editTooltip)
    }
    .padding(.leading, 9)
    .padding(.trailing, 5)
    .frame(height: Theme.Layout.browserSidebarRow)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(rowBackground)
    )
    .onHover { isHovered = $0 }
  }

  private var rowBackground: Color {
    if isSelected { return Color.theme.selectionFill }
    if isHovered { return Color.theme.surfaceInk.opacity(Theme.Opacity.browserSidebarItemHover) }
    return .clear
  }
}
