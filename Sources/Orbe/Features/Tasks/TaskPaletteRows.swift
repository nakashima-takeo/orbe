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
  /// Orbe の workspace の永続 ID（受信の提案をタスクにすると、ここに付く）。
  let home: UUID?

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

  /// 解けた待ちの札（「レビューが付いた 2分前」）。
  struct Resolved: Equatable {
    /// 起きたこと（`WaitResolution.headline`）。期限が来たなら nil。
    let headline: String?
    let at: Date
  }

  /// 期限の札。曜日名は言語に依るので表示側が引く。
  struct Due: Equatable {
    let date: TaskItem.DueDate
    let today: TaskItem.DueDate
  }

  let id: Int
  let title: String
  /// 詳細の先頭（改行と連続する空白を 1 つの空白にまとめ、前後の空白を除いたもの）。空なら nil。
  let descriptionLine: String?
  let glyph: Glyph
  /// 高と低だけ（中は札を出さない）。
  let priority: TaskItem.Priority?
  let due: Due?
  let createdBy: String?
  let waiting: Waiting?
  let resolved: Resolved?
  let workspace: WorkspaceBadge?
  let isDone: Bool
  /// 掴んで同じ欄の中で動かせるか（未完了で、タスクを選ぶ状態でない）。
  let reorderable: Bool
  let link: GitHubItemText.Mark?
  let pullRequest: GitHubItemText.PullRequestBadge?
  /// 主が自分以外の作成した PR（「レビュー」）。
  let needsReview: Bool
  let agent: WorktreeAgentActivity.Agent?
}

extension TaskPaletteTaskRow.Glyph {
  /// 完了 → 待ち → 進行中 → 未着手 の順に決まる（待ちはステータスと独立した属性なので、完了以外で優先する）。
  init(_ task: TaskItem) {
    self =
      switch (task.status, task.waiting) {
      case (.done, _): .done
      case (_, .some): .waiting
      case (.inProgress, nil): .inProgress
      case (.todo, nil): .todo
      }
  }
}

/// 一覧の 1 行。
enum TaskPaletteRow: Equatable, Identifiable {
  /// 行の同一性（選べない行を含む）。一覧の中で一意。
  enum Identity: Hashable {
    case selectable(TaskPaletteRowID)
    case sectionHeader(TaskItem.Status)
    case empty
  }

  case add(title: String)
  /// 「進行中 N」「未着手 N」の見出し（選べない）。
  case sectionHeader(TaskItem.Status, count: Int)
  case task(TaskPaletteTaskRow)
  case doneHeader(count: Int, expanded: Bool)
  /// 範囲にタスクが 1 件も無く、入力も無いときの情報行（選べない）。
  case empty

  var id: Identity {
    switch self {
    case .add: .selectable(.add)
    case .sectionHeader(let status, _): .sectionHeader(status)
    case .task(let row): .selectable(.task(row.id))
    case .doneHeader: .selectable(.doneHeader)
    case .empty: .empty
    }
  }

  var selectableID: TaskPaletteRowID? {
    guard case .selectable(let id) = id else { return nil }
    return id
  }
}

/// 一覧の行の寸法。行の高さは行の値だけで決まり、描画（各行の枠）とドラッグの落ちる位置の計算が同じ値を
/// 読む。選べる 1 行の行は ⌘⇧S の行（上下 5 ＋ 12pt の 1 行）と同じ高さ。
enum TaskPaletteRowMetrics {
  /// 行の上下の余白。
  static let inset: CGFloat = 4
  /// 1 行目（タイトルと札）の高さ。
  static let firstLine: CGFloat = 16
  /// 詳細の先頭の 1 行の高さ。
  static let descriptionLine: CGFloat = 14
  /// 選べる 1 行の行（追加・1 行のタスク・空の行）。
  static let line: CGFloat = inset * 2 + firstLine
  /// 詳細のあるタスクの行。
  static let taskWithDescription: CGFloat = line + descriptionLine
  /// 「進行中 N」「未着手 N」の見出し。
  static let sectionHeader: CGFloat = 26
  /// 「完了 N ⌄」の見出し（上の罫線と余白を含む）。
  static let doneHeader: CGFloat = doneRuleGap + Theme.Stroke.hairline + line
  /// 完了の見出しの上の、罫線までの余白。
  static let doneRuleGap: CGFloat = Theme.Space.note
  /// 行の先頭のアイコンの列の幅。
  static let glyphColumn: CGFloat = 12
  /// 一覧の内側の余白（⌘⇧S のリストと同じ）。
  static let listPadding: CGFloat = Theme.Space.note

  static func height(_ row: TaskPaletteRow) -> CGFloat {
    switch row {
    case .add, .empty: line
    case .sectionHeader: sectionHeader
    case .task(let task): task.descriptionLine == nil ? line : taskWithDescription
    case .doneHeader: doneHeader
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
    /// 結び付けるタスクを選ぶ状態か。選ぶ間は「＋『…』を追加」を出さず、行を並べ替えられない。
    var picking = false
    let scope: TaskPaletteScope
    let doneExpanded: Bool
    let workspaces: TaskPaletteWorkspaces
    let today: TaskItem.DueDate
    /// 待ち始めた時刻を暦日へ落とすためのタイムゾーン。
    let timeZone: TimeZone
    /// 結び付いた項目の GitHub の値（`GitHubItemCache` の答え）。
    let items: [GitHubItemID: GitHubItemAnswer]
    let viewerLogin: String?
    /// worktree ごとの agent（`WorktreeAgentActivity` の索引）。
    let agents: [String: WorktreeAgentActivity.Agent]
  }

  static func build(_ input: Input) -> [TaskPaletteRow] {
    let title = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let visible = inScope(input.tasks, input).filter {
      title.isEmpty || $0.title.localizedStandardContains(title)
    }
    var rows: [TaskPaletteRow] = []
    if !title.isEmpty, !input.picking { rows.append(.add(title: title)) }
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
    let workspace: TaskPaletteTaskRow.WorkspaceBadge? = input.workspaces.entry(task.workspace).map {
      $0.id == input.workspaces.opened.id ? .opened($0.name) : .other($0.name)
    }
    return TaskPaletteTaskRow(
      id: task.id, title: task.title, descriptionLine: descriptionLine(task.description),
      glyph: TaskPaletteTaskRow.Glyph(task),
      priority: task.priority == .medium ? nil : task.priority,
      due: task.due.map { TaskPaletteTaskRow.Due(date: $0, today: input.today) },
      createdBy: task.createdBy,
      waiting: task.waiting.map {
        TaskPaletteTaskRow.Waiting(
          reason: $0.reason,
          days: TaskItem.DueDate($0.since, timeZone: input.timeZone).days(to: input.today))
      },
      resolved: task.waitResolution.map {
        TaskPaletteTaskRow.Resolved(headline: $0.headline, at: $0.at)
      },
      workspace: workspace, isDone: task.status == .done,
      reorderable: !input.picking && task.status != .done,
      link: GitHubItemText.mark(task.links),
      pullRequest: GitHubItemText.pullRequestBadge(task.links, input.items),
      needsReview: GitHubItemText.needsReview(
        task.links, input.items, viewerLogin: input.viewerLogin),
      agent: task.agent(in: input.agents).flatMap { $0.isBusy ? $0 : nil })
  }

  private static func descriptionLine(_ description: String) -> String? {
    let line = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.isEmpty ? nil : line
  }
}
