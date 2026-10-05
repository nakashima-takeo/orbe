import Foundation
import Observation

/// 変異が受け付けられなかった理由。
enum TaskStoreError: Error, Equatable {
  /// 指したタスクが無い。
  case notFound(Int)
  /// 値か組み合わせが不変条件に反する。
  case invalid(String)
}

/// タスク一覧の唯一の正（@Observable・main のみ）。`WindowController` が 1 個所有し、制御 API と画面が
/// 同じ変異メソッドを呼ぶ——値の検証と不変条件はここだけが持つ。変異が成功するたびに即座に保存するので、
/// 呼び出し側に保存の責務は無い。
@Observable final class TaskStore {
  /// ユーザーが決める 1 本の列。ステータス別の欄や絞り込みは表示側がここから抜き出す。
  private(set) var tasks: [TaskItem]
  private var nextId: Int

  enum Placement {
    case before, after
  }

  init(file: TasksFile? = TaskPersistence.load()) {
    tasks = file?.tasks ?? []
    nextId = file?.nextId ?? 1
  }

  /// 列の末尾へ足す。
  func add(_ draft: TaskDraft) throws(TaskStoreError) -> TaskItem {
    let title = try Self.validTitle(draft.title)
    try Self.checkLinks(draft.links, of: nextId, against: tasks)
    try Self.checkWorktree(draft.worktree, of: nextId, against: tasks)
    let now = TaskItem.storedInstant(Date())
    var waiting: TaskItem.Waiting?
    if let raw = draft.waitingReason {
      guard draft.status != .done else { throw .invalid("a done task cannot be waiting") }
      waiting = TaskItem.Waiting(reason: try Self.validReason(raw), since: now)
    }
    let item = TaskItem(
      id: nextId, title: title, status: draft.status, waiting: waiting, priority: draft.priority,
      due: draft.due, workspace: draft.workspace, memo: draft.memo, createdAt: now,
      createdBy: draft.createdBy, links: draft.links, worktree: draft.worktree,
      worktreeBranch: draft.worktree?.currentBranch)
    nextId += 1
    tasks.append(item)
    persist()
    return item
  }

  /// 指定した項目だけを変える。完了にすると待ちが外れる。完了のまま待ちを入れることはできない
  /// （同じ要求でステータスを戻せば入れられる）。結び付きは丸ごと置き換え、外れた項目を「外した項目」に
  /// 足し、足された項目をそこから消す（外した経路を区別しない）。
  func update(_ id: Int, _ update: TaskUpdate) throws(TaskStoreError) -> TaskItem {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
    guard !update.isEmpty else { throw .invalid("no fields to update") }
    var item = tasks[index]
    if let title = update.title { item.title = try Self.validTitle(title) }
    if let status = update.status { item.status = status }
    if let priority = update.priority { item.priority = priority }
    if let due = update.due { item.due = due.value }
    if let memo = update.memo { item.memo = memo }
    if let workspace = update.workspace { item.workspace = workspace.value }
    try applyLinksAndWorktree(update, to: &item)
    item.waiting = try Self.waiting(update.waitingReason, of: item)
    if item.status == .done { item.waiting = nil }
    tasks[index] = item
    persist()
    return item
  }

  /// 結び付きと worktree の変更を当てる（どちらも、ほかのタスクとの不変条件を持つ）。結び付きから外れた
  /// 項目は外した項目に足し、足された項目はそこから消す。
  private func applyLinksAndWorktree(_ update: TaskUpdate, to item: inout TaskItem)
    throws(TaskStoreError)
  {
    if let links = update.links {
      try Self.checkLinks(links, of: item.id, against: tasks)
      let kept = Set(links.map(\.item))
      item.unlinked = item.unlinked.union(item.links.map(\.item)).subtracting(kept)
      item.links = links
    }
    if let worktree = update.worktree {
      try Self.checkWorktree(worktree.value, of: item.id, against: tasks)
      item.worktree = worktree.value
      item.worktreeBranch = worktree.value?.currentBranch
    }
  }

  /// 待ちの変更を当てた後の待ち。理由だけを変えても待ち始めた日時は動かない。
  private static func waiting(_ change: ClearableValue<String>?, of item: TaskItem)
    throws(TaskStoreError) -> TaskItem.Waiting?
  {
    switch change {
    case .set(let raw):
      guard item.status != .done else { throw .invalid("a done task cannot be waiting") }
      return TaskItem.Waiting(
        reason: try validReason(raw),
        since: item.waiting?.since ?? TaskItem.storedInstant(Date()))
    case .clear:
      return nil
    case nil:
      return item.waiting
    }
  }

  /// `id` を `anchor` の前か後ろへ移す。
  func move(_ id: Int, _ placement: Placement, _ anchor: Int) throws(TaskStoreError) {
    guard id != anchor else { throw .invalid("a task cannot be moved relative to itself") }
    guard let from = tasks.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
    guard tasks.contains(where: { $0.id == anchor }) else { throw .notFound(anchor) }
    let item = tasks.remove(at: from)
    let at = tasks.firstIndex { $0.id == anchor }!
    tasks.insert(item, at: placement == .before ? at : at + 1)
    persist()
  }

  /// ⌘T の ↵ で作業を始めた。`worktree` を付け（ほかのタスクが持っていればそこから外し）、未着手・完了なら
  /// 進行中にする（完了から戻すので待ちは無い）。一度だけ保存する——付け替えを 2 回の変異に分けると、
  /// 間に読んだ agent に不変条件の破れか「どちらも持たない」状態が見える。外した前の持ち主の ID を返す。
  @discardableResult func begin(_ id: Int, worktree: TaskWorktree) throws(TaskStoreError) -> Int? {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
    let previous = tasks.firstIndex { $0.id != id && $0.worktree == worktree }
    if let previous {
      tasks[previous].worktree = nil
      tasks[previous].worktreeBranch = nil
    }
    tasks[index].worktree = worktree
    tasks[index].worktreeBranch = worktree.currentBranch
    tasks[index].status = .inProgress
    persist()
    return previous.map { tasks[$0].id }
  }

  /// 画面の付け替え・選んで結び付ける。その項目をどのタスクが持っていても外し、`id` のタスクの結び付きの
  /// 末尾に足して、一度だけ保存する——外す・付けるの 2 回の変異に分けると、間に読んだ agent に「どこにも
  /// 付いていない」状態が見え、後の 1 回が拒否されると外れただけで残る。外した側の外した項目に記録し、
  /// 足した側からは消す（`update` と同じ規則）。`id` が既に持っていれば何もしない。前の持ち主の ID を返す。
  @discardableResult func attach(_ link: TaskLink, to id: Int) throws(TaskStoreError) -> Int? {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
    guard !tasks[index].links.contains(where: { $0.item == link.item }) else { return nil }
    let previous = tasks.firstIndex { $0.links.contains { $0.item == link.item } }
    if let previous {
      tasks[previous].links.removeAll { $0.item == link.item }
      tasks[previous].unlinked.insert(link.item)
    }
    tasks[index].links.append(link)
    tasks[index].unlinked.remove(link.item)
    persist()
    return previous.map { tasks[$0].id }
  }

  /// worktree のブランチの PR の自動の結び付け。結び付きの末尾に足す。タスクが無い・完了・その項目を
  /// 人が外した・どこかのタスクに既に付いている、のどれかなら何もしない（外した項目の記録は変えない）。
  /// 足したら true。
  @discardableResult func linkFromBranch(_ id: Int, _ link: TaskLink) -> Bool {
    guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status != .done,
      !tasks[index].unlinked.contains(link.item),
      !tasks.contains(where: { $0.links.contains { $0.item == link.item } })
    else { return false }
    tasks[index].links.append(link)
    persist()
    return true
  }

  func delete(_ id: Int) throws(TaskStoreError) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
    tasks.remove(at: index)
    persist()
  }

  private func persist() {
    TaskPersistence.save(
      TasksFile(version: TaskPersistence.version, nextId: nextId, tasks: tasks))
  }

  /// 前後の空白を除いて空でなく、制御文字（Cc）と改行類（U+2028 / U+2029 を含む）を含まない 1 行。
  /// 書式文字（ZWJ 絵文字の U+200D など）は行を壊さないので通す。
  private static func validTitle(_ raw: String) throws(TaskStoreError) -> String {
    let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw .invalid("title is empty") }
    guard
      !title.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
      })
    else {
      throw .invalid("title contains control characters")
    }
    return title
  }

  /// 結び付きの不変条件。`links` を `id` のタスクの結び付きとして、同じタスクの中で項目が重複せず、
  /// `tasks` のほかのタスクがどの項目も持っていないことを確かめる。項目の同一性はリポジトリと番号で、
  /// 種別は問わない。拒否の文には相手のタスクの ID を入れる（agent が外す相手を知れるように）。
  static func checkLinks(_ links: [TaskLink], of id: Int, against tasks: [TaskItem])
    throws(TaskStoreError)
  {
    var items = Set<GitHubItemID>()
    for link in links where !items.insert(link.item).inserted {
      throw .invalid("github item \(link.item.text) is linked twice")
    }
    for other in tasks where other.id != id {
      if let clash = other.links.first(where: { items.contains($0.item) }) {
        throw .invalid("github item \(clash.item.text) is linked to task \(other.id)")
      }
    }
  }

  /// worktree の不変条件。`worktree` を `id` のタスクの worktree として、`tasks` のほかのタスクが持って
  /// いないことを確かめる。拒否の文には相手のタスクの ID を入れる（agent が外す相手を知れるように）。
  static func checkWorktree(_ worktree: TaskWorktree?, of id: Int, against tasks: [TaskItem])
    throws(TaskStoreError)
  {
    guard let worktree,
      let other = tasks.first(where: { $0.id != id && $0.worktree == worktree })
    else { return }
    throw .invalid("worktree \(worktree.path) is linked to task \(other.id)")
  }

  private static func validReason(_ raw: String) throws(TaskStoreError) -> String {
    let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty else { throw .invalid("waiting reason is empty") }
    return reason
  }
}
