import SwiftUI

/// タスク画面のフッター。左は今の選択と焦点で主な操作が何をするかを 1 行で言い（失敗は赤で置き換える）、
/// 右はその場所で効くキーのヒント。
struct TaskPaletteFooter: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      description
        .font(Font.theme.meta)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Space.step)
      hints
        .font(Font.theme.sectionLabel)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize()
        .layoutPriority(1)
    }
    .padding(.horizontal, Theme.Space.phrase)
    .frame(height: 44)
  }

  @ViewBuilder private var description: some View {
    if let error = model.error {
      Text(l10n.string(errorKey(error))).foregroundStyle(Color.theme.danger)
    } else if model.tab == .tasks {
      action
    }
  }

  @ViewBuilder private var action: some View {
    if let draft = model.draft {
      PaletteActionLine(
        key: draft.field == .memo ? "⌘↵" : "↵", template: l10n.string(.taskPaletteActionCommit),
        slots: [])
    } else if case .detail(.field(let field)) = model.area {
      PaletteActionLine(
        key: field.isText ? "↵" : "←→", template: l10n.string(fieldActionKey(field)), slots: [])
    } else if model.area == .detail(.agent) {
      if let task = model.selectedTask, let agent = model.agent(of: task) {
        PaletteActionLine(
          key: "↵", template: l10n.string(.taskPaletteActionGoToTab),
          slots: [.emphasis(agent.tabTitle)])
      }
    } else if case .detail(.link(let item)) = model.area {
      PaletteActionLine(
        key: "↵", template: l10n.string(.taskPaletteActionOpenLink),
        slots: [
          .emphasis(
            GitHubItemText.label(item, primary: model.selectedTask?.links.first?.item))
        ])
    } else {
      switch model.selectedID {
      case .add:
        PaletteActionLine(
          key: "↵", template: l10n.string(.taskPaletteAdd),
          slots: [.emphasis(model.query.trimmingCharacters(in: .whitespacesAndNewlines))])
      case .task:
        if let task = model.selectedTask {
          PaletteActionLine(
            key: model.query.isEmpty ? "space" : "↵",
            template: l10n.string(
              task.status == .done ? .taskPaletteActionReopen : .taskPaletteActionDone),
            slots: [.emphasis(task.title)])
        }
      case .doneHeader:
        PaletteActionLine(
          key: "↵",
          template: l10n.string(
            model.doneExpanded ? .taskPaletteActionHideDone : .taskPaletteActionShowDone),
          slots: [])
      case nil:
        EmptyView()
      }
    }
  }

  private var hints: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      if model.draft != nil {
        PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintCancel))
      } else if model.tab == .github {
        PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintClose))
      } else if case .detail(let stop) = model.area {
        PaletteKeyHint(key: "⌘T", label: l10n.string(.taskPaletteHintOpenWorktree))
        if case .link = stop {
          PaletteKeyHint(key: "⌫", label: l10n.string(.taskPaletteUnlink))
        }
        PaletteKeyHint(key: "↑↓", label: l10n.string(.taskPaletteHintField))
        PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintBack))
      } else {
        PaletteKeyHint(key: "⌘T", label: l10n.string(.taskPaletteHintOpenWorktree))
        PaletteKeyHint(key: "→", label: l10n.string(.taskPaletteHintDetail))
        PaletteKeyHint(key: "⌥↑↓", label: l10n.string(.taskPaletteHintReorder))
        PaletteKeyHint(key: "⇥", label: l10n.string(.taskPaletteHintScope))
        PaletteKeyHint(key: "⌘⌫", label: l10n.string(.taskPaletteDelete))
        PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintClose))
      }
    }
  }

  private func fieldActionKey(_ field: TaskDetailField) -> L10nKey {
    switch field {
    case .title: .taskPaletteActionEditTitle
    case .status: .taskPaletteActionChangeStatus
    case .waiting: .taskPaletteActionEditWaiting
    case .priority: .taskPaletteActionChangePriority
    case .due: .taskPaletteActionEditDue
    case .workspace: .taskPaletteActionChangeWorkspace
    case .memo: .taskPaletteActionEditMemo
    }
  }

  private func errorKey(_ error: TaskPaletteError) -> L10nKey {
    switch error {
    case .title: .taskPaletteErrTitle
    case .waiting: .taskPaletteErrWaiting
    case .due: .taskPaletteErrDue
    case .failed: .taskPaletteErrFailed
    }
  }
}
