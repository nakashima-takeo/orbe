import Foundation

/// タスクの 5 動詞の dispatch。ここが見るのは params の在否と JSON の型（違反は -32602）だけで、値の検証と
/// 不変条件は `TaskStore`、workspace・呼び出し元タブ・worktree の解決は target が持つ。
extension ControlServer {
  func runTask(method: String, params: [String: Any], target: ControlTarget)
    -> Result<Any, ControlError>?
  {
    let p = TaskParams(params)
    do throws(ControlError) {
      switch method {
      case "list_tasks":
        return target.controlListTasks(workspaceId: try p.optionalInt("workspaceId"))
      case "add_task":
        var draft = TaskDraft(title: try p.string("title"))
        if let status = try p.status() { draft.status = status }
        if let priority = try p.priority() { draft.priority = priority }
        draft.due = try p.due()?.value
        draft.waitingReason = try p.nullableString("waitingReason")?.value
        if let memo = try p.optionalString("memo") { draft.memo = memo }
        if let links = try p.links() { draft.links = links }
        return target.controlAddTask(
          draft, workspaceId: try p.nullableInt("workspaceId"),
          callerTabId: try p.optionalInt("callerTabId"), worktree: try p.optionalString("worktree"))
      case "update_task":
        let update = TaskUpdate(
          title: try p.optionalString("title"), status: try p.status(),
          priority: try p.priority(), due: try p.due(),
          waitingReason: try p.nullableString("waitingReason"),
          memo: try p.optionalString("memo"), links: try p.links())
        return target.controlUpdateTask(
          taskId: try p.int("taskId"), update, workspaceId: try p.nullableInt("workspaceId"),
          worktree: try p.nullableString("worktree"))
      case "move_task":
        let taskId = try p.int("taskId")
        switch (try p.optionalInt("beforeTaskId"), try p.optionalInt("afterTaskId")) {
        case (let anchor?, nil):
          return target.controlMoveTask(taskId: taskId, .before, anchorTaskId: anchor)
        case (nil, let anchor?):
          return target.controlMoveTask(taskId: taskId, .after, anchorTaskId: anchor)
        default:
          throw ControlError(
            code: -32602, message: "pass exactly one of beforeTaskId / afterTaskId")
        }
      case "delete_task":
        return target.controlDeleteTask(taskId: try p.int("taskId"))
      default:
        return nil
      }
    } catch {
      return .failure(error)
    }
  }
}

/// params の型検査。キーが無いことと `null` を区別する（`null` は「外す」）。
private struct TaskParams {
  let params: [String: Any]

  init(_ params: [String: Any]) { self.params = params }

  private func invalid(_ key: String) -> ControlError {
    ControlError(code: -32602, message: "invalid \(key)")
  }

  /// JSONSerialization は true / false も NSNumber に載せ `as? Int` を通すので、真偽値を整数として受けない。
  private func intValue(_ raw: Any, _ key: String) throws(ControlError) -> Int {
    let isBool = (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    guard !isBool, let n = raw as? Int else { throw invalid(key) }
    return n
  }

  func int(_ key: String) throws(ControlError) -> Int {
    guard let raw = params[key] else { throw ControlError(code: -32602, message: "missing \(key)") }
    return try intValue(raw, key)
  }

  func optionalInt(_ key: String) throws(ControlError) -> Int? {
    guard let raw = params[key] else { return nil }
    return try intValue(raw, key)
  }

  func nullableInt(_ key: String) throws(ControlError) -> ClearableValue<Int>? {
    guard let raw = params[key] else { return nil }
    if raw is NSNull { return .clear }
    return .set(try intValue(raw, key))
  }

  func string(_ key: String) throws(ControlError) -> String {
    guard let raw = params[key] else { throw ControlError(code: -32602, message: "missing \(key)") }
    guard let text = raw as? String else { throw invalid(key) }
    return text
  }

  func optionalString(_ key: String) throws(ControlError) -> String? {
    guard params[key] != nil else { return nil }
    return try string(key)
  }

  func nullableString(_ key: String) throws(ControlError) -> ClearableValue<String>? {
    guard let raw = params[key] else { return nil }
    if raw is NSNull { return .clear }
    return .set(try string(key))
  }

  func status() throws(ControlError) -> TaskItem.Status? {
    guard let raw = try optionalString("status") else { return nil }
    guard let status = TaskItem.Status(rawValue: raw) else { throw invalid("status") }
    return status
  }

  func priority() throws(ControlError) -> TaskItem.Priority? {
    guard let raw = try optionalString("priority") else { return nil }
    guard let priority = TaskItem.Priority(rawValue: raw) else { throw invalid("priority") }
    return priority
  }

  /// 結び付きの列。配列だけを受け（`null` は型の違反）、各要素の `kind`・`repo`・`number` の型・形・範囲を
  /// 値の型（`GitHubItemKind`・`GitHubItemID`）で確かめる。
  func links() throws(ControlError) -> [TaskLink]? {
    guard let raw = params["links"] else { return nil }
    guard let elements = raw as? [Any] else { throw invalid("links") }
    var links: [TaskLink] = []
    for element in elements {
      guard let object = element as? [String: Any],
        let kind = (object["kind"] as? String).flatMap(GitHubItemKind.init(rawValue:)),
        let repo = object["repo"] as? String, let rawNumber = object["number"]
      else { throw invalid("links") }
      guard let item = GitHubItemID(repo: repo, number: try intValue(rawNumber, "links")) else {
        throw invalid("links")
      }
      links.append(TaskLink(item: item, kind: kind))
    }
    return links
  }

  func due() throws(ControlError) -> ClearableValue<TaskItem.DueDate>? {
    switch try nullableString("due") {
    case .set(let raw):
      guard let due = TaskItem.DueDate(raw) else { throw invalid("due") }
      return .set(due)
    case .clear: return .clear
    case nil: return nil
    }
  }
}
