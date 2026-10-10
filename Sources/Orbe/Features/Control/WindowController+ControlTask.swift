import Foundation
import OrbeSessionLog

/// タスクの動詞（5 動詞と `set_wait_condition`）の domain 側。外に見せる起動ごとの workspaceId とタスクが持つ永続 ID の相互変換・
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

  func controlAddTask(
    _ draft: TaskDraft, workspaceId: ClearableValue<Int>?, callerTabId: Int?,
    worktree: String? = nil
  ) -> Result<Any, ControlError> {
    var draft = draft
    if let worktree {
      guard let resolved = TaskWorktree(directory: worktree) else {
        return .failure(Self.notADirectory(worktree))
      }
      draft.worktree = resolved
    }
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

  func controlUpdateTask(
    taskId: Int, _ update: TaskUpdate, workspaceId: ClearableValue<Int>?,
    worktree: ClearableValue<String>? = nil
  ) -> Result<Any, ControlError> {
    var update = update
    switch worktree {
    case nil:
      break
    case .clear:
      update.worktree = .clear
    case .set(let path):
      guard let resolved = TaskWorktree(directory: path) else {
        return .failure(Self.notADirectory(path))
      }
      update.worktree = .set(resolved)
    }
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

  func controlSetWaitCondition(
    taskId: Int, _ condition: ClearableValue<WaitConditionRequest>, callerTabId: Int?
  ) -> Result<Any, ControlError> {
    var update = TaskUpdate()
    switch condition {
    case .set(let request):
      update.waitingCondition = .set(
        locate(request, caller: callerTabId.flatMap(controlResolveTab)))
    case .clear:
      update.waitingCondition = .clear
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

  /// 待ちの条件に、呼び出し元タブの作業ディレクトリ（タブの今の cwd）と、会話を入れる。会話を残すのは、そのタブの
  /// agent が作業中を報告しているとき（agent が自分のターンの中で付けた）だけ——人がシェルから打った条件や、終了を報告
  /// しない agent が去った後のタブからの条件を、その会話のものとして残さない（追加者と同じ規則）。agent が自分で書いた
  /// 値は使わない。
  private func locate(_ request: WaitConditionRequest, caller: TerminalTab?)
    -> WaitConditionRequest
  {
    var request = request
    guard let caller else { return request }
    request.directory = caller.cwd
    if caller.agentState == "working", let session = caller.agentSlot.session,
      let sessionId = session.sessionId, AgentCatalog.isSafeSessionId(sessionId)
    {
      request.conversation = WaitConversation(
        command: session.command, sessionId: sessionId,
        workspace: workspaces.first { $0.tabs.contains { $0 === caller } }?.persistentId,
        secretary: secretary.isSecretary(caller))
    }
    return request
  }

  private static let workspaceNotFound = ControlError(code: -32004, message: "workspace not found")

  private static func notADirectory(_ path: String) -> ControlError {
    ControlError(code: -32602, message: "worktree is not an absolute path to a directory: \(path)")
  }

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
  /// 「なし」と同じくキーごと出さない。worktree もディレクトリが無ければ出さない。無い値はキーごと出さない。
  /// 外した項目は出さない（自動の結び付けのための内部の記録）。
  func taskJSON(_ task: TaskItem) -> [String: Any] {
    var json: [String: Any] = [
      "taskId": task.id, "title": task.title, "status": task.status.rawValue,
      "priority": task.priority.rawValue, "description": task.description,
      "createdAt": SessionEvent.iso8601(task.createdAt),
    ]
    if let waiting = task.waiting { json["waiting"] = Self.waitingJSON(waiting) }
    if let resolution = task.waitResolution {
      var resolved: [String: Any] = [
        "at": SessionEvent.iso8601(resolution.at), "waiting": Self.waitingJSON(resolution.waiting),
      ]
      switch resolution.how {
      case .satisfied(let output):
        resolved["how"] = "satisfied"
        resolved["output"] = output
      case .expired:
        resolved["how"] = "expired"
      }
      json["waitResolved"] = resolved
    }
    if let due = task.due { json["due"] = due.text }
    if let ws = task.workspace.flatMap({ id in workspaces.first { $0.persistentId == id } }) {
      json["workspaceId"] = ws.id
      json["workspaceName"] = ws.name
    }
    if let createdBy = task.createdBy { json["createdBy"] = createdBy }
    if let worktree = task.worktree, worktree.exists { json["worktree"] = worktree.path }
    if !task.links.isEmpty {
      json["links"] = task.links.map {
        ["kind": $0.kind.rawValue, "repo": $0.item.repo.value, "number": $0.item.number]
          as [String: Any]
      }
    }
    return json
  }
}

extension WindowController {
  /// 待ち（と、あれば条件と確認の経過）のワイヤの形。解けた待ちも同じ形で読める（同じ条件で付け直せる）。
  fileprivate static func waitingJSON(_ waiting: TaskItem.Waiting) -> [String: Any] {
    var json: [String: Any] = [
      "reason": waiting.reason, "since": SessionEvent.iso8601(waiting.since),
    ]
    guard let condition = waiting.condition else { return json }
    var wire: [String: Any] = [
      "description": condition.description, "command": condition.command,
      "everyMinutes": condition.everyMinutes,
      "deadline": SessionEvent.iso8601(condition.deadline),
      "setAt": SessionEvent.iso8601(condition.setAt), "checks": condition.checks,
    ]
    if let directory = condition.directory { wire["directory"] = directory }
    if let conversation = condition.conversation {
      wire["agent"] = ["command": conversation.command, "sessionId": conversation.sessionId]
    }
    if let last = condition.log.last {
      var check: [String: Any] = [
        "startedAt": SessionEvent.iso8601(last.startedAt), "result": last.result.name,
      ]
      if !last.stdout.isEmpty { check["stdout"] = last.stdout }
      if !last.stderr.isEmpty { check["stderr"] = last.stderr }
      wire["lastCheck"] = check
    }
    json["condition"] = wire
    return json
  }
}
