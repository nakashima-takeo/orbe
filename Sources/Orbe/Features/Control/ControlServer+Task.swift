import Foundation
import OrbeSessionLog

/// タスクの 5 動詞の domain 操作（`ControlTarget` の一部。main スレッドでのみ呼ぶ）。
protocol ControlTaskTarget: AnyObject {
  /// タスクを列の順に列挙する（list_tasks）。workspaceId 指定でその workspace のタスクだけ。未知 id は -32004。
  func controlListTasks(workspaceId: Int?) -> Result<Any, ControlError>
  /// タスクを列の末尾へ足す（add_task）。workspaceId は省略＝呼び出し元タブの workspace（タブが分からなければ
  /// なし）・`.clear`＝なし・`.set`＝その workspace（未知は -32004）。callerTabId は追加者の agent 名と
  /// 既定の付き先を引くためだけに読み、未知のタブでもエラーにしない。worktree は実在するディレクトリの
  /// 絶対パス（それ以外は -32602）で、それを含む worktree のルートに揃えて付ける。待ちの条件には、呼び出し元タブの
  /// 作業ディレクトリ・workspace・会話を入れる。
  func controlAddTask(
    _ draft: TaskDraft, workspaceId: ClearableValue<Int>?, callerTabId: Int?, worktree: String?
  ) -> Result<Any, ControlError>
  /// タスクを変える（update_task）。workspaceId・worktree は省略＝変えない・`.clear`＝なし・`.set`＝付ける。
  /// callerTabId は待ちの条件に呼び出し元タブの作業ディレクトリ・workspace・会話を入れるためだけに読む。
  func controlUpdateTask(
    taskId: Int, _ update: TaskUpdate, workspaceId: ClearableValue<Int>?,
    worktree: ClearableValue<String>?, callerTabId: Int?
  ) -> Result<Any, ControlError>
  /// タスクを別のタスクの前か後ろへ移す（move_task）。
  func controlMoveTask(taskId: Int, _ placement: TaskStore.Placement, anchorTaskId: Int)
    -> Result<Any, ControlError>
  /// タスクを消す（delete_task）。
  func controlDeleteTask(taskId: Int) -> Result<Any, ControlError>
  /// タスクから作業を始める（start_task）。作業場を用意してタブを開いた時点で、main で 1 度だけ `completion` を呼ぶ。
  func controlStartTask(
    _ request: TaskStartRequest, completion: @escaping (Result<Any, ControlError>) -> Void)
}

extension ControlServer {
  /// `start_task`: queue で params の型を確かめ、main で始め、作業場の用意（worktree の作成・fetch の着地待ちで
  /// 数秒かかりうる）が済んだ完了で 1 度だけ応答する。
  func startTask(id: Any?, params: [String: Any], conn: Connection) {
    let request: TaskStartRequest
    do throws(ControlError) {
      let p = TaskParams(params)
      request = TaskStartRequest(
        taskId: try p.int("taskId"), branch: try p.optionalString("branch"),
        repo: try p.optionalString("repo"), agent: try p.optionalString("agent"),
        prompt: try p.optionalString("prompt"))
    } catch {
      return conn.respond(id: id, result: .failure(error))
    }
    DispatchQueue.main.async {
      let respond = { result in self.queue.async { conn.respond(id: id, result: result) } }
      guard let target = self.target else {
        return respond(.failure(ControlError(code: -32000, message: "no window")))
      }
      target.controlStartTask(request, completion: respond)
    }
  }
}

/// タスクの 5 動詞の解決。ハンドラが見るのは params の在否と JSON の型（違反は -32602）だけで、値の検証と
/// 不変条件は `TaskStore`、workspace・呼び出し元タブ・worktree の解決は target が持つ。
extension ControlServer {
  /// 非該当は nil。target を `ControlTaskTarget` に絞っても `WindowedHandler` として渡せる。
  func taskHandler(for method: String) -> (
    (ControlTaskTarget, [String: Any]) -> Result<Any, ControlError>
  )? {
    guard let body = taskBody(for: method) else { return nil }
    return { target, params in
      do throws(ControlError) {
        return try body(target, TaskParams(params))
      } catch {
        return .failure(error)
      }
    }
  }

  private func taskBody(for method: String) -> TaskBody? {
    switch method {
    case "list_tasks":
      return { target, p throws(ControlError) in
        target.controlListTasks(workspaceId: try p.optionalInt("workspaceId"))
      }
    case "add_task":
      return { target, p throws(ControlError) in
        var draft = TaskDraft(title: try p.string("title"))
        if let status = try p.status() { draft.status = status }
        if let priority = try p.priority() { draft.priority = priority }
        draft.due = try p.due()?.value
        draft.waitingReason = try p.nullableString("waitingReason")?.value
        draft.waitingCondition = try p.waitingCondition()?.value
        if let description = try p.optionalString("description") { draft.description = description }
        if let links = try p.links() { draft.links = links }
        return target.controlAddTask(
          draft, workspaceId: try p.nullableInt("workspaceId"),
          callerTabId: try p.optionalInt("callerTabId"), worktree: try p.optionalString("worktree"))
      }
    case "update_task":
      return { target, p throws(ControlError) in
        let update = TaskUpdate(
          title: try p.optionalString("title"), status: try p.status(),
          priority: try p.priority(), due: try p.due(),
          waitingReason: try p.nullableString("waitingReason"),
          waitingCondition: try p.waitingCondition(),
          description: try p.optionalString("description"), links: try p.links())
        return target.controlUpdateTask(
          taskId: try p.int("taskId"), update, workspaceId: try p.nullableInt("workspaceId"),
          worktree: try p.nullableString("worktree"), callerTabId: try p.optionalInt("callerTabId"))
      }
    case "move_task":
      return { target, p throws(ControlError) in
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
      }
    case "delete_task":
      return { target, p throws(ControlError) in
        target.controlDeleteTask(taskId: try p.int("taskId"))
      }
    default:
      return nil
    }
  }
}

private typealias TaskBody = (ControlTaskTarget, TaskParams) throws(ControlError) -> Result<
  Any, ControlError
>

/// params の型検査。キーが無いことと `null` を区別する（`null` は「外す」）。
private struct TaskParams {
  let params: [String: Any]
  /// 入れ子の値のキーに付ける、拒否の文の前置き（`waitingCondition.`）。
  let prefix: String

  init(_ params: [String: Any], prefix: String = "") {
    self.params = params
    self.prefix = prefix
  }

  func invalid(_ key: String) -> ControlError {
    ControlError(code: -32602, message: "invalid \(prefix)\(key)")
  }

  /// JSONSerialization は true / false も NSNumber に載せ `as? Int` を通すので、真偽値を整数として受けない。
  private func intValue(_ raw: Any, _ key: String) throws(ControlError) -> Int {
    let isBool = (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    guard !isBool, let n = raw as? Int else { throw invalid(key) }
    return n
  }

  func int(_ key: String) throws(ControlError) -> Int {
    guard let raw = params[key] else {
      throw ControlError(code: -32602, message: "missing \(prefix)\(key)")
    }
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
    guard let raw = params[key] else {
      throw ControlError(code: -32602, message: "missing \(prefix)\(key)")
    }
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

  /// 待ちの条件（`{description, command, everyMinutes, deadline}`。4 つとも必須）。`null` は条件だけを外す。
  /// 値の規則（空・間隔の下限・過ぎた期限）はストアが確かめる。
  func waitingCondition() throws(ControlError) -> ClearableValue<WaitConditionRequest>? {
    guard let raw = params["waitingCondition"] else { return nil }
    if raw is NSNull { return .clear }
    guard let object = raw as? [String: Any] else { throw invalid("waitingCondition") }
    let fields = TaskParams(object, prefix: "waitingCondition.")
    guard let deadline = Self.deadline(try fields.string("deadline")) else {
      throw fields.invalid("deadline")
    }
    return .set(
      WaitConditionRequest(
        description: try fields.string("description"), command: try fields.string("command"),
        everyMinutes: try fields.int("everyMinutes"), deadline: deadline))
  }

  /// ISO 8601 の日時。時差の無い形（`2026-10-13T09:00`）は Mac のタイムゾーンの時刻として読む。
  static func deadline(_ text: String) -> Date? {
    if let date = SessionEvent.parseISO8601(text) { return date }
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.timeZone = .current
    for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
      local.dateFormat = format
      if let date = local.date(from: text) { return date }
    }
    return nil
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
