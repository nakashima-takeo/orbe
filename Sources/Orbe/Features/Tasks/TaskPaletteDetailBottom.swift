import SwiftUI

/// 右の欄の末尾。秘書に頼む欄を開いている間は「頼んだ後は、秘書が起こした agent がこの行に出る」だけを出し、それ以外は
/// 「秘書に頼む」（未完了のタスク）と「完了にする」「削除」のボタン。
struct TaskPaletteDetailBottom: View {
  let model: TaskPaletteModel
  let task: TaskItem
  @Environment(\.localization) private var l10n

  var body: some View {
    if model.askingTaskID == task.id {
      Text(l10n.string(.taskPaletteAskAfter))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.top, Theme.Space.beat)
    } else {
      if task.status != .done {
        TaskPaletteSecretaryButton(onTap: { model.openAsk(task.id) })
          .padding(.top, Theme.Space.beat)
      }
      TaskPaletteDetailActions(model: model, task: task)
        .padding(.top, Theme.Space.beat)
    }
  }
}

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

/// 右の欄の「⌘↵ ◐ 秘書に頼む — このタスクを渡す」（クリックで行の直下に頼む欄を開く）。
private struct TaskPaletteSecretaryButton: View {
  let onTap: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.row)
    Button(action: onTap) {
      HStack(spacing: Theme.Space.note) {
        Text("⌘↵").font(Font.theme.meta).foregroundStyle(Color.theme.textMuted)
        SecretaryMark(size: 10)
        Text(l10n.string(.taskPaletteAskSecretary))
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textPrimary)
        Spacer(minLength: Theme.Space.step)
        Text(l10n.string(.taskPaletteAskHandOver))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
      }
      .lineLimit(1)
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .frame(height: TaskPaletteFieldMetrics.buttonHeight + Theme.Space.step)
      .background(shape.fill(Color.theme.surfaceInk.opacity(0.04)))
      .overlay(shape.strokeBorder(Color.theme.surface1, lineWidth: Theme.Stroke.hairline))
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .focusable(false)
  }
}

/// 右の欄の末尾のボタン（「space 完了にする」「⌘⌫ 削除」）。
private struct TaskPaletteDetailActions: View {
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
