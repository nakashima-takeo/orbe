import Foundation
import OrbeSessionLog

/// タスクの 5 動詞の domain 側。外に見せる起動ごとの workspaceId とタスクが持つ永続 ID の相互変換・
/// 呼び出し元タブの解決をここで行い、検証と変異は `TaskStore` に任せる。
extension WindowController {
  func controlListTasks(workspaceId: Int?) -> Result<Any, ControlError> {
    var tasks = taskStore.tasks
    if let workspaceId {
      guard let ws = workspaces.first(where: { $0.id == workspaceId }) else {
        return .failure(Self.workspaceNotFound)
      }
      tasks = tasks.filter { $0.workspace == ws.persistentId }
    }
    return .success(["tasks": tasks.map(taskJSON)])
  }

  func controlAddTask(_ draft: TaskDraft, workspaceId: ClearableValue<Int>?, callerTabId: Int?)
    -> Result<Any, ControlError>
  {
    var draft = draft
    let caller = callerTabId.flatMap(controlResolveTab)
    // agent が自分のターンの中で足したときだけ、そのタブの agent は working を報告している。人がシェルから
    // 打った追加や、終了を報告しない agent（codex / agy）が去った後のタブからの追加を agent の名で残さない。
    if let caller, caller.agentState == "working", let session = caller.agentSlot.session {
      draft.createdBy = session.command
    }
    switch workspaceId {
    case nil:
      draft.workspace = caller.flatMap { tab in
        workspaces.first { $0.tabs.contains { $0 === tab } }?.persistentId
      }
    case .clear:
      draft.workspace = nil
    case .set(let id):
      guard let ws = workspaces.first(where: { $0.id == id }) else {
        return .failure(Self.workspaceNotFound)
      }
      draft.workspace = ws.persistentId
    }
    return taskResult { () throws(TaskStoreError) in ["task": taskJSON(try taskStore.add(draft))] }
  }

  func controlUpdateTask(taskId: Int, _ update: TaskUpdate, workspaceId: ClearableValue<Int>?)
    -> Result<Any, ControlError>
  {
    var update = update
    switch workspaceId {
    case nil:
      break
    case .clear:
      update.workspace = .clear
    case .set(let id):
      guard let ws = workspaces.first(where: { $0.id == id }) else {
        return .failure(Self.workspaceNotFound)
      }
      update.workspace = .set(ws.persistentId)
    }
    return taskResult { () throws(TaskStoreError) in
      ["task": taskJSON(try taskStore.update(taskId, update))]
    }
  }

  func controlMoveTask(taskId: Int, _ placement: TaskStore.Placement, anchorTaskId: Int)
    -> Result<Any, ControlError>
  {
    taskResult { () throws(TaskStoreError) in
      try taskStore.move(taskId, placement, anchorTaskId)
      return ["ok": true]
    }
  }

  func controlDeleteTask(taskId: Int) -> Result<Any, ControlError> {
    taskResult { () throws(TaskStoreError) in
      try taskStore.delete(taskId)
      return ["ok": true]
    }
  }

  private static let workspaceNotFound = ControlError(code: -32004, message: "workspace not found")

  /// ストアのドメインエラーを制御エラーの語彙へ写す（未知のタスク → -32004・不正な値 → -32602）。
  private func taskResult(_ body: () throws(TaskStoreError) -> [String: Any]) -> Result<
    Any, ControlError
  > {
    do throws(TaskStoreError) {
      return .success(try body())
    } catch {
      switch error {
      case .notFound(let id):
        return .failure(ControlError(code: -32004, message: "task not found: \(id)"))
      case .invalid(let message):
        return .failure(ControlError(code: -32602, message: message))
      }
    }
  }

  /// list_tasks の要素。workspace は今の workspaceId と名前で見せ、解決できない参照（削除済み）は
  /// 「なし」と同じくキーごと出さない。無い値はキーごと出さない。
  private func taskJSON(_ task: TaskItem) -> [String: Any] {
    var json: [String: Any] = [
      "taskId": task.id, "title": task.title, "status": task.status.rawValue,
      "priority": task.priority.rawValue, "memo": task.memo,
      "createdAt": SessionEvent.iso8601(task.createdAt),
    ]
    if let waiting = task.waiting {
      json["waiting"] = ["reason": waiting.reason, "since": SessionEvent.iso8601(waiting.since)]
    }
    if let due = task.due { json["due"] = due.text }
    if let ws = task.workspace.flatMap({ id in workspaces.first { $0.persistentId == id } }) {
      json["workspaceId"] = ws.id
      json["workspaceName"] = ws.name
    }
    if let createdBy = task.createdBy { json["createdBy"] = createdBy }
    return json
  }
}
