import Foundation
import OrbeSessionLog

/// タスク 1 件。一覧（`TaskStore.tasks`）は人と agent が共有する 1 本の列で、この値はその要素。
/// 不変条件（ID の一意・タイトルと待ちの理由が空でない・完了は待ちの席が空・待ちの条件は待っている間だけ・
/// 結び付きの項目と worktree はそれぞれ 1 つのタスクにだけ現れる）は `TaskStore` が保証する。
struct TaskItem: Codable, Equatable, Identifiable {
  /// 永続の短い整数。使い回さない（採番位置は `TasksFile.nextId` が持つ）。
  let id: Int
  var title: String
  var status: Status
  /// 待ちの席。待っているか、解けたか（無しも可）。書くのは `TaskStore` だけ。
  var wait: Wait?
  var priority: Priority
  var due: DueDate?
  /// 付き先の `Workspace.persistentId`。解決できない参照は「なし」と同じに扱う（削除された workspace を
  /// 指していても書き換えない）。
  var workspace: UUID?
  /// 人も agent も読む前提の自由記述（複数行可）。
  var description: String
  let createdAt: Date
  /// 追加した agent の command 名。人が足したタスクは nil。
  let createdBy: String?
  /// 結び付いた GitHub の Issue・PR。先頭が主。空は結び付きなし。
  var links: [TaskLink] = []
  /// このタスクの作業の場所。解決できない値（ディレクトリが消えた）は「なし」と同じに扱う（書き換えない）。
  var worktree: TaskWorktree?
  /// worktree での作業のブランチ。worktree を付けるたびに、そこで checkout していたブランチを記録し
  /// （detached・git の外・読めなければ nil）、無い・既定ブランチの記録は未確定とみなす——未確定の間は
  /// ブランチで絞らない。⌘⇧X を開いたときの PR の自動の結び付けが、未確定の worktree が既定ブランチ以外に
  /// いるのを見たら、そのブランチで確定する。確定した後は、worktree の今のブランチがこれと同じ間だけ、そこを
  /// このタスクの作業とみなす（ブランチを切り替えて使い回す main worktree で、別の作業の PR・agent を
  /// このタスクに付けない）。保つのは `TaskStore`。tasks.json にだけ出し、ワイヤには出さない。
  var worktreeBranch: String?
  /// 結び付きから外れた項目。PR の自動の結び付けはこれを避ける。保つのは `TaskStore` で、tasks.json にだけ
  /// 出し、ワイヤには出さない。
  var unlinked: Set<GitHubItemID> = []

  enum Status: String, Codable, CaseIterable {
    case todo
    case inProgress = "in_progress"
    case done
  }

  enum Priority: String, Codable, CaseIterable {
    case high, medium, low

    /// 高いほど小さい。
    var rank: Int { Self.allCases.firstIndex(of: self)! }
  }

  /// 待ちの段階。両方を同時に持つことは型で表せない。
  enum Wait: Equatable {
    case waiting(Waiting)
    /// 待ちの条件で解けた（起きたことを持つ）。
    case resolved(WaitResolution)
  }

  /// 待ち。ステータスとは独立した属性で、完了にすると外れる。
  struct Waiting: Codable, Equatable {
    var reason: String
    /// 待ち始めた日時。理由だけを変えても動かない。
    var since: Date
    /// 解ける条件。理由だけを変えても変わらない。
    var condition: WaitCondition?
  }

  /// 待っている段階（解けた待ちは含まない）。
  var waiting: Waiting? {
    if case .waiting(let waiting) = wait { return waiting }
    return nil
  }

  /// 解けた待ち（起きたこと）。
  var waitResolution: WaitResolution? {
    if case .resolved(let resolution) = wait { return resolution }
    return nil
  }

  /// 期限。時刻とタイムゾーンを持たない暦日。
  struct DueDate: Equatable, Codable {
    let year: Int
    let month: Int
    let day: Int

    /// `YYYY-MM-DD` で、暦として存在する日付だけを受ける。
    init?(_ text: String) {
      let parts = text.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
        parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
        let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
      else { return nil }
      let calendar = Calendar(identifier: .gregorian)
      guard y >= 1, (1...12).contains(m),
        let firstOfMonth = calendar.date(from: DateComponents(year: y, month: m)),
        calendar.range(of: .day, in: .month, for: firstOfMonth)?.contains(d) == true
      else { return nil }
      year = y
      month = m
      day = d
    }

    var text: String { String(format: "%04d-%02d-%02d", year, month, day) }

    init(from decoder: Decoder) throws {
      let raw = try decoder.singleValueContainer().decode(String.self)
      guard let parsed = DueDate(raw) else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "not a calendar date: \(raw)"))
      }
      self = parsed
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.singleValueContainer()
      try c.encode(text)
    }
  }
}

extension TaskItem {
  private enum CodingKeys: String, CodingKey {
    case id, title, status, waiting, waitResolved, priority, due, workspace, description, createdAt,
      createdBy, links, worktree, worktreeBranch, unlinked
  }

  /// `links`・`worktree`・`worktreeBranch`・`unlinked` は、欠けていれば空として読む。待ちの席は `waiting` か
  /// `waitResolved` のどちらか 1 つ（両方あるものは読めない）。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    status = try c.decode(Status.self, forKey: .status)
    switch (
      try c.decodeIfPresent(Waiting.self, forKey: .waiting),
      try c.decodeIfPresent(WaitResolution.self, forKey: .waitResolved)
    ) {
    case (let waiting?, nil): wait = .waiting(waiting)
    case (nil, let resolution?): wait = .resolved(resolution)
    case (nil, nil): wait = nil
    case (.some, .some):
      throw DecodingError.dataCorruptedError(
        forKey: .waitResolved, in: c, debugDescription: "both waiting and waitResolved")
    }
    priority = try c.decode(Priority.self, forKey: .priority)
    due = try c.decodeIfPresent(DueDate.self, forKey: .due)
    workspace = try c.decodeIfPresent(UUID.self, forKey: .workspace)
    description = try c.decode(String.self, forKey: .description)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
    links = try c.decodeIfPresent([TaskLink].self, forKey: .links) ?? []
    worktree = try c.decodeIfPresent(TaskWorktree.self, forKey: .worktree)
    worktreeBranch = try c.decodeIfPresent(String.self, forKey: .worktreeBranch)
    unlinked = Set(try c.decodeIfPresent([UnlinkedItem].self, forKey: .unlinked)?.map(\.item) ?? [])
  }

  /// `unlinked` は空でも書き、並びは決まった順にする（保存のたびに順が揺れない）。
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(title, forKey: .title)
    try c.encode(status, forKey: .status)
    try c.encodeIfPresent(waiting, forKey: .waiting)
    try c.encodeIfPresent(waitResolution, forKey: .waitResolved)
    try c.encode(priority, forKey: .priority)
    try c.encodeIfPresent(due, forKey: .due)
    try c.encodeIfPresent(workspace, forKey: .workspace)
    try c.encode(description, forKey: .description)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encodeIfPresent(createdBy, forKey: .createdBy)
    try c.encode(links, forKey: .links)
    try c.encodeIfPresent(worktree, forKey: .worktree)
    try c.encodeIfPresent(worktreeBranch, forKey: .worktreeBranch)
    try c.encode(
      unlinked.sorted { ($0.repo.value, $0.number) < ($1.repo.value, $1.number) }.map(
        UnlinkedItem.init), forKey: .unlinked)
  }

  /// 永続とワイヤに載る時刻の精度（ミリ秒）へ丸める。丸めずに持つと、保存して読み戻した値が
  /// メモリ上の値と一致しない。
  static func storedInstant(_ date: Date) -> Date {
    SessionEvent.parseISO8601(SessionEvent.iso8601(date)) ?? date
  }
}

/// 外した項目 1 つの永続の形（`{repo, number}`）。
private struct UnlinkedItem: Codable {
  let item: GitHubItemID

  private enum CodingKeys: String, CodingKey {
    case repo, number
  }

  init(_ item: GitHubItemID) { self.item = item }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let repo = try c.decode(String.self, forKey: .repo)
    let number = try c.decode(Int.self, forKey: .number)
    guard let item = GitHubItemID(repo: repo, number: number) else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath, debugDescription: "not a github item: \(repo)#\(number)"))
    }
    self.item = item
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(item.repo.value, forKey: .repo)
    try c.encode(item.number, forKey: .number)
  }
}

/// タスクと GitHub の Issue・PR の結び付き 1 つ。種別は指定どおりに持ち、GitHub に照合しない。
/// 永続とワイヤの形は `{kind, repo, number}`。
struct TaskLink: Codable, Equatable {
  let item: GitHubItemID
  let kind: GitHubItemKind

  private enum CodingKeys: String, CodingKey {
    case kind, repo, number
  }

  init(item: GitHubItemID, kind: GitHubItemKind) {
    self.item = item
    self.kind = kind
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let repo = try c.decode(String.self, forKey: .repo)
    let number = try c.decode(Int.self, forKey: .number)
    guard let item = GitHubItemID(repo: repo, number: number) else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath, debugDescription: "not a github item: \(repo)#\(number)"))
    }
    self.item = item
    kind = try c.decode(GitHubItemKind.self, forKey: .kind)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind, forKey: .kind)
    try c.encode(item.repo.value, forKey: .repo)
    try c.encode(item.number, forKey: .number)
  }

  /// GitHub のページ。GitHub は名前の大小文字を区別せず、issues と pull の取り違えもリダイレクトするので、
  /// 保存した種別と小文字の名前のままで開ける。
  var url: URL {
    URL(
      string:
        "https://github.com/\(item.repo.value)/\(kind == .issue ? "issues" : "pull")/\(item.number)"
    )!
  }
}

/// 追加の要求。`workspace` と `createdBy` は呼び出し元の文脈から埋める。
struct TaskDraft {
  var title: String
  var status: TaskItem.Status = .todo
  var priority: TaskItem.Priority = .medium
  var due: TaskItem.DueDate?
  var waitingReason: String?
  var description = ""
  var workspace: UUID?
  var createdBy: String?
  var links: [TaskLink] = []
  var worktree: TaskWorktree?
}

/// JSON の `null` に当たる「外す」を、値の指定と区別して運ぶ。
enum ClearableValue<Value> {
  case set(Value)
  case clear

  var value: Value? {
    if case .set(let v) = self { return v }
    return nil
  }
}

/// 変更の要求。nil の項目は変えない。
struct TaskUpdate {
  var title: String?
  var status: TaskItem.Status?
  var priority: TaskItem.Priority?
  var due: ClearableValue<TaskItem.DueDate>?
  var waitingReason: ClearableValue<String>?
  /// `.clear` は条件だけを外す（待ちは残る）。
  var waitingCondition: ClearableValue<WaitConditionRequest>?
  var description: String?
  var workspace: ClearableValue<UUID>?
  /// 丸ごと置き換える。`[]` で全部外す。
  var links: [TaskLink]?
  var worktree: ClearableValue<TaskWorktree>?

  var isEmpty: Bool {
    title == nil && status == nil && priority == nil && due == nil && waitingReason == nil
      && waitingCondition == nil && description == nil && workspace == nil && links == nil
      && worktree == nil
  }
}
