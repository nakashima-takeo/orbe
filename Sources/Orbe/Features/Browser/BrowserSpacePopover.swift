import SwiftUI

/// 自由スペースの作成・編集・削除確認を行うビュー内ポップオーバー。
struct BrowserSpacePopover: View {
  enum Mode: Equatable {
    case create
    case edit(spaceId: UUID, confirmingDelete: Bool)
  }

  let mode: Mode
  let session: BrowserSession
  let localization: LocalizationStore
  let onBeforeFormUnmount: () -> Void
  let onRequestDeleteConfirm: (UUID) -> Void
  let onDismiss: () -> Void

  @State private var draftName = ""
  @State private var draftIcon: BrowserSpaceIcon = .globe
  @State private var draftProfileId: UUID?
  @State private var nameFocusToken = 0
  @State private var initializedKey = ""

  private var store: BrowserStore { session.store }
  private static let selectableIcons = BrowserSpaceIcon.allCases.filter { $0 != .local }

  var body: some View {
    BrowserPopoverScrollCard {
      VStack(alignment: .leading, spacing: Theme.Space.step) {
        switch mode {
        case .create:
          formBody(editingSpace: nil)
        case .edit(let spaceId, let confirmingDelete):
          if let space = store.space(id: spaceId), space.kind == .free {
            if confirmingDelete {
              deleteConfirmBody(space: space)
            } else {
              formBody(editingSpace: space)
            }
          }
        }
      }
      .padding(Theme.Space.beat)
    }
    .onAppear(perform: syncDraftIfNeeded)
    .onChange(of: mode) { _, _ in syncDraftIfNeeded() }
  }

  // MARK: - 作成／編集フォーム

  private func formBody(editingSpace: BrowserSpace?) -> some View {
    let resolvedProfileId = draftProfileId ?? defaultProfileId(for: editingSpace)
    let canSave =
      !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && resolvedProfileId != nil

    return VStack(alignment: .leading, spacing: Theme.Space.step) {
      Text(
        localization.string(
          editingSpace == nil ? .browserSpaceCreateTitle : .browserSpaceEditTitle)
      )
      .font(Font.theme.browserPopoverTitle)
      .foregroundStyle(Color.theme.textPrimary)

      BrowserPopoverTextFieldBox(
        label: localization.string(.browserSpaceNameLabel),
        text: $draftName,
        placeholder: localization.string(.browserSpaceNamePlaceholder),
        focusToken: nameFocusToken,
        onCommit: { _ in save(editingSpace: editingSpace, profileId: resolvedProfileId) },
        onCancel: dismissForm)

      iconPickerSection
      profilePickerSection(selectedId: resolvedProfileId)
      formActionButtons(
        editingSpace: editingSpace, canSave: canSave, profileId: resolvedProfileId)

      if let editingSpace {
        Rectangle()
          .fill(Color.theme.browserBarBorder)
          .frame(height: Theme.Stroke.hairline)
          .padding(.vertical, 2)
        BrowserPopoverMenuRow(
          glyph: BrowserGlyphs.trash,
          title: localization.string(.browserSpaceDeleteAction),
          isDanger: true,
          action: { onRequestDeleteConfirm(editingSpace.id) })
      }
    }
  }

  private var iconPickerSection: some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      Text(localization.string(.browserSpaceIconLabel))
        .font(Font.theme.browserPopoverSection)
        .foregroundStyle(Color.theme.textMuted)
      HStack(spacing: Theme.Space.tick) {
        ForEach(Self.selectableIcons, id: \.self) { icon in
          iconOption(icon)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private func profilePickerSection(selectedId: UUID?) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      Text(localization.string(.browserSpaceProfileLabel))
        .font(Font.theme.browserPopoverSection)
        .foregroundStyle(Color.theme.textMuted)
      VStack(spacing: 2) {
        ForEach(store.profiles) { profile in
          profileOption(profile, isSelected: profile.id == selectedId)
        }
      }
    }
  }

  private func formActionButtons(
    editingSpace: BrowserSpace?, canSave: Bool, profileId: UUID?
  ) -> some View {
    HStack(spacing: Theme.Space.step) {
      Spacer(minLength: 0)
      BrowserPopoverActionButton(
        title: localization.string(.browserActionCancel),
        style: .secondary,
        action: dismissForm)
      BrowserPopoverActionButton(
        title: localization.string(
          editingSpace == nil ? .browserActionCreate : .browserActionSave),
        style: .primary,
        isEnabled: canSave,
        action: { _ = save(editingSpace: editingSpace, profileId: profileId) })
    }
    .padding(.top, 2)
  }

  // MARK: - 削除確認画面

  private func deleteConfirmBody(space: BrowserSpace) -> some View {
    let tabCount = store.tabs(in: space.id).count
    return VStack(alignment: .leading, spacing: Theme.Space.step) {
      Text(localization.string(.browserSpaceDeleteTitle))
        .font(Font.theme.browserPopoverTitle)
        .foregroundStyle(Color.theme.textPrimary)
      Text(localization.format(.browserSpaceDeleteMessage, space.name, tabCount))
        .font(Font.theme.browserSidebarAction)
        .foregroundStyle(Color.theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: Theme.Space.step) {
        Spacer(minLength: 0)
        BrowserPopoverActionButton(
          title: localization.string(.browserActionCancel),
          style: .secondary,
          action: onDismiss)
        BrowserPopoverActionButton(
          title: localization.string(.browserActionDelete),
          style: .danger,
          action: {
            if session.deleteFreeSpace(space.id) {
              onDismiss()
            }
          })
      }
      .padding(.top, Theme.Space.tick)
    }
  }

  // MARK: - 補助

  private func iconOption(_ icon: BrowserSpaceIcon) -> some View {
    let selected = draftIcon == icon
    return BrowserGlyphView(
      glyph: BrowserGlyphs.spaceIcon(icon),
      size: Theme.Layout.browserIconSize,
      color: selected ? Color.theme.textPrimary : Color.theme.textMuted
    )
    .frame(width: 30, height: 28)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarRowRadius)
        .fill(selected ? Color.theme.selectionFill : Color.theme.surfaceInk.opacity(0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Layout.browserSidebarRowRadius)
        .strokeBorder(
          selected
            ? Color.theme.accentPrimary.opacity(Theme.Opacity.browserSidebarSwitcherBorder)
            : .clear,
          lineWidth: Theme.Stroke.hairline)
    )
    .contentShape(Rectangle())
    .onTapGesture { draftIcon = icon }
  }

  private func profileOption(_ profile: BrowserProfile, isSelected: Bool) -> some View {
    HStack(spacing: Theme.Space.step) {
      Circle()
        .fill(profile.color.themeColor)
        .frame(width: Theme.Layout.browserSidebarDot, height: Theme.Layout.browserSidebarDot)
      Text(profile.name)
        .font(Font.theme.browserSidebarTab)
        .foregroundStyle(isSelected ? Color.theme.textPrimary : Color.theme.textSecondary)
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
    .onTapGesture { draftProfileId = profile.id }
  }

  private func defaultProfileId(for editingSpace: BrowserSpace?) -> UUID? {
    editingSpace?.profileId ?? store.activeSpace?.profileId ?? store.profiles.first?.id
  }

  private func dismissForm() {
    onBeforeFormUnmount()
    onDismiss()
  }

  private func syncDraftIfNeeded() {
    let key = "\(mode)"
    guard initializedKey != key else { return }
    initializedKey = key
    switch mode {
    case .create:
      draftName = ""
      draftIcon = .globe
      draftProfileId = store.activeSpace?.profileId ?? store.profiles.first?.id
      nameFocusToken = max(1, nameFocusToken &+ 1)
    case .edit(let spaceId, let confirmingDelete):
      guard !confirmingDelete, let space = store.space(id: spaceId) else { return }
      draftName = space.name
      draftIcon = space.icon == .local ? .globe : space.icon
      draftProfileId = space.profileId
      nameFocusToken = max(1, nameFocusToken &+ 1)
    }
  }

  private func save(editingSpace: BrowserSpace?, profileId: UUID?) -> Bool {
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let profileId else { return false }
    if let editingSpace {
      guard session.updateFreeSpace(editingSpace.id, name: trimmed, icon: draftIcon) != nil else {
        return false
      }
      if editingSpace.profileId != profileId {
        _ = session.setSpaceProfile(editingSpace.id, profileId: profileId)
      }
    } else {
      guard
        let created = session.createFreeSpace(
          name: trimmed, icon: draftIcon, profileId: profileId)
      else { return false }
      _ = session.selectSpace(.free(created.id))
    }
    dismissForm()
    return true
  }
}
