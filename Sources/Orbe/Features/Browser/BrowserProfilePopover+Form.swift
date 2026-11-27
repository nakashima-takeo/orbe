import SwiftUI

/// プロファイルポップオーバー内の作成／編集フォーム画面。
struct BrowserProfileFormSection: View {
  let editingId: UUID?
  let canDelete: Bool
  @Binding var draftName: String
  @Binding var draftColor: BrowserProfileColor
  @Binding var draftMCPAllowed: Bool
  let nameFocusToken: Int
  let localization: LocalizationStore
  let onBack: () -> Void
  let onSave: () -> Bool
  let onCancelEsc: () -> Void
  let onRequestDelete: (UUID) -> Void

  var body: some View {
    let isValid = !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let titleKey: L10nKey =
      editingId == nil ? .browserProfileCreateTitle : .browserProfileEditTitle

    VStack(alignment: .leading, spacing: Theme.Space.step) {
      BrowserPopoverSubHeader(
        title: localization.string(titleKey),
        backTooltip: localization.string(.browserActionBack),
        onBack: onBack
      )
      .padding(.horizontal, Theme.Space.note)
      .padding(.vertical, Theme.Space.tick)

      BrowserPopoverTextFieldBox(
        label: localization.string(.browserProfileNameLabel),
        text: $draftName,
        placeholder: localization.string(.browserProfileNamePlaceholder),
        focusToken: nameFocusToken,
        onCommit: { _ in onSave() },
        onCancel: onCancelEsc
      )
      .padding(.horizontal, Theme.Space.note)

      colorPicker
        .padding(.horizontal, Theme.Space.note)

      BrowserProfileMCPToggleRow(
        isAllowed: draftMCPAllowed,
        localization: localization,
        action: { draftMCPAllowed.toggle() })

      HStack(spacing: Theme.Space.step) {
        Spacer(minLength: 0)
        BrowserPopoverActionButton(
          title: localization.string(.browserActionCancel),
          style: .secondary,
          action: onBack)
        BrowserPopoverActionButton(
          title: localization.string(editingId == nil ? .browserActionCreate : .browserActionSave),
          style: .primary,
          isEnabled: isValid,
          action: { _ = onSave() })
      }
      .padding(.horizontal, Theme.Space.note)
      .padding(.top, 2)

      if let editingId, canDelete {
        Rectangle()
          .fill(Color.theme.browserBarBorder)
          .frame(height: Theme.Stroke.hairline)
          .padding(.horizontal, Theme.Space.note)
          .padding(.vertical, Theme.Space.tick)
        BrowserPopoverMenuRow(
          glyph: BrowserGlyphs.trash,
          title: localization.string(.browserProfileDeleteAction),
          isDanger: true,
          action: { onRequestDelete(editingId) })
      }
    }
    .padding(.bottom, Theme.Space.tick)
  }

  private var colorPicker: some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      Text(localization.string(.browserProfileColorLabel))
        .font(Font.theme.browserPopoverSection)
        .foregroundStyle(Color.theme.textMuted)
      HStack(spacing: Theme.Space.step) {
        ForEach(BrowserProfileColor.allCases, id: \.self) { color in
          Circle()
            .fill(color.themeColor)
            .frame(width: 20, height: 20)
            .overlay(
              Circle()
                .strokeBorder(
                  draftColor == color ? Color.theme.textPrimary : .clear,
                  lineWidth: 2)
            )
            .contentShape(Circle())
            .onTapGesture { draftColor = color }
        }
        Spacer(minLength: 0)
      }
    }
  }
}

/// プロファイルポップオーバー内の付け替え削除確認サブ画面（`NSAlert` 不使用）。
struct BrowserProfileDeleteSection: View {
  let target: BrowserProfile
  let candidates: [BrowserProfile]
  let hasReferencingSpaces: Bool
  @Binding var reassignProfileId: UUID?
  let localization: LocalizationStore
  let onBack: () -> Void
  let onCancel: () -> Void
  let onDelete: (UUID) -> Void
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    let defaultFallbackId = BrowserProfilePopover.defaultReassignProfileId(
      for: target, candidates: candidates)
    let resolvedFallback =
      candidates.first(where: { $0.id == reassignProfileId })
      ?? candidates.first(where: { $0.id == defaultFallbackId })
    let exposesPrivateSpaces =
      hasReferencingSpaces && !target.mcpAllowed && resolvedFallback?.mcpAllowed == true

    VStack(alignment: .leading, spacing: Theme.Space.step) {
      BrowserPopoverSubHeader(
        title: localization.string(.browserProfileDeleteTitle),
        backTooltip: localization.string(.browserActionBack),
        onBack: onBack
      )
      .padding(.horizontal, Theme.Space.note)
      .padding(.vertical, Theme.Space.tick)

      fontResolver.text(
        localization.format(.browserProfileDeleteMessage, target.name),
        base: Theme.Typography.browserSidebarAction
      )
      .font(Font.theme.browserSidebarAction)
      .foregroundStyle(Color.theme.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, Theme.Space.note)

      if hasReferencingSpaces, !candidates.isEmpty {
        reassignPicker(selectedId: resolvedFallback?.id)
          .padding(.horizontal, Theme.Space.note)
      }

      if exposesPrivateSpaces {
        Text(localization.string(.browserProfileReassignMCPExposeWarning))
          .font(Font.theme.browserSidebarProfilePill)
          .foregroundStyle(Color.theme.conflict)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Theme.Space.note)
      }

      HStack(spacing: Theme.Space.step) {
        Spacer(minLength: 0)
        BrowserPopoverActionButton(
          title: localization.string(.browserActionCancel),
          style: .secondary,
          action: onCancel)
        BrowserPopoverActionButton(
          title: localization.string(.browserActionDelete),
          style: .danger,
          isEnabled: resolvedFallback != nil,
          action: {
            if let fallback = resolvedFallback { onDelete(fallback.id) }
          })
      }
      .padding(.horizontal, Theme.Space.note)
      .padding(.top, Theme.Space.tick)
    }
    .padding(.bottom, Theme.Space.tick)
  }

  private func reassignPicker(selectedId: UUID?) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      Text(localization.string(.browserProfileReassignLabel))
        .font(Font.theme.browserPopoverSection)
        .foregroundStyle(Color.theme.textMuted)
      ForEach(candidates) { candidate in
        BrowserPopoverProfileOptionRow(
          profile: candidate,
          isSelected: candidate.id == selectedId,
          usePrimaryTextWhenUnselected: true,
          action: { reassignProfileId = candidate.id })
      }
    }
  }
}
