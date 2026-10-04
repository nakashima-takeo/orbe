import Foundation

/// GitHub タブの選べる行の同一性。
enum TaskPaletteGitHubRowID: Hashable {
  case item(GitHubItemID)
  /// 区分の「↓ さらに N 件」。
  case more(GitHubItemKind)
}

/// GitHub タブの絞り込みの札（⇥ で巡回する順）。
enum TaskGitHubFilter: CaseIterable, Equatable {
  case all, assigned, authored, reviewRequested

  /// 次の札（末尾の次は先頭）。
  var next: TaskGitHubFilter {
    let all = Self.allCases
    return all[(all.firstIndex(of: self)! + 1) % all.count]
  }
}

/// 行に添える、自分との関係の文。
enum TaskGitHubRelation: Equatable {
  /// 個人宛のレビュー依頼が自分。
  case reviewRequestedYou
  /// チーム宛だけで自分にレビューが頼まれている（先頭のチームの `org/slug`。無ければ nil）。
  case reviewRequestedTeam(String?)
  case authoredByYou
  /// 作成者（消えたアカウントなら nil）。
  case author(String?)
  case assignedYou
  case unassigned
  /// 先頭の担当者。
  case assignee(String)
}

/// GitHub タブの項目の行に出す値（一覧の項目とタスクの列から純関数で決まる）。
struct TaskPaletteGitHubItemRow: Equatable {
  /// 結び付いたタスク。
  struct LinkedTask: Equatable {
    let id: Int
    /// 「#212 タスク機能の設計」（主の番号は、行のリポジトリと違えば `<リポジトリ名>#212`）。
    let label: String
  }

  let id: GitHubItemID
  let item: GitHubOpenItem
  let relation: TaskGitHubRelation
  let task: LinkedTask?
}

/// GitHub タブの一覧の 1 行。
enum TaskPaletteGitHubRow: Equatable, Identifiable {
  /// 行の同一性（選べない行を含む）。一覧の中で一意。
  enum Identity: Hashable {
    case selectable(TaskPaletteGitHubRowID)
    case header(GitHubItemKind)
    case empty
  }

  /// 「ISSUES · ORBE 24」の見出し（選べない）。件数は絞り込みと入力を当てた後の数。
  case header(GitHubItemKind, count: Int)
  case item(TaskPaletteGitHubItemRow)
  case more(GitHubItemKind, count: Int)
  /// 絞り込みと入力に当たる項目が 1 件も無いときの情報行（選べない）。
  case empty

  var id: Identity {
    switch self {
    case .header(let kind, _): .header(kind)
    case .item(let row): .selectable(.item(row.id))
    case .more(let kind, _): .selectable(.more(kind))
    case .empty: .empty
    }
  }

  var selectableID: TaskPaletteGitHubRowID? {
    guard case .selectable(let id) = id else { return nil }
    return id
  }
}

/// 絞り込みの札の件数（一覧の全件で数え、入力には左右されない）。自分の login やレビュー依頼がまだ分からない
/// 札は nil（件数を出さない）。
struct TaskGitHubFilterCounts: Equatable {
  let assigned: Int?
  let authored: Int?
  let reviewRequested: Int?
}

/// GitHub タブの一覧の行を、open 一覧・タスクの列・自分・絞り込み・入力・開いた区分から組む純関数。
enum TaskPaletteGitHubRows {
  struct Input {
    let repo: GitHubRepoName
    /// 作成の新しい順（置き場の並び）。
    let issues: [GitHubOpenItem]
    let pullRequests: [GitHubOpenItem]
    let tasks: [TaskItem]
    let login: String?
    /// 自分（所属チームを含む）にレビューを頼んでいる PR の番号。nil = まだ分からない。
    let reviewRequests: Set<Int>?
    let filter: TaskGitHubFilter
    let query: String
    /// 「さらに」で全部を出した区分。
    let expanded: Set<GitHubItemKind>
  }

  /// 結び付いていない行を、区分を開くまでに出す件数。
  static let collapsedCount = 5

  /// 各区分は、結び付いた行（全部）→ 結び付いていない行（更新の新しい順。開いていなければ先頭
  /// `collapsedCount` 件と「さらに」）。当たる項目の無い区分は見出しごと出さない。
  static func build(_ input: Input) -> [TaskPaletteGitHubRow] {
    let owners = owners(input.tasks)
    var rows: [TaskPaletteGitHubRow] = []
    for kind in [GitHubItemKind.issue, .pr] {
      let items = (kind == .issue ? input.issues : input.pullRequests)
        .filter { matches($0, input) }
        .enumerated().sorted {
          ($0.element.updatedAt, -$0.offset) > ($1.element.updatedAt, -$1.offset)
        }
        .compactMap { itemRow($0.element, owners, input) }
      guard !items.isEmpty else { continue }
      rows.append(.header(kind, count: items.count))
      let linked = items.filter { $0.task != nil }
      let unlinked = items.filter { $0.task == nil }
      rows += linked.map(TaskPaletteGitHubRow.item)
      if input.expanded.contains(kind) || unlinked.count <= collapsedCount {
        rows += unlinked.map(TaskPaletteGitHubRow.item)
      } else {
        rows += unlinked.prefix(collapsedCount).map(TaskPaletteGitHubRow.item)
        rows.append(.more(kind, count: unlinked.count - collapsedCount))
      }
    }
    if rows.isEmpty { rows.append(.empty) }
    return rows
  }

  static func counts(_ input: Input) -> TaskGitHubFilterCounts {
    let all = input.issues + input.pullRequests
    let count = { (filter: TaskGitHubFilter) in all.filter { passes($0, filter, input) }.count }
    return TaskGitHubFilterCounts(
      assigned: input.login == nil ? nil : count(.assigned),
      authored: input.login == nil ? nil : count(.authored),
      reviewRequested: input.reviewRequests == nil ? nil : count(.reviewRequested))
  }

  /// 自分との関係。PR はレビュー依頼（個人宛 → チーム宛だけ）→ 作成者、Issue は担当で決める。
  static func relation(
    _ item: GitHubOpenItem, login: String?, reviewRequests: Set<Int>?
  ) -> TaskGitHubRelation {
    if let pullRequest = item.pullRequest {
      if pullRequest.reviewers.contains(where: { isSame($0, login) }) { return .reviewRequestedYou }
      if reviewRequests?.contains(item.number) == true {
        return .reviewRequestedTeam(pullRequest.teams.first)
      }
      return isSame(item.author, login) ? .authoredByYou : .author(item.author)
    }
    if item.assignees.contains(where: { isSame($0, login) }) { return .assignedYou }
    return item.assignees.first.map(TaskGitHubRelation.assignee) ?? .unassigned
  }

  /// 「タスクにする」で自分を足す役割。チーム宛だけで頼まれている PR はレビュアー、それ以外は担当者。自分が
  /// 分からない・自分が作成者・既に担当・個人宛にレビュー依頼済みなら nil（足すものが無い）。
  static func selfRole(
    _ item: GitHubOpenItem, login: String?, reviewRequests: Set<Int>?
  ) -> GitHubSelfRole? {
    guard login != nil, !isSame(item.author, login),
      !item.assignees.contains(where: { isSame($0, login) })
    else { return nil }
    switch relation(item, login: login, reviewRequests: reviewRequests) {
    case .reviewRequestedYou: return nil
    case .reviewRequestedTeam: return .reviewer
    default: return .assignee
    }
  }

  /// 項目 → それを持つタスク（1 項目 1 タスクの不変条件で高々 1 つ）。
  private static func owners(_ tasks: [TaskItem]) -> [GitHubItemID: TaskItem] {
    var owners: [GitHubItemID: TaskItem] = [:]
    for task in tasks {
      for link in task.links { owners[link.item] = task }
    }
    return owners
  }

  private static func itemRow(
    _ item: GitHubOpenItem, _ owners: [GitHubItemID: TaskItem], _ input: Input
  ) -> TaskPaletteGitHubItemRow? {
    guard let id = GitHubItemID(repo: input.repo.value, number: item.number) else { return nil }
    let task = owners[id].map { task in
      let primary = task.links.first.map { GitHubItemText.label($0.item, primary: id) + " " } ?? ""
      return TaskPaletteGitHubItemRow.LinkedTask(id: task.id, label: primary + task.title)
    }
    return TaskPaletteGitHubItemRow(
      id: id, item: item,
      relation: relation(item, login: input.login, reviewRequests: input.reviewRequests),
      task: task)
  }

  /// 絞り込みの札と入力（タイトルの部分一致か、`#` の有無を問わない番号の前方一致）の両方に当たるか。
  private static func matches(_ item: GitHubOpenItem, _ input: Input) -> Bool {
    guard passes(item, input.filter, input) else { return false }
    let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    let digits = query.hasPrefix("#") ? String(query.dropFirst()) : query
    if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
      String(item.number).hasPrefix(digits)
    {
      return true
    }
    return item.title.localizedStandardContains(query)
  }

  private static func passes(_ item: GitHubOpenItem, _ filter: TaskGitHubFilter, _ input: Input)
    -> Bool
  {
    switch filter {
    case .all: true
    case .assigned: item.assignees.contains { isSame($0, input.login) }
    case .authored: isSame(item.author, input.login)
    case .reviewRequested: item.kind == .pr && input.reviewRequests?.contains(item.number) == true
    }
  }

  /// GitHub の login は大小文字を区別しない。どちらかが分からなければ false。
  private static func isSame(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return a.lowercased() == b.lowercased()
  }
}
