@testable import Orbe

extension TaskStore {
  /// 待っているタスクを足し、条件を付ける（条件は帳簿の追加とは別の口で付く）。
  func addWaiting(_ draft: TaskDraft, _ condition: WaitConditionRequest) throws(TaskStoreError)
    -> TaskItem
  {
    let task = try add(draft)
    return try update(task.id, TaskUpdate(waitingCondition: .set(condition)))
  }
}
