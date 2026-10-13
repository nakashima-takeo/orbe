import AppKit

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
  /// Home の永続 ID（受信の提案をタスクにすると、ここに付く）。
  let home: UUID?

  /// 解決できない参照（削除された workspace）は nil＝「なし」。
  func entry(_ id: UUID?) -> Entry? {
    guard let id else { return nil }
    return all.first { $0.id == id }
  }
}

/// 選べる行の同一性。選択はこれで持ち、位置は付け直しのときだけ使う。
enum TaskPaletteRowID: Hashable {
  /// 入力欄に打った文の行き先（入力欄の中のヒントが描く。一覧の行は持たない）。選ばれている間の ↵ は
  /// タスクに足し、⌘↵ は agent に任せる。
  case add
  case task(Int)
}

/// 表の 1 行に出す値（タスクから純関数で決まる）。
struct TaskPaletteTaskRow: Equatable {
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

  /// 暦日の値（期限・作成日）。曜日名は言語に依るので表示側が引く。
  struct Day: Equatable {
    let date: TaskItem.DueDate
    let today: TaskItem.DueDate
  }

  let id: Int
  let title: String
  let state: TaskItem.DisplayState
  let priority: TaskItem.Priority
  let due: Day?
  let created: Day
  let waiting: Waiting?
  let resolved: Resolved?
  /// workspace の名前（なしなら nil）。
  let workspace: String?
  let link: GitHubItemText.Mark?
  let pullRequest: GitHubItemText.PullRequestBadge?
  /// 主が自分以外の作成した PR（「レビュー」）。
  let needsReview: Bool
  let agent: WorktreeAgentActivity.Agent?
}

/// 表の 1 行。
enum TaskPaletteRow: Equatable, Identifiable {
  /// 行の同一性（選べない行を含む）。表の中で一意。
  enum Identity: Hashable {
    case selectable(TaskPaletteRowID)
    case empty
  }

  case task(TaskPaletteTaskRow)
  /// 絞り込みに合うタスクが 1 件も無く、入力も無いときの情報行（選べない）。
  case empty

  var id: Identity {
    switch self {
    case .task(let row): .selectable(.task(row.id))
    case .empty: .empty
    }
  }

  var selectableID: TaskPaletteRowID? {
    guard case .selectable(let id) = id else { return nil }
    return id
  }
}

/// 表の寸法。行の高さは 1 種類。優先度・workspace の列の幅は見本の比率（44 / 80、間 12）を本番の字の
/// 大きさ（行 12pt・欄 10pt）に合わせて丸めたもの。件名は残りの幅。状態は今の UI 言語の最も長い状態の名前、
/// 期限・作成は最も長い書式から測る。
enum TaskPaletteRowMetrics {
  /// 札の 1 行（GitHub タブ・選ぶ状態の帯）の高さ。⌘⇧S の行（上下 4 ＋ 16pt の 1 行）と同じ。
  static let line: CGFloat = 24
  /// 札の高さ。
  static let badge: CGFloat = 16
  /// 表の行の高さ。
  static let row: CGFloat = 30
  /// 表の見出しの高さ。
  static let header: CGFloat = 24
  /// 表の行と見出しの左右の内側の余白。
  static let rowInset: CGFloat = Theme.Space.step
  /// 表の列の間。
  static let columnGap: CGFloat = Theme.Space.step
  /// 状態の列。札に左右の余白を足した幅。
  static func stateColumn(_ language: Language) -> CGFloat {
    stateChip(language).width + Theme.Space.tick
  }
  static let priorityColumn: CGFloat = 36
  /// 期限の列。最も長い書式（年の付いた「2026/12/31」と、どの UI 言語でも最も幅のある曜日名）が収まる幅。
  static let dueColumn: CGFloat = {
    let weekdays = Language.allCases.flatMap { TaskDueText.weekdays($0) }
    return ceil(weekdays.map { cellWidth("0000/00/00 " + $0) }.max() ?? 0)
  }()
  static let workspaceColumn: CGFloat = 64
  /// 作成の列。最も長い書式（年の付いた「2026/12/31」）が収まる幅。
  static let createdColumn: CGFloat = ceil(cellWidth("0000/00/00"))
  /// 件名のタイトルの最小幅（日本語で 8 文字前後）。これより狭くなるときは、続く札と補足の側を切り詰める。
  static let titleMinWidth: CGFloat = 100
  /// 状態の札（同じ幅）。その UI 言語の状態の名前のうち最も長いものに、左右の内側の余白を足した幅。余白は見本の
  /// 札（字の幅に対して左右にゆったり取る）に合わせる。
  static func stateChip(_ language: Language) -> CGSize {
    let labels = TaskItem.DisplayState.allCases.map { L10n.string($0.labelKey, language) }
    let widest = ceil(labels.map(cellWidth).max() ?? 0)
    return CGSize(width: widest + 2 * Theme.Space.beat, height: 18)
  }
  /// 行の札のうち、人や agent の文字を出す札（起きたこと）の文字の上限幅。
  static let textBadgeMaxWidth: CGFloat = 180
  /// GitHub タブの行の先頭のアイコンの列の幅。
  static let glyphColumn: CGFloat = 12
  /// 一覧の内側の余白（⌘⇧S のリストと同じ）。
  static let listPadding: CGFloat = Theme.Space.note

  /// 表の欄の字（`Theme.Typography.meta`）で書いた幅。
  private static func cellWidth(_ text: String) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: Theme.Typography.meta]).width
  }
}

/// 件数（全タスクで数え、絞り込みと入力には左右されない）。
struct TaskPaletteCounts: Equatable {
  /// 表に出す状態ごとの数（状態の札）。
  let states: [TaskItem.DisplayState: Int]
  /// 未完了の数（タブの「タスク N」）。
  let undone: Int

  init(_ tasks: [TaskItem]) {
    states = Dictionary(grouping: tasks, by: \.displayState).mapValues(\.count)
    undone = tasks.filter { $0.status != .done }.count
  }
}

/// 表の行を、タスク・入力・絞り込み・並び・残すタスクから組む純関数。
enum TaskPaletteRows {
  struct Input {
    let tasks: [TaskItem]
    let query: String
    /// 結び付けるタスクを選ぶ状態か。選ぶ間は入力の行き先を持たない。
    var picking = false
    let filter: TaskPaletteFilter
    let sort: TaskPaletteSort
    /// 絞り込みと入力に合わなくても出すタスク（選んでいるタスク）。
    var kept: Int?
    let workspaces: TaskPaletteWorkspaces
    let today: TaskItem.DueDate
    /// 待ち始めた時刻・作成日時を暦日へ落とすためのタイムゾーン。
    let timeZone: TimeZone
    /// 結び付いた項目の GitHub の値（`GitHubItemCache` の答え）。
    let items: [GitHubItemID: GitHubItemAnswer]
    let viewerLogin: String?
    /// worktree ごとの agent（`WorktreeAgentActivity` の索引）。
    let agents: [String: WorktreeAgentActivity.Agent]
  }

  /// 入力の行き先（`TaskPaletteRowID.add`）が持つタイトル。入力が無い・選ぶ状態なら nil。
  static func addTitle(_ input: Input) -> String? {
    let title = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty || input.picking ? nil : title
  }

  /// 絞り込みと入力（タイトルの部分一致）に合うタスクと残すタスクを、並びのとおりに並べる。
  static func build(_ input: Input) -> [TaskPaletteRow] {
    let title = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let rows = input.tasks.filter {
      $0.id == input.kept
        || input.filter.matches($0, today: input.today, workspaces: input.workspaces)
          && (title.isEmpty || $0.title.localizedStandardContains(title))
    }
    .sorted { input.sort.areInIncreasingOrder($0, $1, workspaces: input.workspaces) }
    .map { TaskPaletteRow.task(taskRow($0, input)) }
    return rows.isEmpty && title.isEmpty ? [.empty] : rows
  }

  private static func taskRow(_ task: TaskItem, _ input: Input) -> TaskPaletteTaskRow {
    TaskPaletteTaskRow(
      id: task.id, title: task.title, state: task.displayState, priority: task.priority,
      due: task.due.map { TaskPaletteTaskRow.Day(date: $0, today: input.today) },
      created: TaskPaletteTaskRow.Day(
        date: TaskItem.DueDate(task.createdAt, timeZone: input.timeZone), today: input.today),
      waiting: task.waiting.map {
        TaskPaletteTaskRow.Waiting(
          reason: $0.reason,
          days: TaskItem.DueDate($0.since, timeZone: input.timeZone).days(to: input.today))
      },
      resolved: task.waitResolution.map {
        TaskPaletteTaskRow.Resolved(headline: $0.headline, at: $0.at)
      },
      workspace: input.workspaces.entry(task.workspace)?.name,
      link: GitHubItemText.mark(task.links),
      pullRequest: GitHubItemText.pullRequestBadge(task.links, input.items),
      needsReview: GitHubItemText.needsReview(
        task.links, input.items, viewerLogin: input.viewerLogin),
      agent: task.agent(in: input.agents).flatMap { $0.isBusy ? $0 : nil })
  }
}
