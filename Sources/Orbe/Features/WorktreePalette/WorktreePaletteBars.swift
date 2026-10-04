import SwiftUI

/// 一覧の起動先とベースのバー。起動先は名前の長さのボタンを並べ（⇥ で巡回・クリックで選択）、ベースは
/// 作成行の選択中だけ選択肢のボタン（⇧⇥ で巡回）、それ以外の行では「なし — …」の言葉でその行の ↵ を言う。
struct WorktreePaletteBars: View {
  @Bindable var model: WorktreePaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.step) {
      bar(label: .worktreePaletteTargetLabel, hint: ("⇥", .worktreePaletteHintSwitch)) {
        ForEach(Array(model.targets.enumerated()), id: \.offset) { index, target in
          WorktreePaletteChoiceButton(
            title: target.name,
            tag: target == model.defaultTarget ? l10n.string(.worktreePaletteDefaultTag) : nil,
            selected: index == model.selectedTargetIndex
          ) { model.chooseTarget(at: index) }
        }
      }
      if model.isCreateRowSelected {
        bar(label: .worktreePaletteBaseLabel, hint: ("⇧⇥", .worktreePaletteHintSwitch)) {
          ForEach(model.baseChoices, id: \.role) { choice in
            WorktreePaletteChoiceButton(
              title: choice.role == .other ? l10n.string(.worktreePaletteBaseOther) : choice.name,
              tag: tag(for: choice.role), selected: choice == model.selectedBaseChoice
            ) { model.chooseBase(choice.role) }
          }
        }
      } else {
        bar(label: .worktreePaletteBaseLabel, hint: nil) { baseNote }
      }
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.beat)
  }

  private func bar<Content: View>(
    label: L10nKey, hint: (key: String, label: L10nKey)?, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: Theme.Space.step) {
      Text(l10n.string(label))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .frame(width: 56, alignment: .leading)
      content()
      Spacer(minLength: Theme.Space.step)
      if let hint {
        PaletteKeyHint(key: hint.key, label: l10n.string(hint.label))
          .font(Font.theme.sectionLabel)
          .foregroundStyle(Color.theme.textMuted)
          .fixedSize()
          .layoutPriority(1)
      }
    }
  }

  private func tag(for role: WorktreeBaseRole) -> String? {
    switch role {
    case .previous: l10n.string(.worktreePaletteBasePreviousTag)
    case .defaultBranch: l10n.string(.worktreePaletteDefaultTag)
    case .current: l10n.string(.worktreePaletteCurrentTag)
    case .picked, .other: nil
    }
  }

  /// 作成行以外の選択中に出す「なし — …」。行が無ければ何も言わない。
  @ViewBuilder private var baseNote: some View {
    if let note = model.selectedItem?.baseNote {
      PaletteActionLine(
        key: nil, template: l10n.string(note.key), slots: note.values.map { .emphasis($0) }
      )
      .padding(.horizontal, Theme.Space.beat)
      .padding(.vertical, 5)
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .strokeBorder(
            Color.theme.borderInk.opacity(0.18),
            style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: [3, 3]))
      )
    }
  }
}

/// 起動先・ベースの選択肢のボタン（名前の長さ）。選択中は accent の枠と淡い地。札（「既定」等）は accent。
/// 焦点は取らない——クリックで入力欄から焦点を奪わず、キーはいつも入力欄が受ける。
struct WorktreePaletteChoiceButton: View {
  let title: String
  let tag: String?
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      // 窓が狭くて並びきらないときは名前が中ほどで縮む（札は縮めない）。
      HStack(spacing: Theme.Space.note) {
        Text(title)
          .font(Font.theme.chrome)
          .foregroundStyle(selected ? Color.theme.textPrimary : Color.theme.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if let tag {
          Text(tag)
            .font(Font.theme.sectionLabel)
            .foregroundStyle(Color.theme.accentPrimary)
            .lineLimit(1)
            .fixedSize()
        }
      }
      .padding(.horizontal, Theme.Space.beat)
      .padding(.vertical, Theme.Space.tick + 1)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .fill(selected ? Color.theme.tintAccent : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .strokeBorder(
            selected ? Color.theme.accentPrimary.opacity(0.6) : Color.theme.borderInk.opacity(0.14),
            lineWidth: Theme.Stroke.hairline)
      )
      .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
    }
    .buttonStyle(.plain)
    .focusable(false)
  }
}
