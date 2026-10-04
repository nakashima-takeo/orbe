import Foundation

/// タスク画面を開いた時点の workspace の写し。開いている間に workspace が改名・削除されても、閉じて
/// 開き直すまでこの値のまま（`Workspace` は観測できないので、描くたびに引くと反映が描き直しのついでに
/// 左右される）。
struct TaskPaletteWorkspaces: Equatable {
  struct Entry: Equatable {
    let id: UUID
    let name: String
  }

  /// 画面を開いた workspace。
  let opened: Entry
  /// 全 workspace（サイドバーの順）。
  let all: [Entry]

  /// 解決できない参照（削除された workspace）は nil＝「なし」。
  func entry(_ id: UUID?) -> Entry? {
    guard let id else { return nil }
    return all.first { $0.id == id }
  }
}

/// 一覧の範囲。
enum TaskPaletteScope: Equatable {
  case all
  /// 開いた workspace のタスクだけ。
  case opened
}

/// 選べる行の同一性。選択はこれで持ち、位置は付け直しのときだけ使う。
enum TaskPaletteRowID: Hashable {
  /// 先頭の「＋『…』を追加」。
  case add
  case task(Int)
  /// 「完了 N ⌄」の見出し（↵ とクリックで開閉）。
  case doneHeader
}

/// タスクの行に出す値（列の要素から純関数で決まる）。
struct TaskPaletteTaskRow: Equatable {
  enum Glyph: Equatable {
    case todo, inProgress, waiting, done
  }

  enum WorkspaceBadge: Equatable {
    /// 開いた workspace（紫の札）。
    case opened(String)
    /// ほかの workspace（灰色の文字）。
    case other(String)
  }

  struct Waiting: Equatable {
    let reason: String
    /// 待ち始めた日から今日までの暦日の差（0 は今日）。
    let days: Int
  }

  /// 期限の札。曜日名は言語に依るので表示側が引く。
  struct Due: Equatable {
    let date: TaskItem.DueDate
    let today: TaskItem.DueDate
  }

  let id: Int
  let title: String
  let glyph: Glyph
  /// 高と低だけ（中は札を出さない）。
  let priority: TaskItem.Priority?
  let due: Due?
  let createdBy: String?
  let waiting: Waiting?
  let workspace: WorkspaceBadge?
  let isDone: Bool
}

/// 一覧の 1 行。
enum TaskPaletteRow: Equatable {
  case add(title: String)
  /// 「進行中 N」「未着手 N」の見出し（選べない）。
  case sectionHeader(TaskItem.Status, count: Int)
  case task(TaskPaletteTaskRow)
  case doneHeader(count: Int, expanded: Bool)
  /// 範囲にタスクが 1 件も無く、入力も無いときの情報行（選べない）。
  case empty

  var selectableID: TaskPaletteRowID? {
    switch self {
    case .add: .add
    case .task(let row): .task(row.id)
    case .doneHeader: .doneHeader
    case .sectionHeader, .empty: nil
    }
  }
}

/// ヘッダーの件数（どれも未完了の数。入力の絞り込みには左右されない）。
struct TaskPaletteCounts: Equatable {
  /// 今の範囲。
  let scoped: Int
  let all: Int
  /// 開いた workspace。
  let opened: Int
}

/// 一覧の行を、タスクの列・入力・範囲・完了の欄の開閉から組む純関数。どの欄でも列の順をそのまま使う。
enum TaskPaletteRows {
  struct Input {
    let tasks: [TaskItem]
    let query: String
    let scope: TaskPaletteScope
    let doneExpanded: Bool
    let workspaces: TaskPaletteWorkspaces
    let today: TaskItem.DueDate
    /// 待ち始めた時刻を暦日へ落とすためのタイムゾーン。
    let timeZone: TimeZone
  }

  static func build(_ input: Input) -> [TaskPaletteRow] {
    let title = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let visible = inScope(input.tasks, input).filter {
      title.isEmpty || $0.title.localizedStandardContains(title)
    }
    var rows: [TaskPaletteRow] = []
    if !title.isEmpty { rows.append(.add(title: title)) }
    for status in [TaskItem.Status.inProgress, .todo] {
      let section = visible.filter { $0.status == status }
      guard !section.isEmpty else { continue }
      rows.append(.sectionHeader(status, count: section.count))
      rows += section.map { .task(taskRow($0, input)) }
    }
    let done = visible.filter { $0.status == .done }
    if !done.isEmpty {
      rows.append(.doneHeader(count: done.count, expanded: input.doneExpanded))
      if input.doneExpanded { rows += done.map { .task(taskRow($0, input)) } }
    }
    if rows.isEmpty { rows.append(.empty) }
    return rows
  }

  static func counts(_ input: Input) -> TaskPaletteCounts {
    let undone = input.tasks.filter { $0.status != .done }
    return TaskPaletteCounts(
      scoped: inScope(undone, input).count, all: undone.count,
      opened: undone.filter { $0.workspace == input.workspaces.opened.id }.count)
  }

  private static func inScope(_ tasks: [TaskItem], _ input: Input) -> [TaskItem] {
    switch input.scope {
    case .all: tasks
    case .opened: tasks.filter { $0.workspace == input.workspaces.opened.id }
    }
  }

  private static func taskRow(_ task: TaskItem, _ input: Input) -> TaskPaletteTaskRow {
    let glyph: TaskPaletteTaskRow.Glyph =
      switch (task.status, task.waiting) {
      case (.done, _): .done
      case (_, .some): .waiting
      case (.inProgress, nil): .inProgress
      case (.todo, nil): .todo
      }
    let workspace: TaskPaletteTaskRow.WorkspaceBadge? = input.workspaces.entry(task.workspace).map {
      $0.id == input.workspaces.opened.id ? .opened($0.name) : .other($0.name)
    }
    return TaskPaletteTaskRow(
      id: task.id, title: task.title, glyph: glyph,
      priority: task.priority == .medium ? nil : task.priority,
      due: task.due.map { TaskPaletteTaskRow.Due(date: $0, today: input.today) },
      createdBy: task.createdBy,
      waiting: task.waiting.map {
        TaskPaletteTaskRow.Waiting(
          reason: $0.reason,
          days: TaskItem.DueDate($0.since, timeZone: input.timeZone).days(to: input.today))
      },
      workspace: workspace, isDone: task.status == .done)
  }
}
