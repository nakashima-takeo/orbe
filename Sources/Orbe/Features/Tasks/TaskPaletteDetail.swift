import SwiftUI

/// タスク画面の右の詳細。選んでいるのがタスクの行のときだけ、そのタスクを出す。
/// 文字の項目（タイトル・待ち・期限・メモ）の入力欄は常に mount しておき、編集中でない間は値の表示に
/// 見せる——新しく mount した入力欄は `@FocusState` を取りこぼしてキーが届かなくなるため、焦点の宛先は
/// いつも在る形にする（ヘッダーの入力欄と同じ規約）。
struct TaskPaletteDetail: View {
  @Bindable var model: TaskPaletteModel
  let focus: FocusState<TaskPaletteFocusTarget?>.Binding
  @Environment(\.localization) private var l10n

  var body: some View {
    if let task = model.selectedTask {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          titleField(task)
            .padding(.bottom, Theme.Space.bar)
          divider
          fieldRow(.status, label: .taskPaletteFieldStatus) { statusValue(task) }
          divider
          fieldRow(.waiting, label: .taskPaletteFieldWaiting) { waitingValue(task) }
          divider
          fieldRow(.priority, label: .taskPaletteFieldPriority) { priorityValue(task) }
          divider
          fieldRow(.due, label: .taskPaletteFieldDue) { dueValue(task) }
          divider
          fieldRow(.workspace, label: .taskPaletteFieldWorkspace) { workspaceValue(task) }
          divider
          addedRow(task)
          divider
          memoField(task)
            .padding(.top, Theme.Space.bar)
          actions(task)
            .padding(.top, Theme.Space.bar)
        }
        .padding(.horizontal, Theme.Space.phrase)
        .padding(.top, Theme.Space.span)
        .padding(.bottom, Theme.Space.span)
      }
      .scrollIndicators(.automatic)
    } else {
      Color.clear
    }
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  private func isFocused(_ field: TaskDetailField) -> Bool {
    model.area == .detail(field)
  }

  private func isEditing(_ field: TaskDetailField) -> Bool {
    model.draft?.field == field
  }

  /// 項目の 1 行（ラベル＋値）。キーで居る項目は淡く光らせる。行のクリックでその項目へ移る。
  private func fieldRow<Value: View>(
    _ field: TaskDetailField, label: L10nKey, @ViewBuilder value: () -> Value
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
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(isFocused(field) && !isEditing(field) ? Color.theme.selectionFill : .clear)
    )
    .padding(.horizontal, -Theme.Space.step)
    .contentShape(Rectangle())
    .onTapGesture { if !isEditing(field) { model.tapField(field) } }
  }

  private func titleField(_ task: TaskItem) -> some View {
    editableText(.title, font: Font.theme.taskHeading) {
      Text(task.title)
        .font(Font.theme.taskHeading)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.vertical, Theme.Space.tick)
    .padding(.horizontal, Theme.Space.step)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(isFocused(.title) && !isEditing(.title) ? Color.theme.selectionFill : .clear)
    )
    .padding(.horizontal, -Theme.Space.step)
    .contentShape(Rectangle())
    .onTapGesture { if !isEditing(.title) { model.tapField(.title) } }
  }

  /// 1 行の文字の項目。入力欄は常に在り、編集中だけ見えて触れる。編集中でない間は `display` を見せる。
  private func editableText<Display: View>(
    _ field: TaskDetailField, font: Font, @ViewBuilder display: () -> Display
  ) -> some View {
    ZStack(alignment: .leading) {
      TextField("", text: $model.draftText)
        .textFieldStyle(.plain)
        .font(font)
        .foregroundStyle(Color.theme.textPrimary)
        .tint(Color.theme.accentPrimary)
        .focused(focus, equals: .edit(field))
        .onSubmit { model.endEditing(commit: true) }
        .onKeyPress { model.handleEditKey($0, composing: TaskPaletteCard.isComposing) }
        .opacity(isEditing(field) ? 1 : 0)
        .allowsHitTesting(isEditing(field))
      if !isEditing(field) { display() }
    }
  }

  /// 選択式の値（未着手 / 進行中、高 / 中 / 低）。
  private func choices(_ segments: [TaskPaletteSegments.Segment]) -> some View {
    TaskPaletteSegments(
      segments: segments, font: Font.theme.taskText, height: 24,
      selectedFill: Color.theme.tintAccent)
  }

  private func choice(_ key: L10nKey, _ selected: Bool, _ action: @escaping () -> Void)
    -> TaskPaletteSegments.Segment
  {
    TaskPaletteSegments.Segment(
      title: l10n.string(key), count: nil, selected: selected, action: action)
  }

  private func statusValue(_ task: TaskItem) -> some View {
    choices([
      choice(.taskPaletteSectionTodo, task.status == .todo) { model.setStatus(.todo) },
      choice(.taskPaletteSectionInProgress, task.status == .inProgress) {
        model.setStatus(.inProgress)
      },
    ])
  }

  private func priorityValue(_ task: TaskItem) -> some View {
    choices([
      choice(.taskPalettePriorityHigh, task.priority == .high) { model.setPriority(.high) },
      choice(.taskPalettePriorityMedium, task.priority == .medium) { model.setPriority(.medium) },
      choice(.taskPalettePriorityLow, task.priority == .low) { model.setPriority(.low) },
    ])
  }

  /// 待ち。完了のタスクには入れられない（ストアの不変条件）ので、操作できない見た目にする。
  private func waitingValue(_ task: TaskItem) -> some View {
    editableText(.waiting, font: Font.theme.taskText) {
      if let waiting = task.waiting {
        setValue(
          "\(waiting.reason) · \(days(since: waiting.since))", onClear: { model.clearWaiting() })
      } else {
        placeholder(.taskPaletteAddReason)
          .opacity(task.status == .done ? Theme.Opacity.disabled : 1)
      }
    }
  }

  private func dueValue(_ task: TaskItem) -> some View {
    editableText(.due, font: Font.theme.taskText) {
      if let due = task.due {
        setValue(
          TaskDueText.label(
            due, today: model.today, weekdays: TaskDueText.weekdays(l10n.language)),
          onClear: { model.clearDue() })
      } else {
        placeholder(.taskPaletteSetDue)
      }
    }
  }

  /// 空の文字の項目の「＋ …」。
  private func placeholder(_ key: L10nKey) -> some View {
    Text("＋ " + l10n.string(key))
      .font(Font.theme.taskText)
      .foregroundStyle(Color.theme.textSecondary)
      .lineLimit(1)
  }

  /// 入っている値と「解除」。
  private func setValue(_ text: String, onClear: @escaping () -> Void) -> some View {
    HStack(spacing: Theme.Space.step) {
      Text(text)
        .font(Font.theme.taskText)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      Text("·").font(Font.theme.taskText).foregroundStyle(Color.theme.textMuted)
      Button(action: onClear) {
        Text(l10n.string(.taskPaletteClear))
          .font(Font.theme.taskText)
          .foregroundStyle(Color.theme.textMuted)
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
  }

  private func workspaceValue(_ task: TaskItem) -> some View {
    Text(model.workspaces.entry(task.workspace)?.name ?? l10n.string(.taskPaletteNoWorkspace))
      .font(Font.theme.taskText)
      .foregroundStyle(
        task.workspace.flatMap(model.workspaces.entry) == nil
          ? Color.theme.textMuted : Color.theme.textPrimary
      )
      .lineLimit(1)
  }

  private func addedRow(_ task: TaskItem) -> some View {
    let date = TaskDueText.date(
      TaskItem.DueDate(task.createdAt, timeZone: model.timeZone), today: model.today)
    return HStack(spacing: 0) {
      Text(l10n.string(.taskPaletteFieldAdded))
        .font(Font.theme.taskText)
        .foregroundStyle(Color.theme.textMuted)
        .frame(width: 84, alignment: .leading)
      Text(task.createdBy.map { "\(date) · \($0)" } ?? date)
        .font(Font.theme.taskText)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(height: 38)
  }

  /// メモ。複数行で、↵ は改行、⌘↵ で確定。
  private func memoField(_ task: TaskItem) -> some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $model.draftText)
        .font(Font.theme.taskText)
        .foregroundStyle(Color.theme.textPrimary)
        .tint(Color.theme.accentPrimary)
        .scrollContentBackground(.hidden)
        .focused(focus, equals: .edit(.memo))
        .onKeyPress { model.handleEditKey($0, composing: TaskPaletteCard.isComposing) }
        .opacity(isEditing(.memo) ? 1 : 0)
        .allowsHitTesting(isEditing(.memo))
      if !isEditing(.memo) {
        Text(task.memo.isEmpty ? l10n.string(.taskPaletteMemoPlaceholder) : task.memo)
          .font(Font.theme.taskText)
          .foregroundStyle(task.memo.isEmpty ? Color.theme.textMuted : Color.theme.textPrimary)
          .padding(.leading, 5)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .padding(Theme.Space.beat)
    .frame(height: 84, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.md)
        .fill(Color.theme.surfaceInk.opacity(0.04))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.md)
        .strokeBorder(
          isFocused(.memo) || isEditing(.memo) ? Color.theme.accentPrimary.opacity(0.6) : .clear,
          lineWidth: Theme.Stroke.hairline)
    )
    .contentShape(Rectangle())
    .onTapGesture { if !isEditing(.memo) { model.tapField(.memo) } }
  }

  private func actions(_ task: TaskItem) -> some View {
    HStack {
      Button {
        model.toggleDone(task.id)
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text("space").foregroundStyle(Color.theme.textMuted)
          Text(l10n.string(task.status == .done ? .taskPaletteReopen : .taskPaletteMarkDone))
            .foregroundStyle(Color.theme.textPrimary)
        }
        .font(Font.theme.taskText)
        .padding(.horizontal, Theme.Space.beat)
        .frame(height: 30)
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
          Text(l10n.string(.taskPaletteDelete)).font(Font.theme.taskText)
        }
        .foregroundStyle(Color.theme.danger)
        .padding(.horizontal, Theme.Space.beat)
        .frame(height: 30)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
  }

  private func days(since: Date) -> String {
    let count = TaskItem.DueDate(since, timeZone: model.timeZone).days(to: model.today)
    return count == 0 ? l10n.string(.taskPaletteToday) : l10n.format(.taskPaletteDays, count)
  }
}
