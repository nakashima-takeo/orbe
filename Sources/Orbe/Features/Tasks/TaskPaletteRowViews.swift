import SwiftUI

/// タスクのタブの左の一覧。上に絞り込みの行、その下に表の見出しと行。行は `TaskPaletteRows` が組んだ値をそのまま
/// 描き、選択は行の同一性で光らせる。
struct TaskPaletteList: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n
  /// 行の内容の幅。スクロールバーが場所を取る設定であふれると一覧の幅より狭くなるので、見出しをこれに揃える。
  @State private var rowWidth: CGFloat?

  var body: some View {
    let rows = model.rows
    VStack(alignment: .leading, spacing: 0) {
      TaskPaletteFilterBar(model: model)
      TaskPaletteTableHeader(model: model)
        .frame(width: rowWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TaskPaletteRowMetrics.listPadding)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row($0) }
          }
          .frame(maxWidth: .infinity)
          .onGeometryChange(for: CGFloat.self, of: \.size.width) { rowWidth = $0 }
          .padding(TaskPaletteRowMetrics.listPadding)
        }
        .scrollIndicators(.automatic)
        .onChange(of: model.scrollTarget) { scroll(proxy, to: model.scrollTarget?.id, rows) }
        .onAppear { scroll(proxy, to: model.selectedID, rows) }
      }
    }
  }

  /// 最小の量だけスクロールする（見えていれば動かない）。入力の行き先は表の行ではないので、表の先頭を見せる。
  private func scroll(_ proxy: ScrollViewProxy, to id: TaskPaletteRowID?, _ rows: [TaskPaletteRow])
  {
    guard let id else { return }
    if id == .add {
      rows.first.map { proxy.scrollTo($0.id, anchor: .top) }
    } else {
      proxy.scrollTo(TaskPaletteRow.Identity.selectable(id))
    }
  }

  @ViewBuilder private func row(_ row: TaskPaletteRow) -> some View {
    switch row {
    case .task(let task):
      TaskPaletteTaskRowView(
        row: task, selected: model.selectedID == .task(task.id), clock: model.clock,
        onTap: { model.tapRow(.task(task.id)) },
        onToggle: { model.toggleDone(task.id) },
        onHoverEnter: { model.hoverSelect(.task(task.id)) })
    case .empty:
      Text(l10n.string(.taskPaletteEmpty))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.leading, TaskPaletteRowMetrics.rowInset)
        .frame(height: TaskPaletteRowMetrics.row)
    }
  }
}

/// 表の列の並び（状態・件名・優先度・期限・workspace・作成）。件名だけ左揃えで幅を取り、ほかは固定幅で中央揃え。
struct TaskPaletteTableColumns<State: View, Title: View, Rest: View>: View {
  @ViewBuilder let state: () -> State
  @ViewBuilder let title: () -> Title
  /// 件名より右の列の中身（優先度・期限・workspace・作成）。
  let rest: (TaskPaletteSort.Column) -> Rest
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: TaskPaletteRowMetrics.columnGap) {
      column(TaskPaletteRowMetrics.stateColumn(l10n.language), state)
      // 件名は残りの幅だけを取り、収まらない中身は切る（ほかの列を押し出さない）。
      title().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
      column(TaskPaletteRowMetrics.priorityColumn) { rest(.priority) }
      column(TaskPaletteRowMetrics.dueColumn) { rest(.due) }
      column(TaskPaletteRowMetrics.workspaceColumn) { rest(.workspace) }
      column(TaskPaletteRowMetrics.createdColumn) { rest(.created) }
    }
    .padding(.horizontal, TaskPaletteRowMetrics.rowInset)
  }

  /// 固定幅の列。値が無い（空の）列も幅を保つ。
  private func column<Content: View>(_ width: CGFloat, _ content: () -> Content) -> some View {
    Color.clear.frame(width: width).overlay { content() }
  }
}

/// 表の見出し。押すとその列で並べ、並べている列は文字を濃くして向きの矢印（既定の向きは ↓、逆は ↑）を添える。
/// 焦点は取らない。
struct TaskPaletteTableHeader: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    TaskPaletteTableColumns(
      state: { label(.state) }, title: { label(.title) }, rest: { label($0) }
    )
    .frame(height: TaskPaletteRowMetrics.header)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
    }
  }

  private func label(_ column: TaskPaletteSort.Column) -> some View {
    let sorted = model.sort.column == column
    return Button {
      model.setSort(column)
    } label: {
      HStack(spacing: Theme.Space.hair) {
        Text(l10n.string(column.labelKey))
        if sorted {
          Image(systemName: model.sort.reversed ? "arrow.up" : "arrow.down")
            .font(.system(size: 8, weight: .semibold))
        }
      }
      .font(Font.theme.meta)
      .foregroundStyle(sorted ? Color.theme.textPrimary : Color.theme.textMuted)
      .lineLimit(1)
      .fixedSize()
      .frame(
        maxWidth: .infinity, maxHeight: .infinity,
        alignment: column == .title ? .leading : .center
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
  }
}

/// GitHub タブの一覧の選べる行の骨格。選択行は accent の淡塗り。先頭の 22 は行頭の余白。
struct TaskPaletteRowFrame<Content: View>: View {
  let selected: Bool
  var height = TaskPaletteRowMetrics.line
  let onTap: () -> Void
  let onHoverEnter: () -> Void
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 0, content: content)
      .padding(.leading, 22)
      .padding(.trailing, Theme.Space.step + Theme.Space.hair)
      .frame(height: height)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .fill(selected ? Color.theme.selectionFill : .clear)
      )
      .contentShape(Rectangle())
      .onTapGesture(perform: onTap)
      .onHover { if $0 { onHoverEnter() } }
  }
}

/// 表のタスクの行。状態の札（クリックで完了 ⇄ 未着手）・件名（主の番号・タイトル・「レビュー」・PR の札・補足）・
/// 優先度・期限・workspace・作成。縮むのはタイトルが先。完了か絞り込みに合わない行は中身だけを暗くし、選択の
/// 地は普段の濃さのまま（space で完了にした結果を、選んだまま確かめられるように）。暗くなる・戻るときはフェードする。
struct TaskPaletteTaskRowView: View {
  let row: TaskPaletteTaskRow
  let selected: Bool
  /// 経過を数える今（`TaskPaletteModel.clock`）。
  let clock: (Date) -> Date
  let onTap: () -> Void
  let onToggle: () -> Void
  let onHoverEnter: () -> Void
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let dimmed = row.state == .done || !row.matches
    TaskPaletteTableColumns(
      state: {
        TaskStateChip(state: row.state)
          .frame(maxHeight: .infinity)
          .contentShape(Rectangle())
          .onTapGesture(perform: onToggle)
      },
      title: { subject },
      rest: { cell($0) }
    )
    .animation(fade) { $0.opacity(dimmed ? Theme.Opacity.dormant : 1) }
    .frame(height: TaskPaletteRowMetrics.row)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(selected ? Color.theme.selectionFill : .clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    .onHover { if $0 { onHoverEnter() } }
  }

  private var fade: Animation? {
    guard !reduceMotion else { return nil }
    let (p1, p2) = Theme.Motion.easing
    return .timingCurve(p1.x, p1.y, p2.x, p2.y, duration: Theme.Motion.slow)
  }

  private var subject: some View {
    TaskSubjectLayout(
      spacing: Theme.Space.note, titleMinWidth: TaskPaletteRowMetrics.titleMinWidth
    ) {
      Text(row.link.map { "#\($0.number)" } ?? "")
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize()
      TruncatingSlot(row.title) {
        fontResolver.text($0, base: Theme.Typography.workspaceName)
          .font(Font.theme.workspaceName)
          .foregroundStyle(
            row.priority == .low ? Color.theme.textSecondary : Color.theme.textPrimary)
      }
      if row.needsReview {
        Text(l10n.string(.taskPaletteReview))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .fixedSize()
          .subjectBadge(dropOrder: 0)
      }
      if let pullRequest = row.pullRequest {
        TaskPullRequestBadge(badge: pullRequest).subjectBadge(dropOrder: 1)
      }
      // 補足（待ちは「理由 · N日」で末尾を省略、解けた待ちは起きたことの札、agent は「◌ claude 12分」）。
      if let waiting = row.waiting {
        TruncatingSlot("\(waiting.reason) · \(days(waiting.days))") {
          Text($0).font(Font.theme.meta).foregroundStyle(Color.theme.textMuted)
        }
      } else if let resolved = row.resolved {
        TaskResolvedBadge(resolved: resolved, clock: clock).subjectBadge(dropOrder: 2)
      }
      if let agent = row.agent {
        TaskAgentBadge(agent: agent).subjectBadge(dropOrder: 3)
      }
    }
  }

  @ViewBuilder private func cell(_ column: TaskPaletteSort.Column) -> some View {
    switch column {
    case .priority:
      text(l10n.string(row.priority.labelKey), priorityColor)
    case .due:
      if let due = row.due {
        text(
          TaskDueText.label(
            due.date, today: due.today, weekdays: TaskDueText.weekdays(l10n.language)),
          Color.theme.textSecondary)
      }
    case .workspace:
      if let workspace = row.workspace { text(workspace, Color.theme.textSecondary) }
    case .created:
      text(TaskDueText.date(row.created.date, today: row.created.today), Color.theme.textMuted)
    case .state, .title:
      EmptyView()
    }
  }

  /// 高は赤、低は沈める。
  private var priorityColor: Color {
    switch row.priority {
    case .high: Color.theme.danger
    case .medium: Color.theme.textSecondary
    case .low: Color.theme.textMuted
    }
  }

  private func text(_ value: String, _ color: Color) -> some View {
    fontResolver.text(value, base: Theme.Typography.meta)
      .font(Font.theme.meta)
      .foregroundStyle(color)
      .lineLimit(1)
      .truncationMode(.tail)
  }

  private func days(_ count: Int) -> String {
    count == 0 ? l10n.string(.taskPaletteToday) : l10n.format(.taskPaletteDays, count)
  }
}

/// 表に出す状態の札（同じ幅。未着手と完了は中立、進行中と待ちは状態の色）。
struct TaskStateChip: View {
  let state: TaskItem.DisplayState
  @Environment(\.localization) private var l10n

  var body: some View {
    let size = TaskPaletteRowMetrics.stateChip(l10n.language)
    Text(l10n.string(state.labelKey))
      .font(Font.theme.meta)
      .foregroundStyle(foreground)
      .lineLimit(1)
      .frame(width: size.width, height: size.height)
      .background(RoundedRectangle(cornerRadius: Theme.Radius.sm + Theme.Space.hair).fill(fill))
  }

  private var foreground: Color {
    switch state {
    case .todo: Color.theme.textSecondary
    case .inProgress: Color.theme.stateWorking
    case .waiting: Color.theme.stateWaiting
    case .done: Color.theme.textMuted
    }
  }

  private var fill: Color {
    switch state {
    case .todo, .done: Color.theme.plainPillFill
    case .inProgress: Color.theme.tintWorking
    case .waiting: Color.theme.tintWaiting
    }
  }
}

extension TaskPaletteSort.Column {
  var labelKey: L10nKey {
    switch self {
    case .state: .taskPaletteColumnState
    case .title: .taskPaletteColumnTitle
    case .priority: .taskPaletteFieldPriority
    case .due: .taskPaletteFieldDue
    case .workspace: .taskPaletteFieldWorkspace
    case .created: .taskPaletteFieldCreated
    }
  }
}
