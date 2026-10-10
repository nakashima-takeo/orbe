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

  /// 足す位置。
  enum AddPosition: Equatable {
    /// 列の末尾。
    case end
    /// 未着手の欄の中で、足すタスクと同じか低い優先度の最初のタスクの直前（無ければ列の末尾）——その優先度の
    /// 未着手の先頭に入る。
    case priorityHead
  }

  init(file: TasksFile? = TaskPersistence.load()) {
    tasks = file?.tasks ?? []
    nextId = file?.nextId ?? 1
  }

  /// `position` の位置へ足す（既定は列の末尾）。
  func add(_ draft: TaskDraft, at position: AddPosition = .end) throws(TaskStoreError) -> TaskItem {
    let title = try Self.validTitle(draft.title)
    try Self.checkLinks(draft.links, of: nextId, against: tasks)
    try Self.checkWorktree(draft.worktree, of: nextId, against: tasks)
    let now = TaskItem.storedInstant(Date())
    var wait: TaskItem.Wait?
    if let raw = draft.waitingReason {
      guard draft.status != .done else { throw .invalid("a done task cannot be waiting") }
      wait = .waiting(
        TaskItem.Waiting(
          reason: try Self.validReason(raw), since: now,
          condition: try draft.waitingCondition.map { r throws(TaskStoreError) in
            try Self.newCondition(r, now: now)
          }))
    } else if draft.waitingCondition != nil {
      throw .invalid(Self.conditionWithoutWaiting)
    }
    let item = TaskItem(
      id: nextId, title: title, status: draft.status, wait: wait, priority: draft.priority,
      due: draft.due, workspace: draft.workspace, description: draft.description, createdAt: now,
      createdBy: draft.createdBy, links: draft.links, worktree: draft.worktree,
      worktreeBranch: draft.worktree?.currentBranch)
    nextId += 1
    tasks.insert(item, at: index(for: item, position))
    persist()
    return item
  }

  private func index(for item: TaskItem, _ position: AddPosition) -> Int {
    switch position {
    case .end:
      return tasks.endIndex
    case .priorityHead:
      return tasks.firstIndex {
        $0.status == .todo && $0.priority.rank >= item.priority.rank
      } ?? tasks.endIndex
    }
  }

  /// 指定した項目だけを変える。完了にすると待ちの席が空になる（起きたことも消える）。完了のまま待ちや条件を
  /// 入れることはできない（同じ要求でステータスを戻せば入れられる）。結び付きは丸ごと置き換え、外れた項目を
  /// 「外した項目」に足し、足された項目をそこから消す（外した経路を区別しない）。
  func update(_ id: Int, _ update: TaskUpdate) throws(TaskStoreError) -> TaskItem {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
    guard !update.isEmpty else { throw .invalid("no fields to update") }
    var item = tasks[index]
    if let title = update.title { item.title = try Self.validTitle(title) }
    if let status = update.status { item.status = status }
    if let priority = update.priority { item.priority = priority }
    if let due = update.due { item.due = due.value }
    if let description = update.description { item.description = description }
    if let workspace = update.workspace { item.workspace = workspace.value }
    try applyLinksAndWorktree(update, to: &item)
    item.wait = try Self.wait(update, of: item, now: TaskItem.storedInstant(Date()))
    if item.status == .done { item.wait = nil }
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

  /// worktree での作業のブランチを確定する（PR の自動の結び付けが、未確定の記録を持つ worktree が既定
  /// ブランチ以外にいるのを見たとき）。タスクが無い・worktree が `path` でない・記録が既に `branch` なら
  /// 何もしない。
  func confirmWorktreeBranch(_ id: Int, path: String, branch: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }),
      tasks[index].worktree?.path == path, tasks[index].worktreeBranch != branch
    else { return }
    tasks[index].worktreeBranch = branch
    persist()
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

  /// 確認 1 回の結果を記録する。成功なら同じ変異で待ちを「解けた」に置き換え、起きたことを返す。タスクが無い・
  /// 待っていない・条件の同一性が `condition` でないなら何もしない（付け直し・解除の後に届いた古い結果）。
  @discardableResult func recordCheck(_ id: Int, condition: UUID, _ run: BackgroundRunResult)
    -> WaitResolution?
  {
    changeCondition(id, condition) { condition in
      condition.record(WaitCheck(run))
      guard case .exited(0) = run.ending else { return nil }
      var output = ""
      if case .command(let stdout, _) = run.output {
        output = WaitText.head(stdout.data, bytes: WaitResolution.outputBytes)
      }
      return (.satisfied(output: output), TaskItem.storedInstant(run.endedAt))
    }
  }

  /// 期限が来た。待ちを「解けた」に置き換え、起きたことを返す（解けた日時は期限）。何もしない条件は `recordCheck` と同じ。
  @discardableResult func expire(_ id: Int, condition: UUID) -> WaitResolution? {
    changeCondition(id, condition) { condition in (.expired, condition.deadline) }
  }

  /// 起きたことを外す（⌘T で会話へ届けた）。解けていなければ何もしない。
  func clearResolution(_ id: Int) {
    guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].waitResolution != nil
    else { return }
    tasks[index].wait = nil
    persist()
  }

  /// 待っている条件を変え、解けたなら待ちを起きたことに置き換えて、1 度だけ保存する。
  private func changeCondition(
    _ id: Int, _ conditionId: UUID,
    _ body: (inout WaitCondition) -> (WaitResolution.How, Date)?
  ) -> WaitResolution? {
    guard let index = tasks.firstIndex(where: { $0.id == id }),
      var waiting = tasks[index].waiting, var condition = waiting.condition,
      condition.id == conditionId
    else { return nil }
    let resolved = body(&condition)
    waiting.condition = condition
    let resolution = resolved.map { WaitResolution(waiting: waiting, how: $0.0, at: $0.1) }
    tasks[index].wait = resolution.map(TaskItem.Wait.resolved) ?? .waiting(waiting)
    persist()
    return resolution
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

  /// 前後の空白を除いた 1 行のタイトル（`validLine` の規則）。
  static func validTitle(_ raw: String) throws(TaskStoreError) -> String {
    try validLine(raw, "title")
  }

  /// 前後の空白を除いて空でなく、制御文字（Cc）と改行類（U+2028 / U+2029 を含む）を含まない 1 行。
  /// 書式文字（ZWJ 絵文字の U+200D など）は行を壊さないので通す。`name` は拒否の文に入れる項目名。
  static func validLine(_ raw: String, _ name: String) throws(TaskStoreError) -> String {
    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { throw .invalid("\(name) is empty") }
    guard
      !line.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
      })
    else {
      throw .invalid("\(name) contains control characters")
    }
    return line
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

  static func validReason(_ raw: String) throws(TaskStoreError) -> String {
    let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty else { throw .invalid("waiting reason is empty") }
    return reason
  }
}
