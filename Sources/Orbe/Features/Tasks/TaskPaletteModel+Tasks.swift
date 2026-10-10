import Foundation

/// タスクのタブの行の操作（足す・完了 ⇄ 未着手・消す・並べ替え）。変異はストアのメソッドをそのまま呼び、
/// 検証はストアに任せる。選ぶ状態の間は、選ぶこと以外でタスクを変えない。
extension TaskPaletteModel {
  /// 入力のタイトルで未着手のタスクを足し（見ている欄で、その優先度の未着手の先頭 = `addPosition`）、入力を空にして「今足した」
  /// 印を付けて選ぶ。workspace は範囲で決める——「すべて」ならなし、開いた workspace ならその workspace。
  /// 足したタスクの ID を返す。
  @discardableResult func addFromQuery() -> Int? {
    let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard visibleTab == .tasks, !title.isEmpty else { return nil }
    do {
      let item = try store.add(
        TaskDraft(title: title, workspace: addedWorkspace?.id), at: addPosition)
      query = ""
      justAdded = item.id
      taskList.select(.task(item.id), in: selectableIDs)
      return item.id
    } catch {
      self.error = .title
      return nil
    }
  }

  /// 画面から足す位置（入力欄・GitHub タブ・受信）。今の範囲で見ている欄で、その優先度の未着手の先頭。
  var addPosition: TaskStore.AddPosition {
    .priorityHead(workspace: scope == .all ? nil : workspaces.opened.id)
  }

  /// 足すタスクが付く workspace（範囲で決まる）。
  var addedWorkspace: TaskPaletteWorkspaces.Entry? {
    scope == .all ? nil : workspaces.opened
  }

  /// 完了 ⇄ 未着手。選んでいるタスクなら、選択は同一性を捨てて同じ位置の行へ移る（完了の欄が開いて
  /// いても追わない）。選んでいないタスク（行のアイコンのクリック）なら、選択はそのまま動かない。
  func toggleDone(_ id: Int) {
    guard pick == nil else { return }
    leaveEditingForAction()
    guard let task = store.tasks.first(where: { $0.id == id }) else { return reconcile() }
    var update = TaskUpdate()
    update.status = task.status == .done ? .todo : .done
    if selectedID == .task(id) { taskList.forget() }
    mutate(.failed) { () throws(TaskStoreError) in _ = try store.update(id, update) }
  }

  /// 確認なしで消す。選択は同じ位置の行へ移る。
  func delete(_ id: Int) {
    guard pick == nil else { return }
    leaveEditingForAction()
    taskList.forget()
    mutate(.failed) { () throws(TaskStoreError) in try store.delete(id) }
  }

  /// ⌥↑↓。選んだタスクを、同じ欄の見えている隣のタスクと入れ替える。欄の端と完了のタスクでは何もしない。
  func reorder(_ direction: Int) {
    error = nil
    guard pick == nil, askingTaskID == nil, let task = selectedTask,
      let siblings = visibleSiblings(of: task.id),
      let index = siblings.firstIndex(of: task.id), siblings.indices.contains(index + direction)
    else { return }
    place(from: index, to: index + direction, among: siblings)
  }

  /// 同じ欄で一覧に見えている未完了のタスクの ID（一覧の順）。完了のタスクと見えていないタスクは nil。
  func visibleSiblings(of id: Int) -> [Int]? {
    guard let status = store.tasks.first(where: { $0.id == id })?.status, status != .done else {
      return nil
    }
    let siblings = rows.compactMap { row -> Int? in
      guard case .task(let item) = row,
        store.tasks.first(where: { $0.id == item.id })?.status == status
      else { return nil }
      return item.id
    }
    return siblings.contains(id) ? siblings : nil
  }

  /// 見えている兄弟の `from` 番目を `to` 番目へ。下へなら `to` 番目の直後、上へなら直前に入れる（その先の
  /// 隠れたタスクは越えない）。同じ番号ならストアを呼ばない。
  func place(from: Int, to: Int, among siblings: [Int]) {
    guard from != to else { return }
    mutate(.failed) { () throws(TaskStoreError) in
      try store.move(siblings[from], to > from ? .after : .before, siblings[to])
    }
  }

  /// 画面からのストアの変異を呼び、付け直して今見えている一覧の選択へ送る。消えていたタスクは表に出さず
  /// 付け直しに任せる。
  func mutate(_ failure: TaskPaletteError, _ body: () throws(TaskStoreError) -> Void) {
    do throws(TaskStoreError) {
      try body()
    } catch .invalid {
      error = failure
    } catch {
    }
    reconcile()
    switch visibleTab {
    case .tasks: taskList.follow()
    case .github: gitHubList.follow()
    case .intake: break
    }
  }
}
