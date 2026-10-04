import SwiftUI

/// 行の先頭のアイコンの列の幅。
private let glyphColumnWidth: CGFloat = 14

/// 一覧の選べる行の寸法。ドラッグの落ちる位置は、欄のタスクの行がこの高さで連続して並ぶことから出す。
enum TaskPaletteRowMetrics {
  static let height: CGFloat = 40
}

/// タスク画面の左の一覧。行は `TaskPaletteRows` が組んだ値をそのまま描き、選択は行の同一性で光らせる。
struct TaskPaletteList: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    let rows = model.rows
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row($0) }
        }
        .coordinateSpace(.named(Self.contentSpace))
        .padding(.top, Theme.Space.tick)
        .padding(.bottom, Theme.Space.beat)
        .padding(.leading, 11)
        .padding(.trailing, 10)
      }
      .scrollIndicators(.automatic)
      .onChange(of: model.scrollTarget) { scroll(proxy, to: model.scrollTarget?.id) }
      .onAppear { scroll(proxy, to: model.selectedID) }
    }
  }

  /// 一覧の内容（スクロールする中身）の座標空間。掴み中にホイールで流した分も移動量に乗る。
  private static let contentSpace = "TaskPaletteList.content"
  /// これだけ動かして初めてドラッグになる（未満はクリック）。
  private static let dragActivation: CGFloat = 6

  /// 最小の量だけ送る（見えていれば動かない）。
  private func scroll(_ proxy: ScrollViewProxy, to id: TaskPaletteRowID?) {
    if let id { proxy.scrollTo(TaskPaletteRow.Identity.selectable(id)) }
  }

  @ViewBuilder private func row(_ row: TaskPaletteRow) -> some View {
    switch row {
    case .add(let title):
      TaskPaletteRowFrame(
        selected: model.selectedID == .add, onTap: { model.tapRow(.add) },
        onHoverEnter: { model.hoverSelect(.add) },
        content: {
          Text("＋")
            .font(Font.theme.chrome)
            .foregroundStyle(Color.theme.accentPrimary)
            .frame(width: glyphColumnWidth)
          TruncatingSlot(l10n.format(.taskPaletteAdd, title), leading: Theme.Space.beat) {
            Text($0).font(Font.theme.taskText).foregroundStyle(Color.theme.textPrimary)
          }
          Spacer(minLength: 0)
        })
    case .sectionHeader(let status, let count):
      sectionLabel(
        status == .inProgress ? .taskPaletteSectionInProgress : .taskPaletteSectionTodo, count)
    case .task(let task):
      taskRow(task)
    case .doneHeader(let count, let expanded):
      VStack(spacing: 0) {
        Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
          .padding(.horizontal, 22)
          .padding(.top, Theme.Space.note)
        TaskPaletteRowFrame(
          selected: model.selectedID == .doneHeader, onTap: { model.tapRow(.doneHeader) },
          onHoverEnter: { model.hoverSelect(.doneHeader) },
          content: {
            TaskStatusGlyph(glyph: .done)
              .frame(width: glyphColumnWidth)
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
            .padding(.leading, Theme.Space.beat)
            Spacer(minLength: 0)
          })
      }
    case .empty:
      Text(l10n.string(.taskPaletteEmpty))
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.leading, 22)
        .frame(height: 40)
    }
  }

  /// タスクの行。未完了の行は掴んで同じ欄の中で動かせ、掴んだ行は指に付いて動き（欄の外へは出ない）、
  /// 落ちる位置に線を出す。ほかの行はずらさない。
  private func taskRow(_ task: TaskPaletteTaskRow) -> some View {
    let grabbed = model.drag.session.flatMap { $0.taskID == task.id ? $0 : nil }
    return TaskPaletteTaskRowView(
      row: task, selected: model.selectedID == .task(task.id),
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
    .gesture(dragGesture(task.id), including: task.isDone ? .subviews : .all)
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

  private func sectionLabel(_ key: L10nKey, _ count: Int) -> some View {
    HStack(spacing: Theme.Space.step) {
      Text(l10n.string(key)).foregroundStyle(Color.theme.textMuted)
      Text("\(count)").foregroundStyle(Color.theme.textMuted.opacity(0.8))
    }
    .font(Font.theme.codeCompact)
    .padding(.leading, 22)
    .padding(.top, Theme.Space.bar)
    .padding(.bottom, Theme.Space.step)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 一覧の選べる行の骨格。選択行は accent の淡塗り。先頭の 22 は並べ替えの取っ手の場所。
struct TaskPaletteRowFrame<Content: View>: View {
  let selected: Bool
  /// 並べ替えの取っ手を出すか（選ばれている未完了のタスクの行）。取っ手は印で、掴む場所は行全体。
  var grip = false
  let onTap: () -> Void
  let onHoverEnter: () -> Void
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 0, content: content)
      .padding(.leading, 22)
      .padding(.trailing, Theme.Space.beat)
      .frame(height: TaskPaletteRowMetrics.height)
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

/// タスクの行。アイコン（クリックで完了 ⇄ 未着手）・タイトル・札（優先度・期限・追加者）、右寄せで
/// 待ちの札と workspace。縮むのはタイトルが先。
struct TaskPaletteTaskRowView: View {
  let row: TaskPaletteTaskRow
  let selected: Bool
  let onTap: () -> Void
  let onToggle: () -> Void
  let onHoverEnter: () -> Void
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    TaskPaletteRowFrame(
      selected: selected, grip: selected && !row.isDone, onTap: onTap, onHoverEnter: onHoverEnter
    ) {
      TaskStatusGlyph(glyph: row.glyph)
        .frame(width: glyphColumnWidth, height: TaskPaletteRowMetrics.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
      TruncatingSlot(row.title, leading: Theme.Space.beat) {
        fontResolver.text($0, base: Theme.Typography.taskText)
          .font(Font.theme.taskText)
          .foregroundStyle(titleColor)
      }
      .layoutPriority(1)
      if let priority = row.priority {
        TaskPaletteBadge(
          text: l10n.string(priority == .high ? .taskPalettePriorityHigh : .taskPalettePriorityLow),
          foreground: priority == .high ? Color.theme.danger : Color.theme.textMuted,
          fill: priority == .high ? Color.theme.tintRed : Color.theme.plainPillFill
        )
        .padding(.leading, Theme.Space.beat)
      }
      if let due = row.due {
        TaskPaletteBadge(
          symbol: "calendar",
          text: TaskDueText.label(
            due.date, today: due.today, weekdays: TaskDueText.weekdays(l10n.language)),
          foreground: Color.theme.textSecondary, fill: Color.theme.plainPillFill
        )
        .padding(.leading, Theme.Space.beat)
      }
      if let createdBy = row.createdBy {
        TruncatingSlot(l10n.format(.taskPaletteAddedBy, createdBy), leading: Theme.Space.beat) {
          Text($0).font(Font.theme.chrome).foregroundStyle(Color.theme.textMuted)
        }
      }
      Spacer(minLength: Theme.Space.beat)
      if let waiting = row.waiting {
        TaskPaletteBadge(
          symbol: "clock",
          text: "\(waiting.reason) \(days(waiting.days))",
          foreground: Color.theme.textSecondary, fill: Color.theme.plainPillFill, capsule: true
        )
        .layoutPriority(2)
      }
      workspace
        .layoutPriority(2)
    }
    .opacity(row.isDone ? Theme.Opacity.dormant : 1)
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
      .padding(.leading, 34)
    case .other(let name):
      Text(name)
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 34)
    case nil:
      EmptyView()
    }
  }

  private func days(_ count: Int) -> String {
    count == 0 ? l10n.string(.taskPaletteToday) : l10n.format(.taskPaletteDays, count)
  }
}

/// 行の札（優先度・期限・待ち・workspace）。
struct TaskPaletteBadge: View {
  var symbol: String?
  let text: String
  let foreground: Color
  let fill: Color
  var capsule = false

  var body: some View {
    HStack(spacing: Theme.Space.tick + 1) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 9, weight: .medium))
      }
      Text(text).lineLimit(1)
    }
    .font(Font.theme.codeCompact)
    .foregroundStyle(foreground)
    .fixedSize()
    .padding(.horizontal, capsule ? Theme.Space.step + Theme.Space.hair : Theme.Space.note)
    .frame(height: 20)
    .background(
      RoundedRectangle(cornerRadius: capsule ? Theme.Radius.pill : Theme.Radius.sm + 1)
        .fill(fill))
  }
}
