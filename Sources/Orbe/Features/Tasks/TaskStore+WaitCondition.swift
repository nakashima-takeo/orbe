import Foundation

/// 待ちの席と待ちの条件の規則（`TaskStore` の変異と読み込みが使う）。
extension TaskStore {
  static let conditionWithoutWaiting = "a waiting condition needs a waiting task"

  /// 変更を当てた後の待ちの席。理由だけを変えても、待ち始めた日時・条件・経過は変わらない。空か解けた席に理由を
  /// 付けると、新しく待っている段階になる（起きたことは消える）。理由を外すと待ちごと外れる（解けた席はそのまま）。
  /// 条件は待っている段階にだけ付き、付け直すと新しい同一性で経過は空から始まる。
  static func wait(_ update: TaskUpdate, of item: TaskItem, now: Date) throws(TaskStoreError)
    -> TaskItem.Wait?
  {
    var wait = item.wait
    switch update.waitingReason {
    case .set(let raw):
      guard item.status != .done else { throw .invalid("a done task cannot be waiting") }
      let reason = try validReason(raw)
      if var waiting = item.waiting {
        waiting.reason = reason
        wait = .waiting(waiting)
      } else {
        wait = .waiting(TaskItem.Waiting(reason: reason, since: now))
      }
    case .clear:
      if item.waiting != nil { wait = nil }
    case nil:
      break
    }
    guard case .waiting(var waiting) = wait else {
      if case .set = update.waitingCondition { throw .invalid(conditionWithoutWaiting) }
      return wait
    }
    switch update.waitingCondition {
    case .set(let request):
      guard item.status != .done else {
        throw .invalid("a done task cannot have a waiting condition")
      }
      waiting.condition = try newCondition(request, now: now)
    case .clear:
      waiting.condition = nil
    case nil:
      break
    }
    return .waiting(waiting)
  }

  /// 要求から新しい条件を作る（説明は前後の空白を除く）。期限は今より後でなければならない。
  static func newCondition(_ request: WaitConditionRequest, now: Date) throws(TaskStoreError)
    -> WaitCondition
  {
    var request = request
    request.description = try validLine(request.description, "waiting condition description")
    request.deadline = TaskItem.storedInstant(request.deadline)
    guard request.deadline > now else { throw .invalid("waiting condition deadline has passed") }
    let condition = WaitCondition(request, setAt: now)
    try checkCondition(condition)
    return condition
  }

  /// 付けるときと読み込みが共有する値の規則: 説明が空でない 1 行で、u1 の予定として通ること（間隔の下限・空の
  /// コマンド・相対の作業ディレクトリ）。期限が過ぎていることは問わない（読み込んだ後に解けるだけ）。
  static func checkCondition(_ condition: WaitCondition) throws(TaskStoreError) {
    guard
      try validLine(condition.description, "waiting condition description")
        == condition.description
    else { throw .invalid("waiting condition description has surrounding spaces") }
    do throws(BackgroundJobError) {
      try condition.schedule.validate()
    } catch {
      throw .invalid("invalid waiting condition: \(Self.message(error))")
    }
  }

  private static func message(_ error: BackgroundJobError) -> String {
    switch error {
    case .intervalTooShort: "interval must be at least 1 minute"
    case .intervalTooLong: "interval must be at most 10080 minutes (7 days)"
    case .emptyCommand: "command is empty"
    case .relativeDirectory: "directory must be an absolute path"
    default: "\(error)"
    }
  }
}
