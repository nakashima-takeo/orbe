import SwiftUI

/// タスク画面のフッター。左は今の選択と焦点で主な操作が何をするかを 1 行で言い（失敗は赤で置き換える）、
/// 右はその場所で効くキーのヒント。
struct TaskPaletteFooter: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      actionLine
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

  @ViewBuilder private var actionLine: some View {
    if let error = model.error {
      Text(l10n.string(errorKey(error))).foregroundStyle(Color.theme.danger)
    } else if let draft = model.draft {
      PaletteActionLine(
        key: draft.field == .description ? "⌘↵" : "↵",
        template: l10n.string(.taskPaletteActionCommit),
        slots: [])
    } else if model.pick != nil {
      TaskPalettePickAction(model: model)
    } else if model.visibleTab == .tasks {
      action
    } else {
      TaskPaletteGitHubAction(model: model)
    }
  }

  @ViewBuilder private var action: some View {
    if case .detail(.field(let field)) = model.area {
      // 編集できない文字の項目（完了のタスクの待ち）には、効かない ↵ を案内しない。
      if !field.isText || model.canEdit(field) {
        PaletteActionLine(
          key: field.isText ? "↵" : "←→", template: l10n.string(fieldActionKey(field)), slots: [])
      }
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
    } else if model.area == .detail(.addLink) {
      PaletteActionLine(key: "↵", template: l10n.string(.taskPaletteActionAddLink), slots: [])
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
        TaskPaletteDoneHeaderAction(model: model)
      case nil:
        EmptyView()
      }
    }
  }

  private var hints: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      if model.draft != nil {
        PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintCancel))
      } else if model.pick != nil {
        PaletteKeyHint(
          key: "⇥",
          label: l10n.string(
            model.visibleTab == .tasks ? .taskPaletteHintScope : .taskPaletteHintFilter))
        PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintStopPicking))
      } else if model.visibleTab == .github {
        TaskPaletteGitHubHints(model: model)
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
    case .description: .taskPaletteActionEditDescription
    }
  }

  private func errorKey(_ error: TaskPaletteError) -> L10nKey {
    switch error {
    case .title: .taskPaletteErrTitle
    case .waiting: .taskPaletteErrWaiting
    case .due: .taskPaletteErrDue
    case .failed: .taskPaletteErrFailed
    case .assign: .taskPaletteErrAssign
    case .link: .taskPaletteErrLink
    }
  }
}

/// GitHub タブのフッターの左（選んだ行と右の欄の場所で、↵ が何をするか）。
private struct TaskPaletteGitHubAction: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    switch model.area {
    case .pane(.assign):
      PaletteActionLine(key: "space", template: l10n.string(.taskPaletteActionToggle), slots: [])
    case .pane(.priority):
      PaletteActionLine(
        key: "←→", template: l10n.string(.taskPaletteActionChangePriority), slots: [])
    case .pane(.due):
      PaletteActionLine(key: "↵", template: l10n.string(.taskPaletteActionEditDue), slots: [])
    case .list, .detail:
      list
    }
  }

  @ViewBuilder private var list: some View {
    if case .more = model.selectedGitHubID, let count = moreCount {
      PaletteActionLine(
        key: "↵", template: l10n.string(.taskPaletteActionMore), slots: [.emphasis("\(count)")])
    } else if let row = model.selectedGitHubRow {
      if let task = row.task {
        PaletteActionLine(
          key: "↵", template: l10n.string(.taskPaletteActionOpenTask),
          slots: [.emphasis(task.label)])
      } else {
        PaletteActionLine(
          key: "↵", template: l10n.string(makeKey(row)), slots: [.emphasis("#\(row.id.number)")])
      }
    }
  }

  private var moreCount: Int? {
    model.gitHubRows.lazy.compactMap { row -> Int? in
      if case .more(let kind, let count) = row, model.selectedGitHubID == .more(kind) {
        count
      } else {
        nil
      }
    }.first
  }

  private func makeKey(_ row: TaskPaletteGitHubItemRow) -> L10nKey {
    guard model.pane.assignsSelf, let role = model.selfRole(row) else {
      return .taskPaletteActionMake
    }
    return role == .assignee ? .taskPaletteActionAssignMake : .taskPaletteActionReviewMake
  }
}

/// GitHub タブのフッターの右のヒント。
private struct TaskPaletteGitHubHints: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    if case .pane(let stop) = model.area {
      // 期限の ↵ は期限を打つ（左の 1 行が言う）。
      if stop != .due { PaletteKeyHint(key: "↵", label: l10n.string(.taskPaletteMakeTask)) }
      PaletteKeyHint(key: "⌘↵", label: l10n.string(.taskPaletteHintOpenInBrowser))
      PaletteKeyHint(key: "↑↓", label: l10n.string(.taskPaletteHintField))
      PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintBack))
    } else if let row = model.selectedGitHubRow {
      if row.task == nil {
        PaletteKeyHint(key: "⌘T", label: l10n.string(.taskPaletteMakeTaskOpen))
        PaletteKeyHint(key: "⌘L", label: l10n.string(.taskPaletteHintLink))
        PaletteKeyHint(key: "→", label: l10n.string(.taskPaletteHintDetail))
      } else {
        PaletteKeyHint(key: "⌘T", label: l10n.string(.taskPaletteHintOpenWorktree))
        PaletteKeyHint(key: "⌘L", label: l10n.string(.taskPaletteHintRelink))
        PaletteKeyHint(key: "⌘⌫", label: l10n.string(.taskPaletteUnlink))
      }
      PaletteKeyHint(key: "⌘↵", label: l10n.string(.taskPaletteHintOpenInBrowser))
      PaletteKeyHint(key: "⇥", label: l10n.string(.taskPaletteHintFilter))
      PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintClose))
    } else {
      PaletteKeyHint(key: "⇥", label: l10n.string(.taskPaletteHintFilter))
      PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintClose))
    }
  }
}

/// 選ぶ状態のフッターの左（↵ で何をどこへ結び付けるか。別のタスクのものなら付け替えを先に言う）。
private struct TaskPalettePickAction: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    switch model.pick {
    case .task(let link, _):
      switch model.selectedID {
      case .task:
        if let task = model.selectedTask {
          line(item: "#\(link.item.number)", to: task, owner: model.pickedItemOwner)
        }
      case .doneHeader:
        TaskPaletteDoneHeaderAction(model: model)
      case .add, nil:
        EmptyView()
      }
    case .item(let id, _):
      if let row = model.selectedGitHubRow,
        let task = model.store.tasks.first(where: { $0.id == id })
      {
        line(
          item: "#\(row.id.number)", to: task,
          owner: row.task.flatMap { owner in model.store.tasks.first { $0.id == owner.id } })
      } else if case .more = model.selectedGitHubID {
        TaskPaletteGitHubAction(model: model)
      }
    case nil:
      EmptyView()
    }
  }

  @ViewBuilder private func line(item: String, to task: TaskItem, owner: TaskItem?) -> some View {
    if let owner, owner.id == task.id {
      PaletteActionLine(
        key: nil, template: l10n.string(.taskPaletteActionLinkedAlready),
        slots: [.emphasis(item), .emphasis(task.title)])
    } else if let owner {
      PaletteActionLine(
        key: "↵", template: l10n.string(.taskPaletteActionMoveItem),
        slots: [.emphasis(item), .emphasis(task.title), .emphasis(owner.title)])
    } else {
      PaletteActionLine(
        key: "↵", template: l10n.string(.taskPaletteActionLinkItem),
        slots: [.emphasis(item), .emphasis(task.title)])
    }
  }
}

/// 完了の見出しのフッターの左（↵ で完了の欄を開閉する）。
private struct TaskPaletteDoneHeaderAction: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    PaletteActionLine(
      key: "↵",
      template: l10n.string(
        model.doneExpanded ? .taskPaletteActionHideDone : .taskPaletteActionShowDone),
      slots: [])
  }
}
