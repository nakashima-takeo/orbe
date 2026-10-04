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
    let now = TaskItem.storedInstant(Date())
    var waiting: TaskItem.Waiting?
    if let raw = draft.waitingReason {
      guard draft.status != .done else { throw .invalid("a done task cannot be waiting") }
      waiting = TaskItem.Waiting(reason: try Self.validReason(raw), since: now)
    }
    let item = TaskItem(
      id: nextId, title: title, status: draft.status, waiting: waiting, priority: draft.priority,
      due: draft.due, workspace: draft.workspace, memo: draft.memo, createdAt: now,
      createdBy: draft.createdBy)
    nextId += 1
    tasks.append(item)
    persist()
    return item
  }

  /// 指定した項目だけを変える。完了にすると待ちが外れる。完了のまま待ちを入れることはできない
  /// （同じ要求でステータスを戻せば入れられる）。
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
    switch update.waitingReason {
    case .set(let raw):
      guard item.status != .done else { throw .invalid("a done task cannot be waiting") }
      let reason = try Self.validReason(raw)
      item.waiting = TaskItem.Waiting(
        reason: reason, since: item.waiting?.since ?? TaskItem.storedInstant(Date()))
    case .clear:
      item.waiting = nil
    case nil:
      break
    }
    if item.status == .done { item.waiting = nil }
    tasks[index] = item
    persist()
    return item
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

  private static func validReason(_ raw: String) throws(TaskStoreError) -> String {
    let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty else { throw .invalid("waiting reason is empty") }
    return reason
  }
}
