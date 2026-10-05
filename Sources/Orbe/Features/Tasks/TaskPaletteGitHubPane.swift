import SwiftUI

/// GitHub タブの右の欄。選んでいる項目の見出し・タイトル・関係の文に続けて、結び付いていない行では「タスクに
/// する」ための値（自分を足すか・優先度・期限）とボタン、結び付いている行では結び付いたタスクとボタンを出す。
/// 選ぶ状態の間は、見出しと結び付いたタスクだけを出す（操作は一覧の ↵ だけ）。期限の入力欄は常に mount して
/// おく（新しく mount した入力欄は `@FocusState` を取りこぼす。詳細と同じ規約）。
struct TaskPaletteGitHubPane: View {
  @Bindable var model: TaskPaletteModel
  let focus: FocusState<TaskPaletteFocusTarget?>.Binding
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    if model.gitHubBody == .lists, let row = model.selectedGitHubRow {
      GeometryReader { geometry in
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              Color.clear.frame(height: Theme.Space.bar).id(Self.top)
              heading(row)
              if let task = row.task {
                linkedTask(task.id, row: row)
                  .padding(.top, Theme.Space.beat)
                Spacer(minLength: Theme.Space.beat)
                if model.pick == nil { linkedActions(row, task) }
              } else if model.pick == nil {
                divider.padding(.top, Theme.Space.beat)
                values(row)
                Spacer(minLength: Theme.Space.beat)
                unlinkedActions(row)
              } else {
                Spacer(minLength: 0)
              }
            }
            .padding(.horizontal, Theme.Space.span)
            .padding(.bottom, Theme.Space.bar)
            // 幅は欄の幅に留める（縦のスクロールは中身の幅を縛らないので、留めないと長い行が欄を押し広げ、
            // 区切り線と強調の地がカードの端まで伸びる）。収まる間は欄の高さいっぱいに広げ、ボタン群を下端へ
            // 押す。収まらなければ欄ごとスクロールする。
            .frame(width: geometry.size.width)
            .frame(minHeight: geometry.size.height, alignment: .top)
          }
          .scrollIndicators(.automatic)
          // キーで移った場所を見える位置へ最小の量だけ送る（詳細と同じ規約）。
          .onChange(of: model.area) {
            if case .pane(let stop) = model.area { proxy.scrollTo(stop) }
          }
          // 別の項目を選んだら先頭から見せる（前の項目で送った位置のまま、見出しを隠して出さない）。
          .onChange(of: row.id) { proxy.scrollTo(Self.top, anchor: .top) }
        }
      }
    } else {
      Color.clear
    }
  }

  /// 欄の上の余白（送りの的。余白そのものを的にして、余白ごと先頭へ送り、最初に開いたときと同じ見え方に
  /// 戻す）。
  private static let top = "TaskPaletteGitHubPane.top"

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  /// 「⊙ orbe#221 · 今日」（PR は「· ✓ CI · レビュー待ち」も）・タイトル・関係の文。
  private func heading(_ row: TaskPaletteGitHubItemRow) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Space.note) {
        TaskLinkGlyph(kind: row.item.kind, size: 12)
        meta(row).lineLimit(1)
      }
      .font(Font.theme.meta)
      .padding(.bottom, Theme.Space.note)
      fontResolver.text(row.item.title, base: Theme.Typography.title)
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(2)
        .padding(.bottom, Theme.Space.tick)
      if let relation = TaskGitHubRelationText.text(row.relation, l10n) {
        Text(relation)
          .font(Font.theme.workspaceName)
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
          }, font: Font.theme.workspaceName, height: TaskPaletteFieldMetrics.choiceHeight,
          selectedFill: Color.theme.tintAccent)
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
    HStack(alignment: .top, spacing: Theme.Space.step + Theme.Space.hair) {
      Image(systemName: model.pane.assignsSelf ? "checkmark.square.fill" : "square")
        .font(.system(size: 12))
        .foregroundStyle(
          model.pane.assignsSelf ? Color.theme.accentPrimary : Color.theme.textMuted)
      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        Text(l10n.string(role == .assignee ? .taskPaletteAssignSelf : .taskPaletteReviewSelf))
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textPrimary)
        Text(
          l10n.string(role == .assignee ? .taskPaletteAssignSelfNote : .taskPaletteReviewSelfNote)
        )
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.vertical, Theme.Space.step)
    .padding(.horizontal, Theme.Space.step)
    .background(focusFill(.assign))
    .padding(.horizontal, -Theme.Space.step)
    .contentShape(Rectangle())
    .onTapGesture { model.togglePaneAssign() }
    .id(TaskGitHubPaneStop.assign)
  }

  /// その項目の書き込みの失敗（画面を閉じた後の失敗も、次に選んだときに出る）。
  @ViewBuilder private func failure(_ row: TaskPaletteGitHubItemRow) -> some View {
    if let role = model.writeFailure(row.id) {
      Text(l10n.string(role == .assignee ? .taskPaletteAssignFailed : .taskPaletteReviewFailed))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.danger)
        .lineLimit(2)
        .padding(.bottom, Theme.Space.step)
    }
  }

  private func paneRow<Value: View>(
    _ stop: TaskGitHubPaneStop, label: L10nKey, @ViewBuilder value: () -> Value
  ) -> some View {
    HStack(spacing: 0) {
      Text(l10n.string(label))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .frame(width: TaskPaletteFieldMetrics.labelWidth, alignment: .leading)
      value()
      Spacer(minLength: 0)
    }
    .frame(height: TaskPaletteFieldMetrics.rowHeight)
    .padding(.horizontal, Theme.Space.step)
    .background(focusFill(stop))
    .padding(.horizontal, -Theme.Space.step)
    .contentShape(Rectangle())
    .id(stop)
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
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textPrimary)
        .tint(Color.theme.accentPrimary)
        .focused(focus, equals: .paneDue)
        .onSubmitIgnoringKeyRepeat { model.endEditing(commit: true) }
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
          .font(Font.theme.workspaceName)
          .lineLimit(1)
        } else {
          Text("＋ " + l10n.string(.taskPaletteSetDue))
            .font(Font.theme.workspaceName)
            .foregroundStyle(Color.theme.textSecondary)
            .lineLimit(1)
        }
      }
    }
  }

  @ViewBuilder private func makeTaskButtons(_ row: TaskPaletteGitHubItemRow) -> some View {
    TaskPaneButton(key: "↵", title: l10n.string(.taskPaletteMakeTask), primary: true) {
      model.makeTask(row)
    }
    TaskPaneButton(key: "⌘T", title: l10n.string(.taskPaletteMakeTaskOpen)) {
      model.openWorktreePaletteFromGitHub()
    }
  }

  private func unlinkedActions(_ row: TaskPaletteGitHubItemRow) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.step) {
      Text(l10n.string(.taskPaletteMakeTaskNote))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
      // 横に並びきらない狭い欄では縦に積む（ボタンの文字は縮めない）。
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Theme.Space.step) { makeTaskButtons(row) }
        VStack(alignment: .leading, spacing: Theme.Space.step) { makeTaskButtons(row) }
      }
      divider.padding(.top, Theme.Space.tick)
      Button {
        model.linkSelectedGitHubItem()
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text("⌘L").foregroundStyle(Color.theme.accentBright)
          Text(l10n.string(.taskPaletteLinkExisting)).foregroundStyle(Color.theme.textPrimary)
        }
        .font(Font.theme.workspaceName)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
  }
}

/// 結び付いている行の欄。
extension TaskPaletteGitHubPane {
  // MARK: - 結び付いている行

  /// 「🔗 結び付いているタスク / ◐ #212 タスク機能の設計 / 進行中 · claude 作業中 12分」。
  @ViewBuilder private func linkedTask(_ id: Int, row: TaskPaletteGitHubItemRow) -> some View {
    if let task = model.store.tasks.first(where: { $0.id == id }) {
      VStack(alignment: .leading, spacing: Theme.Space.tick) {
        HStack(spacing: Theme.Space.note) {
          Image(systemName: "link").font(.system(size: 9, weight: .semibold))
          Text(l10n.string(.taskPaletteLinkedTask))
        }
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        HStack(spacing: Theme.Space.step) {
          TaskStatusGlyph(
            glyph: TaskPaletteTaskRow.Glyph(task), size: TaskPaletteRowMetrics.glyphColumn)
          fontResolver.text(row.task?.label ?? task.title, base: Theme.Typography.workspaceName)
            .font(Font.theme.workspaceName)
            .foregroundStyle(Color.theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        linkedTaskState(task)
          .font(Font.theme.meta)
          .lineLimit(1)
          .padding(.leading, TaskPaletteRowMetrics.glyphColumn + Theme.Space.step)
      }
      .padding(Theme.Space.step + Theme.Space.hair)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.md)
          .fill(Color.theme.surfaceInk.opacity(0.04)))
      failure(row).padding(.top, Theme.Space.step)
    }
  }

  /// 「進行中 · claude 作業中 12分」（agent の札は `WorktreeAgentActivity` の索引。作業中・入力待ちだけ）。
  private func linkedTaskState(_ task: TaskItem) -> some View {
    let status = l10n.string(Self.statusKey(task.status))
    let agent = model.agent(of: task).flatMap { $0.isBusy ? $0 : nil }
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
    return VStack(alignment: .leading, spacing: Theme.Space.step) {
      TaskPaneButton(
        key: "↵", title: l10n.format(.taskPaletteOpenTask, number ?? task.label), primary: true,
        wide: true
      ) { model.showTask(task.id) }
      TaskPaneButton(key: "⌘L", title: l10n.string(.taskPaletteRelink), wide: true) {
        model.linkSelectedGitHubItem()
      }
      Button {
        model.unlinkSelectedGitHubItem()
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text("⌘⌫")
          Text(l10n.string(.taskPaletteUnlinkTask))
        }
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.danger)
        .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
        .frame(height: TaskPaletteFieldMetrics.buttonHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
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
