import SwiftUI

/// タスク画面の左の一覧。行は `TaskPaletteRows` が組んだ値をそのまま描き、選択は行の同一性で光らせる。
struct TaskPaletteList: View {
  @Bindable var model: TaskPaletteModel
  let focus: FocusState<TaskPaletteFocusTarget?>.Binding
  @Environment(\.localization) private var l10n

  var body: some View {
    let rows = model.rows
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row($0) }
        }
        .coordinateSpace(.named(Self.contentSpace))
        .padding(TaskPaletteRowMetrics.listPadding)
      }
      .scrollIndicators(.automatic)
      .onChange(of: model.scrollTarget) { scroll(proxy, to: model.scrollTarget?.id, rows) }
      // 行の直下に開いた頼む欄が見えるように送る（行だけを見せると、狭い窓で欄が下に切れる）。
      .onChange(of: model.askingTaskID) { revealAsk(proxy) }
      .onAppear {
        scroll(proxy, to: model.selectedID, rows)
        revealAsk(proxy)
      }
    }
  }

  /// 一覧の内容（スクロールする中身）の座標空間。掴み中にホイールで流した分も移動量に乗る。
  private static let contentSpace = "TaskPaletteList.content"
  /// これだけ動かして初めてドラッグになる（未満はクリック）。
  private static let dragActivation: CGFloat = 6

  /// 最小の量だけ送る（見えていれば動かない）。入力の行き先は一覧の行ではないので、一覧の先頭（行き先の次の一致）を
  /// 見せる。
  private func scroll(_ proxy: ScrollViewProxy, to id: TaskPaletteRowID?, _ rows: [TaskPaletteRow])
  {
    guard let id else { return }
    if id == .add {
      rows.first.map { proxy.scrollTo($0.id, anchor: .top) }
    } else {
      proxy.scrollTo(TaskPaletteRow.Identity.selectable(id))
    }
  }

  private func revealAsk(_ proxy: ScrollViewProxy) {
    if let id = model.askingTaskID { proxy.scrollTo(TaskPaletteRow.Identity.ask(id)) }
  }

  @ViewBuilder private func row(_ row: TaskPaletteRow) -> some View {
    switch row {
    case .sectionHeader(let status, let count):
      sectionLabel(
        status == .inProgress ? .taskPaletteSectionInProgress : .taskPaletteSectionTodo, count)
    case .matchHeader:
      sectionLabel(.taskPaletteMatchingTasks, nil)
    case .task(let task):
      taskRow(task)
    case .ask(let ask):
      TaskPaletteAskField(model: model, row: ask, focus: focus)
    case .doneHeader(let count, let expanded):
      VStack(spacing: 0) {
        Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
          .padding(.horizontal, 22)
          .padding(.top, TaskPaletteRowMetrics.doneRuleGap)
        TaskPaletteRowFrame(
          selected: model.selectedID == .doneHeader, onTap: { model.tapRow(.doneHeader) },
          onHoverEnter: { model.hoverSelect(.doneHeader) },
          content: {
            TaskStatusGlyph(glyph: .done, size: TaskPaletteRowMetrics.glyphColumn)
              .frame(width: TaskPaletteRowMetrics.glyphColumn)
            HStack(spacing: Theme.Space.step) {
              Text(l10n.string(.taskPaletteSectionDone))
              Text("\(count)").foregroundStyle(Color.theme.textMuted)
              Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .foregroundStyle(Color.theme.textMuted)
            }
            .font(Font.theme.chrome)
            .foregroundStyle(Color.theme.textSecondary)
            .padding(.leading, Theme.Space.step)
            Spacer(minLength: 0)
          })
      }
      .frame(height: TaskPaletteRowMetrics.doneHeader)
    case .empty:
      Text(l10n.string(.taskPaletteEmpty))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.leading, 22)
        .frame(height: TaskPaletteRowMetrics.line)
    }
  }

  /// タスクの行。未完了の行は掴んで同じ欄の中で動かせ、掴んだ行は指に付いて動き（欄の外へは出ない）、
  /// 落ちる位置に線を出す。ほかの行はずらさない。
  private func taskRow(_ task: TaskPaletteTaskRow) -> some View {
    let grabbed = model.drag.session.flatMap { $0.taskID == task.id ? $0 : nil }
    return TaskPaletteTaskRowView(
      row: task, selected: model.selectedID == .task(task.id), clock: model.clock,
      onTap: { model.tapRow(.task(task.id)) },
      onToggle: { model.toggleDone(task.id) },
      onHoverEnter: { model.hoverSelect(.task(task.id)) }
    )
    .background { if grabbed != nil { floatingGround } }
    .offset(y: grabbed?.offset ?? 0)
    // 線の位置は掴んだ行の元の場所から測る（offset はレイアウトの枠を動かさない）。
    .overlay(alignment: .top) {
      if let y = grabbed?.indicatorY {
        Rectangle()
          .fill(Color.theme.accentBright)
          .frame(height: 2)
          .offset(y: y - 1)
          .allowsHitTesting(false)
      }
    }
    .zIndex(grabbed == nil ? 0 : 1)
    .gesture(dragGesture(task.id), including: task.reorderable ? .all : .subviews)
  }

  /// 掴んだ行の地。浮いた面（ポップアップ）の面色を不透明な bgBase に重ね、下の行を透かさずカードの地に
  /// 揃える。選択の塗りはこの上に行が自分で重ねる。
  private var floatingGround: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.row)
    return shape.fill(Color.theme.bgBase)
      .overlay(shape.fill(Color(nsColor: Theme.Glass.surface(.popup))))
  }

  private func dragGesture(_ id: Int) -> some Gesture {
    DragGesture(minimumDistance: Self.dragActivation, coordinateSpace: .named(Self.contentSpace))
      .onChanged {
        model.dragChanged(id, start: $0.startLocation, translation: $0.translation.height)
      }
      .onEnded { _ in model.dragEnded() }
  }

  /// 見出しの字は ⌘T の欄の見出しと同じ。
  private func sectionLabel(_ key: L10nKey, _ count: Int?) -> some View {
    HStack(spacing: Theme.Space.note) {
      Text(l10n.string(key)).foregroundStyle(Color.theme.textMuted)
      if let count { Text("\(count)").foregroundStyle(Color.theme.textMuted.opacity(0.8)) }
    }
    .font(Font.theme.sectionLabel)
    .tracking(Theme.Typography.trackingLabel)
    .padding(.leading, 22)
    .padding(.bottom, Theme.Space.tick)
    .frame(
      maxWidth: .infinity, minHeight: TaskPaletteRowMetrics.sectionHeader,
      maxHeight: TaskPaletteRowMetrics.sectionHeader, alignment: .bottomLeading)
  }
}

/// 一覧の選べる行の骨格。選択行は accent の淡塗り。先頭の 22 は並べ替えの取っ手の場所。
struct TaskPaletteRowFrame<Content: View>: View {
  let selected: Bool
  /// 並べ替えの取っ手を出すか（選ばれている未完了のタスクの行）。取っ手は印で、掴む場所は行全体。
  var grip = false
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
      .overlay(alignment: .leading) {
        if grip { TaskPaletteGrip().padding(.leading, 8) }
      }
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .fill(selected ? Color.theme.selectionFill : .clear)
      )
      .contentShape(Rectangle())
      .onTapGesture(perform: onTap)
      .onHover { if $0 { onHoverEnter() } }
  }
}

/// 並べ替えの取っ手（2 列 3 段の点）。
private struct TaskPaletteGrip: View {
  private let dot: CGFloat = 3
  private let gap: CGFloat = 2

  var body: some View {
    HStack(spacing: gap) {
      ForEach(0..<2, id: \.self) { _ in
        VStack(spacing: gap) {
          ForEach(0..<3, id: \.self) { _ in Circle().frame(width: dot, height: dot) }
        }
      }
    }
    .foregroundStyle(Color.theme.textMuted)
  }
}

/// タスクの行。アイコン（クリックで完了 ⇄ 未着手）・主の結び付きの印と番号・タイトル・札（「レビュー」・
/// PR・優先度・期限・追加者）、右寄せで agent の札・待ちの札（解けた待ちは起きたことの札）と workspace。縮むのはタイトルが先。詳細があれば
/// タイトルの下に先頭を 1 行出す（書き出しはタイトルにそろえ、右寄せの札は 1 行目に残す）。
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

  var body: some View {
    TaskPaletteRowFrame(
      selected: selected, grip: selected && row.reorderable,
      height: TaskPaletteRowMetrics.height(.task(row)), onTap: onTap, onHoverEnter: onHoverEnter
    ) {
      // アイコンの列は行の高さ全体でクリックを受ける。
      TaskStatusGlyph(glyph: row.glyph, size: TaskPaletteRowMetrics.glyphColumn)
        .frame(width: TaskPaletteRowMetrics.glyphColumn, height: TaskPaletteRowMetrics.firstLine)
        .firstLineSlot()
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
      if let link = row.link {
        HStack(spacing: Theme.Space.tick) {
          TaskLinkGlyph(kind: link.kind, size: 12)
          Text("#\(link.number)")
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
        }
        .fixedSize()
        .frame(height: TaskPaletteRowMetrics.firstLine)
        .padding(.leading, Theme.Space.step)
        .firstLineSlot()
      }
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 0) { firstLine }
          .frame(height: TaskPaletteRowMetrics.firstLine)
        if let line = row.descriptionLine {
          fontResolver.text(line, base: Theme.Typography.meta)
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, Theme.Space.step)
            .frame(height: TaskPaletteRowMetrics.descriptionLine, alignment: .leading)
        }
      }
      .firstLineSlot()
    }
    .opacity(row.isDone ? Theme.Opacity.dormant : 1)
  }

  @ViewBuilder private var firstLine: some View {
    TruncatingSlot(row.title, leading: Theme.Space.step) {
      fontResolver.text($0, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(titleColor)
    }
    .layoutPriority(1)
    if row.justAdded {
      TaskPaletteBadge(
        text: l10n.string(.taskPaletteJustAdded), foreground: Color.theme.accentBright,
        fill: Color.theme.tintAccent
      )
      .padding(.leading, Theme.Space.step)
    }
    if row.needsReview {
      Text(l10n.string(.taskPaletteReview))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize()
        .padding(.leading, Theme.Space.step)
    }
    if let pullRequest = row.pullRequest {
      TaskPullRequestBadge(badge: pullRequest)
        .padding(.leading, Theme.Space.step)
    }
    if let priority = row.priority {
      TaskPaletteBadge(
        text: l10n.string(priority == .high ? .taskPalettePriorityHigh : .taskPalettePriorityLow),
        foreground: priority == .high ? Color.theme.danger : Color.theme.textMuted,
        fill: priority == .high ? Color.theme.tintRed : Color.theme.plainPillFill
      )
      .padding(.leading, Theme.Space.step)
    }
    if let due = row.due {
      TaskPaletteBadge(
        symbol: "calendar",
        text: TaskDueText.label(
          due.date, today: due.today, weekdays: TaskDueText.weekdays(l10n.language)),
        foreground: Color.theme.textSecondary, fill: Color.theme.plainPillFill
      )
      .padding(.leading, Theme.Space.step)
    }
    if let createdBy = row.createdBy {
      TruncatingSlot(l10n.format(.taskPaletteAddedBy, createdBy), leading: Theme.Space.step) {
        Text($0).font(Font.theme.meta).foregroundStyle(Color.theme.textMuted)
      }
    }
    Spacer(minLength: Theme.Space.step)
    if let agent = row.agent {
      TaskAgentBadge(agent: agent)
        .layoutPriority(2)
        .padding(.trailing, row.waiting == nil && row.resolved == nil ? 0 : Theme.Space.note)
    }
    if let waiting = row.waiting {
      TaskPaletteBadge(
        symbol: "clock",
        text: "\(waiting.reason) \(days(waiting.days))",
        foreground: Color.theme.textSecondary, fill: Color.theme.plainPillFill, capsule: true,
        maxWidth: TaskPaletteRowMetrics.textBadgeMaxWidth
      )
      .layoutPriority(2)
    }
    if let resolved = row.resolved {
      TaskResolvedBadge(resolved: resolved, clock: clock)
        .layoutPriority(2)
    }
    workspace
      .layoutPriority(2)
  }

  /// 低い優先度のタスクは一段沈める（見本どおり）。
  private var titleColor: Color {
    row.priority == .low ? Color.theme.textSecondary : Color.theme.textPrimary
  }

  @ViewBuilder private var workspace: some View {
    switch row.workspace {
    case .opened(let name):
      TaskPaletteBadge(
        text: name, foreground: Color.theme.accentBright, fill: Color.theme.tintAccent
      )
      .padding(.leading, Theme.Space.span)
    case .other(let name):
      Text(name)
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, Theme.Space.span)
    case nil:
      EmptyView()
    }
  }

  private func days(_ count: Int) -> String {
    count == 0 ? l10n.string(.taskPaletteToday) : l10n.format(.taskPaletteDays, count)
  }
}

extension View {
  /// タスクの行の 1 つの列を、上の余白の下から 1 行目にそろえて置き、行の高さいっぱいに広げる。
  fileprivate func firstLineSlot() -> some View {
    padding(.top, TaskPaletteRowMetrics.inset).frame(maxHeight: .infinity, alignment: .top)
  }
}
