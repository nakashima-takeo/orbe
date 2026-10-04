import SwiftUI

/// GitHub タブの右の欄。選んでいる項目の見出し・タイトル・関係の文に続けて、結び付いていない行では「タスクに
/// する」ための値（自分を足すか・優先度・期限）とボタン、結び付いている行では結び付いたタスクとボタンを出す。
/// 選ぶ状態の間は、見出しと結び付いたタスクだけを出す（操作は一覧の ↵ だけ）。期限の入力欄は常に mount して
/// おく（新しく mount した入力欄は `@FocusState` を取りこぼす。詳細と同じ規約）。
struct TaskPaletteGitHubPane: View {
  @Bindable var model: TaskPaletteModel
  let focus: FocusState<TaskPaletteFocusTarget?>.Binding
  @Environment(\.localization) private var l10n

  var body: some View {
    if model.gitHubBody == .lists, let row = model.selectedGitHubRow {
      VStack(alignment: .leading, spacing: 0) {
        heading(row)
        if let task = row.task {
          linkedTask(task.id, row: row)
            .padding(.top, Theme.Space.bar)
          Spacer(minLength: Theme.Space.bar)
          if model.pick == nil { linkedActions(row, task) }
        } else if model.pick == nil {
          divider.padding(.top, Theme.Space.bar)
          values(row)
          Spacer(minLength: Theme.Space.bar)
          unlinkedActions(row)
        } else {
          Spacer(minLength: 0)
        }
      }
      .padding(.horizontal, Theme.Space.phrase)
      .padding(.top, Theme.Space.span)
      .padding(.bottom, Theme.Space.span)
    } else {
      Color.clear
    }
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  /// 「⊙ orbe#221 · 今日」（PR は「· ✓ CI · レビュー待ち」も）・タイトル・関係の文。
  private func heading(_ row: TaskPaletteGitHubItemRow) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Space.note) {
        TaskLinkGlyph(kind: row.item.kind)
        meta(row).lineLimit(1)
      }
      .font(Font.theme.codeCompact)
      .padding(.bottom, Theme.Space.step)
      Text(row.item.title)
        .font(Font.theme.taskHeading)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(2)
        .padding(.bottom, Theme.Space.tick)
      if let relation = TaskGitHubRelationText.text(row.relation, l10n) {
        Text(relation)
          .font(Font.theme.taskText)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
      }
    }
  }

  /// Issue は更新日、PR は CI とレビュー状態を添える。
  private func meta(_ row: TaskPaletteGitHubItemRow) -> Text {
    let muted = { (text: String) in Text(text).foregroundStyle(Color.theme.textMuted) }
    var parts = [muted("\(row.id.repoName)#\(row.id.number)")]
    if case .pullRequest(let checks, let phase) = GitHubItemText.state(row.item.summary) {
      if let checks { parts.append(TaskChecksMark.text(checks) + muted(" CI")) }
      if let phase { parts.append(muted(GitHubItemText.phaseText(phase, l10n.language))) }
    } else {
      let updated = TaskItem.DueDate(row.item.updatedAt, timeZone: model.timeZone)
      parts.append(
        muted(
          updated == model.today
            ? l10n.string(.taskPaletteToday) : TaskDueText.date(updated, today: model.today)))
    }
    return parts.dropFirst().reduce(parts[0]) { $0 + muted(" · ") + $1 }
  }

  // MARK: - 結び付いていない行

  private func values(_ row: TaskPaletteGitHubItemRow) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let role = model.selfRole(row) {
        assignCheck(role)
        failure(row)
        divider
      }
      paneRow(.priority, label: .taskPaletteFieldPriority) {
        TaskPaletteSegments(
          segments: [TaskItem.Priority.high, .medium, .low].map { priority in
            TaskPaletteSegments.Segment(
              title: l10n.string(Self.priorityKey(priority)), count: nil,
              selected: model.pane.priority == priority,
              action: { model.setPanePriority(priority) })
          }, font: Font.theme.taskText, height: 24, selectedFill: Color.theme.tintAccent)
      }
      .onTapGesture { model.setPanePriority(model.pane.priority) }
      divider
      paneRow(.due, label: .taskPaletteFieldDue) { dueValue }
        .onTapGesture { if model.draft == nil { model.beginPaneDue() } }
      divider
    }
  }

  /// 「☑ 自分をアサインする / GitHub の担当者に自分を追加する」。
  private func assignCheck(_ role: GitHubSelfRole) -> some View {
    HStack(alignment: .top, spacing: Theme.Space.beat) {
      Image(systemName: model.pane.assignsSelf ? "checkmark.square.fill" : "square")
        .font(.system(size: 14))
        .foregroundStyle(
          model.pane.assignsSelf ? Color.theme.accentPrimary : Color.theme.textMuted)
      VStack(alignment: .leading, spacing: Theme.Space.tick) {
        Text(l10n.string(role == .assignee ? .taskPaletteAssignSelf : .taskPaletteReviewSelf))
          .font(Font.theme.taskText)
          .foregroundStyle(Color.theme.textPrimary)
        Text(
          l10n.string(role == .assignee ? .taskPaletteAssignSelfNote : .taskPaletteReviewSelfNote)
        )
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.textMuted)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.vertical, Theme.Space.beat)
    .padding(.horizontal, Theme.Space.step)
    .background(focusFill(.assign))
    .padding(.horizontal, -Theme.Space.step)
    .contentShape(Rectangle())
    .onTapGesture { model.togglePaneAssign() }
  }

  /// その項目の書き込みの失敗（画面を閉じた後の失敗も、次に選んだときに出る）。
  @ViewBuilder private func failure(_ row: TaskPaletteGitHubItemRow) -> some View {
    if let role = model.writeFailure(row.id) {
      Text(l10n.string(role == .assignee ? .taskPaletteAssignFailed : .taskPaletteReviewFailed))
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.danger)
        .lineLimit(2)
        .padding(.bottom, Theme.Space.beat)
    }
  }

  private func paneRow<Value: View>(
    _ stop: TaskGitHubPaneStop, label: L10nKey, @ViewBuilder value: () -> Value
  ) -> some View {
    HStack(spacing: 0) {
      Text(l10n.string(label))
        .font(Font.theme.taskText)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .frame(width: 84, alignment: .leading)
      value()
      Spacer(minLength: 0)
    }
    .frame(height: 38)
    .padding(.horizontal, Theme.Space.step)
    .background(focusFill(stop))
    .padding(.horizontal, -Theme.Space.step)
    .contentShape(Rectangle())
  }

  private func focusFill(_ stop: TaskGitHubPaneStop) -> some View {
    RoundedRectangle(cornerRadius: Theme.Radius.row)
      .fill(
        model.area == .pane(stop) && model.draft?.target != .paneDue
          ? Color.theme.selectionFill : .clear)
  }

  private var isEditingDue: Bool { model.draft?.target == .paneDue }

  private var dueValue: some View {
    ZStack(alignment: .leading) {
      TextField("", text: $model.draftText)
        .textFieldStyle(.plain)
        .font(Font.theme.taskText)
        .foregroundStyle(Color.theme.textPrimary)
        .tint(Color.theme.accentPrimary)
        .focused(focus, equals: .paneDue)
        .onSubmit { model.endEditing(commit: true) }
        .onKeyPress { model.handleEditKey($0, composing: IMEComposition.isActive) }
        .opacity(isEditingDue ? 1 : 0)
        .allowsHitTesting(isEditingDue)
      if !isEditingDue {
        if let due = model.pane.due {
          HStack(spacing: Theme.Space.step) {
            Text(
              TaskDueText.label(
                due, today: model.today, weekdays: TaskDueText.weekdays(l10n.language))
            )
            .foregroundStyle(Color.theme.textPrimary)
            Text("·").foregroundStyle(Color.theme.textMuted)
            Button {
              model.clearPaneDue()
            } label: {
              Text(l10n.string(.taskPaletteClear)).foregroundStyle(Color.theme.textMuted)
            }
            .buttonStyle(.plain)
            .focusable(false)
          }
          .font(Font.theme.taskText)
          .lineLimit(1)
        } else {
          Text("＋ " + l10n.string(.taskPaletteSetDue))
            .font(Font.theme.taskText)
            .foregroundStyle(Color.theme.textSecondary)
            .lineLimit(1)
        }
      }
    }
  }

  private func unlinkedActions(_ row: TaskPaletteGitHubItemRow) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.beat) {
      Text(l10n.string(.taskPaletteMakeTaskNote))
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
      HStack(spacing: Theme.Space.beat) {
        actionButton("↵", .taskPaletteMakeTask, primary: true) { model.makeTask(row) }
        actionButton("⌘T", .taskPaletteMakeTaskOpen) { model.openWorktreePaletteFromGitHub() }
      }
      divider.padding(.top, Theme.Space.tick)
      Button {
        model.linkSelectedGitHubItem()
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text("⌘L").foregroundStyle(Color.theme.accentBright)
          Text(l10n.string(.taskPaletteLinkExisting)).foregroundStyle(Color.theme.textPrimary)
        }
        .font(Font.theme.taskText)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
  }
}

/// 結び付いている行の欄と、ボタンの部品。
extension TaskPaletteGitHubPane {
  // MARK: - 結び付いている行

  /// 「🔗 結び付いているタスク / ◐ #212 タスク機能の設計 / 進行中 · claude 作業中 12分」。
  @ViewBuilder private func linkedTask(_ id: Int, row: TaskPaletteGitHubItemRow) -> some View {
    if let task = model.store.tasks.first(where: { $0.id == id }) {
      VStack(alignment: .leading, spacing: Theme.Space.tick) {
        HStack(spacing: Theme.Space.note) {
          Image(systemName: "link").font(.system(size: 10, weight: .semibold))
          Text(l10n.string(.taskPaletteLinkedTask))
        }
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.textMuted)
        HStack(spacing: Theme.Space.step) {
          TaskStatusGlyph(glyph: TaskPaletteTaskRow.Glyph(task))
          Text(row.task?.label ?? task.title)
            .font(Font.theme.taskText)
            .foregroundStyle(Color.theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        linkedTaskState(task)
          .font(Font.theme.codeCompact)
          .lineLimit(1)
          .padding(.leading, 14 + Theme.Space.step)
      }
      .padding(Theme.Space.beat)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.md)
          .fill(Color.theme.surfaceInk.opacity(0.04)))
      failure(row).padding(.top, Theme.Space.step)
    }
  }

  /// 「進行中 · claude 作業中 12分」（agent の札は u6 の索引。作業中・入力待ちだけ）。
  private func linkedTaskState(_ task: TaskItem) -> some View {
    let status = l10n.string(Self.statusKey(task.status))
    let agent = task.status == .done ? nil : model.agent(of: task).flatMap { $0.isBusy ? $0 : nil }
    return TimelineView(.periodic(from: agent?.since ?? .distantPast, by: 60)) { context in
      HStack(spacing: Theme.Space.note) {
        Text(status)
        if let agent {
          Text("·").foregroundStyle(Color.theme.textMuted)
          Text(
            agent.state == .working
              ? [
                agent.name, l10n.string(.taskPaletteAgentWorkingBadge),
                TaskElapsedText.label(since: agent.since, now: context.date, l10n: l10n),
              ].joined(separator: " ")
              : "\(agent.name) \(l10n.string(.taskPaletteAgentWaitingBadge))")
        }
      }
      .foregroundStyle(Color.theme.accentBright)
    }
  }

  private func linkedActions(
    _ row: TaskPaletteGitHubItemRow, _ task: TaskPaletteGitHubItemRow.LinkedTask
  )
    -> some View
  {
    let number = model.store.tasks.first { $0.id == task.id }?.links.first.map {
      GitHubItemText.label($0.item, primary: row.id)
    }
    return VStack(alignment: .leading, spacing: Theme.Space.beat) {
      wideButton(
        "↵", l10n.format(.taskPaletteOpenTask, number ?? task.label), primary: true
      ) { model.showTask(task.id) }
      wideButton("⌘L", l10n.string(.taskPaletteRelink)) { model.linkSelectedGitHubItem() }
      Button {
        model.unlinkSelectedGitHubItem()
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text("⌘⌫")
          Text(l10n.string(.taskPaletteUnlinkTask))
        }
        .font(Font.theme.taskText)
        .foregroundStyle(Color.theme.danger)
        .padding(.horizontal, Theme.Space.beat)
        .frame(height: 30)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
  }

  private func actionButton(
    _ key: String, _ title: L10nKey, primary: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Theme.Space.step) {
        Text(key).foregroundStyle(primary ? Color.theme.accentBright : Color.theme.textMuted)
        Text(l10n.string(title)).foregroundStyle(Color.theme.textPrimary)
      }
      .font(Font.theme.taskText)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.beat)
      .frame(height: 34)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .fill(primary ? Color.theme.tintAccent : Color.theme.surfaceInk.opacity(0.06))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
  }

  private func wideButton(
    _ key: String, _ title: String, primary: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Theme.Space.step) {
        Text(key).foregroundStyle(primary ? Color.theme.accentBright : Color.theme.textMuted)
        Text(title).foregroundStyle(Color.theme.textPrimary)
        Spacer(minLength: 0)
      }
      .font(Font.theme.taskText)
      .lineLimit(1)
      .padding(.horizontal, Theme.Space.beat)
      .frame(height: 34)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .fill(primary ? Color.theme.tintAccent : Color.theme.surfaceInk.opacity(0.06))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
  }

  private static func priorityKey(_ priority: TaskItem.Priority) -> L10nKey {
    switch priority {
    case .high: .taskPalettePriorityHigh
    case .medium: .taskPalettePriorityMedium
    case .low: .taskPalettePriorityLow
    }
  }

  private static func statusKey(_ status: TaskItem.Status) -> L10nKey {
    switch status {
    case .todo: .taskPaletteSectionTodo
    case .inProgress: .taskPaletteSectionInProgress
    case .done: .taskPaletteSectionDone
    }
  }
}
