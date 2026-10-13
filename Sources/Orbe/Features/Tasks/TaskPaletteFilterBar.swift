import SwiftUI

/// タスクのタブの絞り込みの段（「状態」と状態の札 4 つ・区切り・workspace / 優先度 / 期限の札）。札は押して
/// 入れ切りし、値を選ぶ札は押すとカードの中に面を開く（面はカードが重ねる）。焦点は取らない。幅に収まらなければ
/// 折り返す（札の表記は入れた値で伸びる）。
struct TaskPaletteFilterBar: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    let counts = model.counts.states
    TaskPaletteWrapLayout(spacing: Theme.Space.step, lineSpacing: Theme.Space.note) {
      Text(l10n.string(.taskPaletteColumnState))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize()
      ForEach(TaskItem.DisplayState.allCases, id: \.self) { state in
        TaskPaletteFilterChip(
          title: l10n.string(state.labelKey), count: counts[state] ?? 0,
          on: model.filter.states.contains(state), action: { model.toggleState(state) })
      }
      Rectangle().fill(Color.theme.surface1).frame(width: Theme.Stroke.hairline, height: 14)
        .padding(.horizontal, Theme.Space.tick)
      ForEach(TaskPaletteFilterKind.allCases, id: \.self) { kind in
        menuChip(kind)
      }
    }
    .padding(.horizontal, TaskPaletteRowMetrics.rowInset)
    .padding(.top, Theme.Space.step)
    .padding(.bottom, Theme.Space.step + Theme.Space.hair)
  }

  /// 何も入っていなければ「workspace」、1 つなら「workspace: orbe」、複数なら「workspace: 2」。
  private func menuChip(_ kind: TaskPaletteFilterKind) -> some View {
    let values = TaskPaletteFilterMenu.values(kind, model, l10n).filter(\.on).map(\.title)
    let title = l10n.string(kind.labelKey)
    return TaskPaletteFilterChip(
      title: values.isEmpty
        ? title : "\(title): \(values.count == 1 ? values[0] : String(values.count))",
      count: nil, on: !values.isEmpty, chevron: true, action: { model.toggleFilterMenu(kind) }
    )
    .anchorPreference(key: TaskPaletteFilterMenuAnchor.self, value: .bounds) { [kind: $0] }
  }
}

/// 子を理想の大きさで左から並べ、提案された幅を超える子は次の行へ送る。行の中は縦の中央で揃える。
struct TaskPaletteWrapLayout: Layout {
  let spacing: CGFloat
  let lineSpacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let lines = self.lines(subviews, width: proposal.width ?? .infinity)
    let width = lines.map(\.width).max() ?? 0
    let height =
      lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for line in lines(subviews, width: bounds.width) {
      var x = bounds.minX
      for (index, size) in line.items {
        subviews[index].place(
          at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .init(size))
        x += size.width + spacing
      }
      y += line.height + lineSpacing
    }
  }

  private struct Line {
    var items: [(Int, CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func lines(_ subviews: Subviews, width: CGFloat) -> [Line] {
    var lines: [Line] = []
    var line = Line()
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let added = line.items.isEmpty ? size.width : line.width + spacing + size.width
      if !line.items.isEmpty, added > width {
        lines.append(line)
        line = Line()
      }
      line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
      line.height = max(line.height, size.height)
      line.items.append((index, size))
    }
    if !line.items.isEmpty { lines.append(line) }
    return lines
  }
}

/// 絞り込みの札（入っている札は accent の地と枠）。タスクのタブの状態・値を選ぶ札と、GitHub タブの関係の札が使う。
struct TaskPaletteFilterChip: View {
  let title: String
  let count: Int?
  let on: Bool
  var chevron = false
  let action: () -> Void

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm + Theme.Space.hair)
    Button(action: action) {
      HStack(spacing: Theme.Space.note) {
        Text(title).foregroundStyle(on ? Color.theme.textPrimary : Color.theme.textSecondary)
        if let count {
          Text("\(count)").foregroundStyle(on ? Color.theme.accentBright : Color.theme.textMuted)
        }
        if chevron {
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(on ? Color.theme.textPrimary : Color.theme.textSecondary)
        }
      }
      .font(Font.theme.chrome)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .frame(height: Self.height)
      .background(shape.fill(on ? Color.theme.tintAccent : .clear))
      .overlay(
        shape.strokeBorder(
          on ? Color.theme.accentPrimary.opacity(0.6) : Color.theme.surface2,
          lineWidth: Theme.Stroke.hairline)
      )
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .focusable(false)
  }

  static let height: CGFloat = 22
}

/// 値を選ぶ札の位置（カードが面をその直下に重ねる）。
struct TaskPaletteFilterMenuAnchor: PreferenceKey {
  static let defaultValue: [TaskPaletteFilterKind: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [TaskPaletteFilterKind: Anchor<CGRect>],
    nextValue: () -> [TaskPaletteFilterKind: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { $1 }
  }
}

/// 絞り込みの面（値ごとに 1 行、チェックの印と名前）。行のクリックは値を入れ切りし、面は開いたまま。焦点は取らない。
struct TaskPaletteFilterMenu: View {
  struct Value: Identifiable {
    let id: Int
    let title: String
    let on: Bool
    let toggle: () -> Void
  }

  @Bindable var model: TaskPaletteModel
  let kind: TaskPaletteFilterKind
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Self.values(kind, model, l10n)) { value in
        Button(action: value.toggle) {
          HStack(spacing: Theme.Space.step) {
            Image(systemName: "checkmark")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color.theme.accentBright)
              .opacity(value.on ? 1 : 0)
            Text(value.title)
              .font(Font.theme.chrome)
              .foregroundStyle(value.on ? Color.theme.textPrimary : Color.theme.textSecondary)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, Theme.Space.step)
          .frame(height: TaskPaletteRowMetrics.line)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
      }
    }
    .padding(Theme.Space.tick)
    .frame(minWidth: 160, alignment: .leading)
    .fixedSize()
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.theme.bgBase)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .strokeBorder(Color.theme.surface2, lineWidth: Theme.Stroke.hairline))
  }

  /// 面の行の並び（workspace は「なし」とサイドバーの順、優先度は高・中・低、期限は区切りの順）。
  static func values(
    _ kind: TaskPaletteFilterKind, _ model: TaskPaletteModel, _ l10n: LocalizationStore
  ) -> [Value] {
    let filter = model.filter
    switch kind {
    case .workspace:
      let options: [(UUID?, String)] =
        [(nil, l10n.string(.taskPaletteNoWorkspace))]
        + model.workspaces.all.map { ($0.id, $0.name) }
      return options.enumerated().map { index, option in
        Value(
          id: index, title: option.1, on: filter.workspaces.contains(option.0),
          toggle: { model.toggleWorkspaceFilter(option.0) })
      }
    case .priority:
      return TaskItem.Priority.allCases.enumerated().map { index, priority in
        Value(
          id: index, title: l10n.string(priority.labelKey),
          on: filter.priorities.contains(priority),
          toggle: { model.togglePriorityFilter(priority) })
      }
    case .due:
      return TaskDueBucket.allCases.enumerated().map { index, bucket in
        Value(
          id: index, title: l10n.string(bucket.labelKey), on: filter.dues.contains(bucket),
          toggle: { model.toggleDueFilter(bucket) })
      }
    }
  }
}

extension TaskItem.DisplayState {
  var labelKey: L10nKey {
    switch self {
    case .todo: .taskPaletteStateTodo
    case .inProgress: .taskPaletteStateInProgress
    case .waiting: .taskPaletteStateWaiting
    case .done: .taskPaletteStateDone
    }
  }
}

extension TaskItem.Priority {
  var labelKey: L10nKey {
    switch self {
    case .high: .taskPalettePriorityHigh
    case .medium: .taskPalettePriorityMedium
    case .low: .taskPalettePriorityLow
    }
  }
}

extension TaskPaletteFilterKind {
  var labelKey: L10nKey {
    switch self {
    case .workspace: .taskPaletteFieldWorkspace
    case .priority: .taskPaletteFieldPriority
    case .due: .taskPaletteFieldDue
    }
  }
}

extension TaskDueBucket {
  var labelKey: L10nKey {
    switch self {
    case .overdue: .taskPaletteDueOverdue
    case .today: .taskPaletteDueToday
    case .withinWeek: .taskPaletteDueWithinWeek
    case .later: .taskPaletteDueLater
    case .none: .taskPaletteDueNone
    }
  }
}
