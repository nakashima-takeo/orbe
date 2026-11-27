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
  let onRequestDeleteConfirm: ((UUID) -> Void)?
  let onDismiss: () -> Void

  @State private var draftName: String
  @State private var draftIcon: BrowserSpaceIcon
  @State private var draftProfileId: UUID?
  @State private var nameFocusToken: Int
  @Environment(\.chromeFontResolver) private var fontResolver

  private var store: BrowserStore { session.store }
  private static let selectableIcons = BrowserSpaceIcon.allCases.filter { $0 != .local }

  init(
    mode: Mode,
    session: BrowserSession,
    localization: LocalizationStore,
    onRequestDeleteConfirm: ((UUID) -> Void)? = nil,
    onDismiss: @escaping () -> Void
  ) {
    self.mode = mode
    self.session = session
    self.localization = localization
    self.onRequestDeleteConfirm = onRequestDeleteConfirm
    self.onDismiss = onDismiss
    switch mode {
    case .create:
      _draftName = State(initialValue: "")
      _draftIcon = State(initialValue: .globe)
      _draftProfileId = State(
        initialValue: session.store.activeSpace?.profileId ?? session.store.profiles.first?.id)
      _nameFocusToken = State(initialValue: 1)
    case .edit(let spaceId, let confirmingDelete):
      if !confirmingDelete, let space = session.store.space(id: spaceId) {
        _draftName = State(initialValue: space.name)
        _draftIcon = State(initialValue: space.icon == .local ? .globe : space.icon)
        _draftProfileId = State(initialValue: space.profileId)
        _nameFocusToken = State(initialValue: 1)
      } else {
        _draftName = State(initialValue: "")
        _draftIcon = State(initialValue: .globe)
        _draftProfileId = State(initialValue: nil)
        _nameFocusToken = State(initialValue: 0)
      }
    }
  }

  var body: some View {
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
        onCancel: onDismiss)

      iconPickerSection
      profilePickerSection(selectedId: resolvedProfileId)
      formActionButtons(
        editingSpace: editingSpace, canSave: canSave, profileId: resolvedProfileId)

      if let editingSpace, let onRequestDeleteConfirm {
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
          BrowserPopoverProfileOptionRow(
            profile: profile,
            isSelected: profile.id == selectedId,
            action: { draftProfileId = profile.id })
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
        action: onDismiss)
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
    let messageKey: L10nKey =
      tabCount == 1 ? .browserSpaceDeleteMessageOne : .browserSpaceDeleteMessageOther
    return VStack(alignment: .leading, spacing: Theme.Space.step) {
      Text(localization.string(.browserSpaceDeleteTitle))
        .font(Font.theme.browserPopoverTitle)
        .foregroundStyle(Color.theme.textPrimary)
      fontResolver.text(
        localization.format(messageKey, space.name, tabCount),
        base: Theme.Typography.browserSidebarAction
      )
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

  private func defaultProfileId(for editingSpace: BrowserSpace?) -> UUID? {
    editingSpace?.profileId ?? store.activeSpace?.profileId ?? store.profiles.first?.id
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
    onDismiss()
    return true
  }
}
