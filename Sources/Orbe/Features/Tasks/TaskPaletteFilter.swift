import Foundation

/// 期限の区切り（期限の絞り込みの値）。期限は暦日なので、今日との暦日の差だけで決まる。
enum TaskDueBucket: CaseIterable, Hashable {
  case overdue, today, withinWeek, later, none

  init(_ due: TaskItem.DueDate?, today: TaskItem.DueDate) {
    guard let due else {
      self = .none
      return
    }
    let days = today.days(to: due)
    self = days < 0 ? .overdue : days == 0 ? .today : days <= 7 ? .withinWeek : .later
  }
}

/// 値を選んで絞り込む種類（札を押して開く面）。
enum TaskPaletteFilterKind: CaseIterable, Hashable {
  case workspace, priority, due
}

/// 一覧の絞り込み。空の種類は全件で、種類どうしは「かつ」、種類の中は「または」。
struct TaskPaletteFilter: Equatable {
  var states: Set<TaskItem.DisplayState> = [.todo, .inProgress, .waiting]
  /// nil は「なし」（解決できない参照も「なし」として当てる）。
  var workspaces: Set<UUID?> = []
  var priorities: Set<TaskItem.Priority> = []
  var dues: Set<TaskDueBucket> = []

  func matches(_ task: TaskItem, today: TaskItem.DueDate, workspaces: TaskPaletteWorkspaces)
    -> Bool
  {
    Self.admits(states, task.displayState)
      && Self.admits(self.workspaces, workspaces.entry(task.workspace)?.id)
      && Self.admits(priorities, task.priority)
      && Self.admits(dues, TaskDueBucket(task.due, today: today))
  }

  /// 打って足すタスクが付く workspace（workspace がちょうど 1 つで、それが「なし」でなければその workspace）。
  func addedWorkspace(in workspaces: TaskPaletteWorkspaces) -> TaskPaletteWorkspaces.Entry? {
    guard self.workspaces.count == 1, let id = self.workspaces.first else { return nil }
    return workspaces.entry(id)
  }

  private static func admits<Value: Hashable>(_ values: Set<Value>, _ value: Value) -> Bool {
    values.isEmpty || values.contains(value)
  }
}

/// 一覧の並び（列と向き）。並びの規則はすべてここが持つ。
struct TaskPaletteSort: Equatable {
  enum Column: CaseIterable, Hashable {
    case state, title, priority, due, workspace, created
  }

  var column: Column = .created
  /// 列の既定の向きの逆か。既定の向きは、作成は新しい順、期限は近い順、優先度は高 → 低、状態は
  /// 進行中 → 待ち → 未着手 → 完了、件名と workspace は昇順。
  var reversed = false

  /// 見出しを押したときの次の並び。同じ列なら反転し、別の列ならその列の既定の向き。
  func tapped(_ column: Column) -> TaskPaletteSort {
    column == self.column
      ? TaskPaletteSort(column: column, reversed: !reversed) : TaskPaletteSort(column: column)
  }

  /// 値の無いもの（期限なし・workspace なし）は向きに関係なく末尾。同じ値どうしは作成の新しい順。
  func areInIncreasingOrder(_ a: TaskItem, _ b: TaskItem, workspaces: TaskPaletteWorkspaces)
    -> Bool
  {
    let order: ComparisonResult
    switch column {
    case .created:
      return reversed ? TaskItem.newerFirst(b, a) : TaskItem.newerFirst(a, b)
    case .state:
      order = directed(Self.compare(Self.stateRank(a.displayState), Self.stateRank(b.displayState)))
    case .title:
      order = directed(a.title.localizedStandardCompare(b.title))
    case .priority:
      order = directed(Self.compare(a.priority.rank, b.priority.rank))
    case .due:
      order = present(a.due, b.due, Self.compare)
    case .workspace:
      order = present(
        workspaces.entry(a.workspace)?.name, workspaces.entry(b.workspace)?.name
      ) { $0.localizedStandardCompare($1) }
    }
    return order == .orderedSame ? TaskItem.newerFirst(a, b) : order == .orderedAscending
  }

  private func directed(_ order: ComparisonResult) -> ComparisonResult {
    guard reversed else { return order }
    switch order {
    case .orderedAscending: return .orderedDescending
    case .orderedDescending: return .orderedAscending
    case .orderedSame: return .orderedSame
    }
  }

  private func present<Value>(
    _ a: Value?, _ b: Value?, _ compare: (Value, Value) -> ComparisonResult
  ) -> ComparisonResult {
    switch (a, b) {
    case (let a?, let b?): directed(compare(a, b))
    case (nil, nil): .orderedSame
    case (nil, _): .orderedDescending
    case (_, nil): .orderedAscending
    }
  }

  private static func compare<Value: Comparable>(_ a: Value, _ b: Value) -> ComparisonResult {
    a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
  }

  private static func stateRank(_ state: TaskItem.DisplayState) -> Int {
    switch state {
    case .inProgress: 0
    case .waiting: 1
    case .todo: 2
    case .done: 3
    }
  }
}
