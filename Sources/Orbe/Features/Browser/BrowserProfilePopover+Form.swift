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

  var body: some View {
    let resolvedFallback =
      candidates.first(where: { $0.id == reassignProfileId })?.id ?? candidates.first?.id

    VStack(alignment: .leading, spacing: Theme.Space.step) {
      BrowserPopoverSubHeader(
        title: localization.string(.browserProfileDeleteTitle),
        backTooltip: localization.string(.browserActionBack),
        onBack: onBack
      )
      .padding(.horizontal, Theme.Space.note)
      .padding(.vertical, Theme.Space.tick)

      Text(localization.format(.browserProfileDeleteMessage, target.name))
        .font(Font.theme.browserSidebarAction)
        .foregroundStyle(Color.theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Space.note)

      if hasReferencingSpaces, !candidates.isEmpty {
        reassignPicker(selectedId: resolvedFallback)
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
            if let fallback = resolvedFallback { onDelete(fallback) }
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
        let selected = candidate.id == selectedId
        HStack(spacing: Theme.Space.step) {
          Circle()
            .fill(candidate.color.themeColor)
            .frame(width: Theme.Layout.browserSidebarDot, height: Theme.Layout.browserSidebarDot)
          Text(candidate.name)
            .font(Font.theme.browserSidebarTab)
            .foregroundStyle(Color.theme.textPrimary)
            .lineLimit(1)
          Spacer(minLength: 0)
          if selected {
            BrowserGlyphView(glyph: BrowserGlyphs.check, size: 12, color: Color.theme.accentBright)
          }
        }
        .padding(.horizontal, Theme.Space.step)
        .frame(height: 28)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.row)
            .fill(selected ? Color.theme.selectionFill : Color.theme.surfaceInk.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture { reassignProfileId = candidate.id }
      }
    }
  }
}
