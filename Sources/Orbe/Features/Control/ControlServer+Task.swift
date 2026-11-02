import Foundation
import OrbeSessionLog

/// タスクの動詞（4 動詞と `set_wait_condition`・`start_task`）の domain 操作（`ControlTarget` の一部。main スレッドでのみ呼ぶ）。
protocol ControlTaskTarget: AnyObject {
  /// タスクを作成の新しい順（`TaskItem.newerFirst`）に列挙する（list_tasks）。workspaceId 指定でその workspace のタスクだけ。未知 id は -32004。
  func controlListTasks(workspaceId: UUID?) -> Result<Any, ControlError>
  /// タスクを足す（add_task）。workspaceId は省略＝呼び出し元タブの workspace（タブが分からなければ
  /// なし）・`.clear`＝なし・`.set`＝その workspace（未知は -32004）。callerTabId は追加者の agent 名と
  /// 既定の付き先を引くためだけに読み、未知のタブでもエラーにしない。worktree は実在するディレクトリの
  /// 絶対パス（それ以外は -32602）で、それを含む worktree のルートに揃えて付ける。
  func controlAddTask(
    _ draft: TaskDraft, workspaceId: ClearableValue<UUID>?, callerTabId: Int?, worktree: String?
  ) -> Result<Any, ControlError>
  /// タスクを変える（update_task）。workspaceId・worktree は省略＝変えない・`.clear`＝なし・`.set`＝付ける。
  func controlUpdateTask(
    taskId: Int, _ update: TaskUpdate, workspaceId: ClearableValue<UUID>?,
    worktree: ClearableValue<String>?
  ) -> Result<Any, ControlError>
  /// 待っているタスクに解ける条件を付ける・外す（set_wait_condition）。付ける条件には、呼び出し元タブの作業ディレクトリ・
  /// workspace・会話を入れる。
  func controlSetWaitCondition(
    taskId: Int, _ condition: ClearableValue<WaitConditionRequest>, callerTabId: Int?
  ) -> Result<Any, ControlError>
  /// タスクを消す（delete_task）。
  func controlDeleteTask(taskId: Int) -> Result<Any, ControlError>
  /// タスクから作業を始める（start_task）。作業場を用意してタブを開いた時点で、main で 1 度だけ `completion` を呼ぶ。
  func controlStartTask(
    _ request: TaskStartRequest, completion: @escaping (Result<Any, ControlError>) -> Void)
}

extension ControlServer {
  /// `start_task`: queue で引数の型を確かめ、main で始め、作業場の用意（worktree の作成・fetch の着地待ちで
  /// 数秒かかりうる）が済んだ完了で 1 度だけ応答する。
  func startTask(id: Any?, params p: ControlParams, conn: Connection) {
    let request: TaskStartRequest
    do throws(ControlError) {
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

/// タスクの動詞（4 動詞と `set_wait_condition`）。ハンドラが見るのは引数の在否と JSON の型（違反は -32602）だけで、値の検証と
/// 不変条件は `TaskStore`、workspace・呼び出し元タブ・worktree の解決は target が持つ。
extension ControlServer {
  static func listTasks(_ target: ControlTaskTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    target.controlListTasks(workspaceId: try p.optionalWorkspaceId())
  }

  /// 呼び出し元のタブは要求の封筒から読む（追加者と、workspace を省いたときの付き先）。
  static func addTask(_ target: ControlTaskTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    var draft = TaskDraft(title: try p.string("title"))
    if let status = try p.status() { draft.status = status }
    if let priority = try p.priority() { draft.priority = priority }
    draft.due = try p.due()?.value
    draft.waitingReason = try p.clearableString("waitingReason")?.value
    if let description = try p.optionalString("description") { draft.description = description }
    if let links = try p.links() { draft.links = links }
    let workspaceId = try p.clearableWorkspaceId()
    let worktree = try p.optionalString("worktree")
    return target.controlAddTask(
      draft, workspaceId: workspaceId, callerTabId: p.callerTabId, worktree: worktree)
  }

  static func updateTask(_ target: ControlTaskTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let taskId = try p.int("taskId")
    let update = TaskUpdate(
      title: try p.optionalString("title"), status: try p.status(), priority: try p.priority(),
      due: try p.due(), waitingReason: try p.clearableString("waitingReason"),
      description: try p.optionalString("description"), links: try p.links())
    let workspaceId = try p.clearableWorkspaceId()
    let worktree = try p.clearableString("worktree")
    return target.controlUpdateTask(
      taskId: taskId, update, workspaceId: workspaceId, worktree: worktree)
  }

  /// 呼び出し元のタブは要求の封筒から読む（条件の作業ディレクトリと会話）。
  static func setWaitCondition(_ target: ControlTaskTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    let taskId = try p.int("taskId")
    return target.controlSetWaitCondition(
      taskId: taskId, try p.condition(), callerTabId: p.callerTabId)
  }

  static func deleteTask(_ target: ControlTaskTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    target.controlDeleteTask(taskId: try p.int("taskId"))
  }
}

/// タスクの引数のうち、語彙や入れ子の形を持つもの。キーが無いことと `null` を区別する（`null` は「外す」）。
extension ControlParams {
  fileprivate func status() throws(ControlError) -> TaskItem.Status? {
    guard let raw = try optionalString("status") else { return nil }
    guard let status = TaskItem.Status(rawValue: raw) else { throw invalid("status") }
    return status
  }

  fileprivate func priority() throws(ControlError) -> TaskItem.Priority? {
    guard let raw = try optionalString("priority") else { return nil }
    guard let priority = TaskItem.Priority(rawValue: raw) else { throw invalid("priority") }
    return priority
  }

  fileprivate func due() throws(ControlError) -> ClearableValue<TaskItem.DueDate>? {
    switch try clearableString("due") {
    case .set(let raw):
      guard let due = TaskItem.DueDate(raw) else { throw invalid("due") }
      return .set(due)
    case .clear: return .clear
    case nil: return nil
    }
  }

  /// 結び付きの列。オブジェクトの配列だけを受け（`null` は型の違反）、各要素は `{kind, repo, number}` だけを持ち、値の型
  /// （`GitHubItemKind`・`GitHubItemID`）で形と範囲を確かめる。要素の誤りは要素の場所で言う（`missing links[0].number`）。
  fileprivate func links() throws(ControlError) -> [TaskLink]? {
    guard let elements = try optionalObjects("links") else { return nil }
    var links: [TaskLink] = []
    for (index, element) in elements.enumerated() {
      let at = "links[\(index)]"
      let fields = try ControlParams(
        element, accepting: ["kind": .string, "repo": .string, "number": .int], prefix: at + ".")
      let rawKind = try fields.string("kind")
      let repo = try fields.string("repo")
      let number = try fields.int("number")
      guard let kind = GitHubItemKind(rawValue: rawKind) else { throw fields.invalid("kind") }
      guard let item = GitHubItemID(repo: repo, number: number) else {
        throw ControlError(code: -32602, message: "invalid \(at)")
      }
      links.append(TaskLink(item: item, kind: kind))
    }
    return links
  }

  /// 待ちの条件（`{description, command, everyMinutes, deadline}`。4 つとも必須で、ほかの欄は持たない）。`null` は条件だけを
  /// 外す。値の規則（空・間隔の下限・過ぎた期限）はストアが確かめる。
  fileprivate func condition() throws(ControlError) -> ClearableValue<WaitConditionRequest> {
    switch try clearableObject("condition") {
    case nil: throw missing("condition")
    case .clear: return .clear
    case .set(let object):
      let fields = try ControlParams(
        object,
        accepting: [
          "description": .string, "command": .string, "everyMinutes": .int, "deadline": .string,
        ], prefix: "condition.")
      let description = try fields.string("description")
      let command = try fields.string("command")
      let everyMinutes = try fields.int("everyMinutes")
      guard let deadline = Self.deadline(try fields.string("deadline")) else {
        throw fields.invalid("deadline")
      }
      return .set(
        WaitConditionRequest(
          description: description, command: command, everyMinutes: everyMinutes,
          deadline: deadline))
    }
  }

  /// ISO 8601 の日時。時差の無い形（`2026-10-13T09:00`）は Mac のタイムゾーンの時刻として読む。秒は時差の有無に
  /// 関わらず省ける（`2026-10-13T09:00+09:00`）。
  private static func deadline(_ text: String) -> Date? {
    if let date = SessionEvent.parseISO8601(text) { return date }
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.timeZone = .current
    for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mmXXXXX"] {
      local.dateFormat = format
      if let date = local.date(from: text) { return date }
    }
    return nil
  }
}
