import Foundation

/// 詳細の項目（上から並ぶ順）。
enum TaskDetailField: CaseIterable, Equatable, Hashable {
  case title, status, waiting, priority, due, workspace, memo

  /// ↵ で編集を始める文字の項目。
  var isText: Bool {
    switch self {
    case .title, .waiting, .due, .memo: true
    case .status, .priority, .workspace: false
    }
  }
}

/// 詳細で ↑↓ で止まる場所。固定の項目と、タスクごとに数が変わる結び付きの行。結び付きは位置でなく項目の
/// 同一性で持つ（agent が結び付きを変えても、焦点が別の項目へずれない）。
enum TaskDetailStop: Hashable {
  case field(TaskDetailField)
  case link(GitHubItemID)
}

/// キーを受ける場所（入力欄の一覧か、詳細の止まる場所か）。詳細の編集中かは `draft` が持つ。
enum TaskPaletteArea: Equatable {
  case list
  case detail(TaskDetailStop)
}

/// SwiftUI の焦点の宛先。モデルから一方向に写す。
enum TaskPaletteFocusTarget: Hashable {
  /// ヘッダーの入力欄。
  case field
  /// カードの器（詳細の項目にいる間）。
  case card
  /// 詳細の文字の項目の入力欄。
  case edit(TaskDetailField)
}

/// 詳細の文字の項目の下書き。編集を始めたときの対象に結び付き、確定はその ID へ書く。
struct TaskEditDraft: Equatable {
  let field: TaskDetailField
  let taskID: Int
  /// 編集を始めたときの値。打っていない下書きは確定しても書かない（その間の agent の変更を、触った
  /// だけの古い値で上書きしない）。
  let original: String
  var text: String
}

/// 詳細の操作（項目の移動・選択式の値・文字の項目の編集と確定・結び付きを開く / 外す）。変異はすべて
/// ストアのメソッドをそのまま呼び、検証はストアに任せる。
extension TaskPaletteModel {
  /// 詳細で止まる場所の並び（タイトル → 各結び付き → ステータス → … → メモ）。
  static func detailStops(_ task: TaskItem) -> [TaskDetailStop] {
    [.field(.title)] + task.links.map { .link($0.item) }
      + TaskDetailField.allCases.filter { $0 != .title }.map { .field($0) }
  }

  /// →。タスクの行を選んでいれば、詳細のステータスへ入る。
  func enterDetail() {
    guard tab == .tasks, selectedTask != nil else { return }
    error = nil
    area = .detail(.field(.status))
  }

  /// 詳細から一覧へ（esc・選択式でない項目の ←・入力欄のクリック）。編集中なら確定してから戻る。
  func leaveDetail() {
    leaveEditingForAction()
    area = .list
  }

  /// ↑↓。端では止まる。
  func moveField(_ direction: Int) {
    guard case .detail(let stop) = area, let task = selectedTask else { return }
    let stops = Self.detailStops(task)
    guard let current = stops.firstIndex(of: stop), stops.indices.contains(current + direction)
    else { return }
    error = nil
    area = .detail(stops[current + direction])
  }

  /// ←→。選択式の項目の値を変える。選択式でない項目では false（← は一覧へ戻る合図）。
  @discardableResult func changeValue(_ direction: Int) -> Bool {
    guard case .detail(.field(let field)) = area, let task = selectedTask else { return false }
    error = nil
    switch field {
    case .status:
      let options: [TaskItem.Status] = [.todo, .inProgress]
      // 完了のタスクはどちらも選ばれていないので、押した向きの端の値に戻す。
      let next =
        options.firstIndex(of: task.status).map { min(max($0 + direction, 0), options.count - 1) }
        ?? (direction < 0 ? 0 : options.count - 1)
      if options[next] != task.status { setStatus(options[next]) }
    case .priority:
      let options: [TaskItem.Priority] = [.high, .medium, .low]
      let index = options.firstIndex(of: task.priority)!
      let next = options[min(max(index + direction, 0), options.count - 1)]
      if next != task.priority { setPriority(next) }
    case .workspace:
      let options: [UUID?] = [nil] + workspaces.all.map(\.id)
      let current = options.firstIndex(of: workspaces.entry(task.workspace)?.id) ?? 0
      setWorkspace(options[(current + direction + options.count) % options.count])
    case .title, .waiting, .due, .memo:
      return false
    }
    return true
  }

  func setStatus(_ status: TaskItem.Status) {
    var update = TaskUpdate()
    update.status = status
    apply(update, field: .status)
  }

  func setPriority(_ priority: TaskItem.Priority) {
    var update = TaskUpdate()
    update.priority = priority
    apply(update, field: .priority)
  }

  func setWorkspace(_ id: UUID?) {
    var update = TaskUpdate()
    update.workspace = id.map { .set($0) } ?? .clear
    apply(update, field: .workspace)
  }

  /// 「解除」のクリック。
  func clearWaiting() {
    var update = TaskUpdate()
    update.waitingReason = .clear
    apply(update, field: .waiting)
  }

  func clearDue() {
    var update = TaskUpdate()
    update.due = .clear
    apply(update, field: .due)
  }

  /// 詳細の項目のクリック。文字の項目はそのまま編集を始める。
  func tapField(_ field: TaskDetailField) {
    guard selectedTask != nil else { return }
    leaveEditingForAction()
    area = .detail(.field(field))
    if field.isText { startDraft() }
    focus()
  }

  /// 結び付きの行の ↵・クリック。その項目の GitHub のページを開く。
  func openLink(_ item: GitHubItemID) {
    guard let link = selectedTask?.links.first(where: { $0.item == item }) else { return }
    leaveEditingForAction()
    area = .detail(.link(item))
    focus()
    onOpenURL(link.url)
  }

  /// 結び付きの行の ⌫・「外す」のクリック。その項目だけを除いた列で置き換え、焦点は同じ位置の止まる場所へ
  /// 移る（付け直しが移す）。
  func unlink(_ item: GitHubItemID) {
    guard let task = selectedTask, task.links.contains(where: { $0.item == item }) else { return }
    leaveEditingForAction()
    area = .detail(.link(item))
    focus()
    var update = TaskUpdate()
    update.links = task.links.filter { $0.item != item }
    mutate(.failed) { () throws(TaskStoreError) in _ = try store.update(task.id, update) }
  }

  /// ↵。今の文字の項目の編集を始める。完了のタスクの待ちは入れられない（ストアの不変条件）。
  func beginEditing() {
    if startDraft() { error = nil }
  }

  @discardableResult private func startDraft() -> Bool {
    guard case .detail(.field(let field)) = area, field.isText, draft == nil,
      let task = selectedTask
    else {
      return false
    }
    if field == .waiting, task.status == .done { return false }
    let text = Self.initialText(field, task)
    draft = TaskEditDraft(field: field, taskID: task.id, original: text, text: text)
    return true
  }

  /// ↵（メモは ⌘↵）で確定、esc で取り消す。確定できない（期限が読めない・ストアが受け付けない）ときは
  /// 理由を出して編集を続け、false を返す。
  @discardableResult func endEditing(commit: Bool) -> Bool {
    guard finishDraft(commit: commit) else { return false }
    reconcile()
    return true
  }

  /// 別の場所の操作・画面を閉じる・アプリの終了で編集を抜ける。打った内容は確定して残し、確定できない
  /// ときは（理由をフッターに残して）捨てる——編集を続ける場所がもう無い。
  func leaveEditing() {
    if !finishDraft(commit: true) { draft = nil }
  }

  /// 編集を抜ける唯一の 1 本。確定は下書きの対象の ID へ書き、空のタイトルは取り消しとして扱う。
  private func finishDraft(commit: Bool) -> Bool {
    guard let draft else { return true }
    guard commit, let task = store.tasks.first(where: { $0.id == draft.taskID }),
      let pending = pendingUpdate(draft, task)
    else {
      self.draft = nil
      return true
    }
    switch pending {
    case .failure(let failure):
      error = failure
      return false
    case .success(let update):
      do throws(TaskStoreError) {
        _ = try store.update(task.id, update)
      } catch .invalid {
        error = Self.error(for: draft.field)
        return false
      } catch {
      }
    }
    self.draft = nil
    error = nil
    return true
  }

  private static func initialText(_ field: TaskDetailField, _ task: TaskItem) -> String {
    switch field {
    case .title: task.title
    case .waiting: task.waiting?.reason ?? ""
    case .due: task.due?.text ?? ""
    case .memo: task.memo
    case .status, .priority, .workspace: ""
    }
  }

  /// 下書きからストアへの変更を組む。nil は変更なし（取り消しと同じ）。打っていない下書きは変更なし。
  private func pendingUpdate(_ draft: TaskEditDraft, _ task: TaskItem) -> Result<
    TaskUpdate, TaskPaletteError
  >? {
    guard draft.text != draft.original else { return nil }
    let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
    var update = TaskUpdate()
    switch draft.field {
    case .title:
      guard !trimmed.isEmpty, trimmed != task.title else { return nil }
      update.title = trimmed
    case .waiting:
      if trimmed.isEmpty {
        guard task.waiting != nil else { return nil }
        update.waitingReason = .clear
      } else {
        guard trimmed != task.waiting?.reason else { return nil }
        update.waitingReason = .set(trimmed)
      }
    case .due:
      if trimmed.isEmpty {
        guard task.due != nil else { return nil }
        update.due = .clear
      } else {
        guard let due = TaskDueText.parse(trimmed, today: today) else { return .failure(.due) }
        guard due != task.due else { return nil }
        update.due = .set(due)
      }
    case .memo:
      guard draft.text != task.memo else { return nil }
      update.memo = draft.text
    case .status, .priority, .workspace:
      return nil
    }
    return .success(update)
  }

  private static func error(for field: TaskDetailField) -> TaskPaletteError {
    switch field {
    case .title: .title
    case .waiting: .waiting
    case .due: .due
    case .status, .priority, .workspace, .memo: .failed
    }
  }

  /// 詳細の選択式の項目と「解除」の変更。
  private func apply(_ update: TaskUpdate, field: TaskDetailField) {
    guard let task = selectedTask else { return }
    leaveEditingForAction()
    area = .detail(.field(field))
    mutate(Self.error(for: field)) { () throws(TaskStoreError) in
      _ = try store.update(task.id, update)
    }
  }
}
