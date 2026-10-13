import SwiftUI

/// 入力欄から今足したタスクの見出し（「タスク · 今 ⌘⇧X から足した」）。
struct TaskJustAddedHeading: View {
  @Environment(\.localization) private var l10n

  var body: some View {
    Text(l10n.string(.taskPaletteHeadingTask) + " · " + l10n.string(.taskPaletteAddedHeading))
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
  }
}

/// 右の欄の末尾のボタン（「space 完了にする」「⌘⌫ 削除」）。
struct TaskPaletteDetailActions: View {
  let model: TaskPaletteModel
  let task: TaskItem
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack {
      Button {
        model.toggleDone(task.id)
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text("space").foregroundStyle(Color.theme.textMuted)
          Text(l10n.string(task.status == .done ? .taskPaletteReopen : .taskPaletteMarkDone))
            .foregroundStyle(Color.theme.textPrimary)
        }
        .font(Font.theme.workspaceName)
        .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
        .frame(height: TaskPaletteFieldMetrics.buttonHeight)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.row)
            .fill(Color.theme.surfaceInk.opacity(0.06))
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
      Spacer(minLength: Theme.Space.step)
      Button {
        model.delete(task.id)
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text("⌘⌫").font(Font.theme.meta)
          Text(l10n.string(.taskPaletteDelete)).font(Font.theme.workspaceName)
        }
        .foregroundStyle(Color.theme.danger)
        .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
        .frame(height: TaskPaletteFieldMetrics.buttonHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
  }
}
