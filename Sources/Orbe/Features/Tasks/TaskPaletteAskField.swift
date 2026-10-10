import SwiftUI

/// タスクの行の直下に開く、そのタスクを秘書に頼む欄（「◐ #218 を秘書に頼む」・補足の入力・「秘書はこのタスクを対象に
/// 動く」）。↵ で頼み、esc か欄を離れると何も送らずに閉じる。箱の書き出しはタスクの行のタイトルにそろえる。
struct TaskPaletteAskField: View {
  @Bindable var model: TaskPaletteModel
  let row: TaskPaletteAskRow
  let focus: FocusState<TaskPaletteFocusTarget?>.Binding
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.md)
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      HStack(spacing: Theme.Space.note) {
        SecretaryMark(size: 10)
        fontResolver.text(l10n.format(.taskPaletteAskTitle, row.label), base: Theme.Typography.meta)
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.accentBright)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: Theme.Space.step)
        Text(l10n.string(.taskPaletteAskOptional))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .fixedSize()
      }
      TextField("", text: $model.draftText)
        .textFieldStyle(.plain)
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textPrimary)
        .tint(Color.theme.accentPrimary)
        .focused(focus, equals: .ask)
        .onSubmitIgnoringKeyRepeat { model.sendAsk() }
        .onKeyPress { model.handleEditKey($0) }
        // 欄は開くときに生まれるので、生まれた後にもう一度焦点を当てる（先に当てた焦点は取りこぼされる）。
        .onAppear { model.focus() }
      Text(l10n.string(.taskPaletteAskScope))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, Theme.Space.span)
    .frame(height: TaskPaletteRowMetrics.askBox)
    .overlay(shape.strokeBorder(Color.theme.accentPrimary.opacity(0.7), lineWidth: 1))
    .padding(.leading, 22 + TaskPaletteRowMetrics.glyphColumn + Theme.Space.step)
    .padding(.trailing, Theme.Space.step)
    .padding(.vertical, TaskPaletteRowMetrics.askGap)
    .frame(height: TaskPaletteRowMetrics.ask)
  }
}
