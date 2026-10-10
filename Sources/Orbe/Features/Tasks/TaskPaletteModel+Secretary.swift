import Foundation

/// 秘書に頼む（⌘↵）。選択の同一性の上に「選んでいるものを秘書に頼む」を足す——入力の行き先なら打った文をそのまま、
/// タスクの行ならその行の直下に頼む欄を開き、欄の ↵ でそのタスクを渡す。頼んだ後も画面は開いたまま。
extension TaskPaletteModel {
  /// 秘書に頼む欄を開いているタスク。
  var askingTaskID: Int? {
    if case .ask(let id) = draft?.target { return id }
    return nil
  }

  /// 入力の行き先が持つタイトル（入力が無い・選ぶ状態なら nil）。
  var addTitle: String? {
    visibleTab == .tasks ? TaskPaletteRows.addTitle(rowsInput) : nil
  }

  /// ⌘↵。選んでいるのが入力の行き先なら打った文を頼み、タスクの行ならその直下に頼む欄を開く。完了の見出し・選ぶ
  /// 状態・GitHub タブでは何もしない。
  func askSecretary() {
    guard pick == nil, visibleTab == .tasks else { return }
    switch selectedID {
    case .add: askWithQuery()
    case .task(let id): openAsk(id)
    case .doneHeader, nil: break
    }
  }

  /// 打った文を頼む。受けたら入力欄を空にする。
  func askWithQuery() {
    guard let title = addTitle else { return }
    leaveEditingForAction()
    deliver(.text(title)) { query = "" }
  }

  /// タスクの行の直下に頼む欄を開く（そのタスクを選び、焦点は欄の補足の入力へ）。
  func openAsk(_ id: Int) {
    guard pick == nil, store.tasks.contains(where: { $0.id == id }) else { return }
    leaveEditingForAction()
    area = .list
    taskList.select(.task(id), in: selectableIDs)
    draft = TaskEditDraft(target: .ask(id), original: "", text: "")
  }

  /// 頼む欄の ↵。補足（空でもよい）を添えてそのタスクを頼み、欄を閉じる。
  func sendAsk() {
    guard let draft, case .ask(let id) = draft.target else { return }
    deliver(.task(id: id, note: draft.text)) { self.draft = nil }
  }

  /// 秘書の係へ渡す。受けたら `accepted` を呼んで、フッターに頼んだことを出す。受けなければ理由を出して、入力も
  /// 欄もそのまま残す。
  private func deliver(_ ask: SecretaryAsk, accepted: () -> Void) {
    switch onAskSecretary(ask) {
    case .success(let acceptance):
      accepted()
      error = nil
      notice = acceptance == .queued ? .askedQueued : .asked
      reconcile()
    case .failure(.claudeMissing):
      error = .secretaryClaude
    case .failure(.nothingToAsk):
      error = .failed
      reconcile()
    }
  }

  /// 行き先の段の右端の言葉（「未着手 · 中の先頭 · <workspace>」）。足すタスクの値（`TaskDraft` の既定の
  /// ステータスと優先度）と、範囲で決まる workspace から出す（位置の「の先頭」は `addPosition` に合わせた文言）。
  func destinationPlace(_ l10n: LocalizationStore) -> String {
    let draft = TaskDraft(title: "")
    let status: L10nKey =
      draft.status == .inProgress ? .taskPaletteSectionInProgress : .taskPaletteSectionTodo
    let priority: L10nKey =
      switch draft.priority {
      case .high: .taskPalettePriorityHigh
      case .medium: .taskPalettePriorityMedium
      case .low: .taskPalettePriorityLow
      }
    return l10n.format(
      .taskPaletteDestinationPlace, l10n.string(status), l10n.string(priority),
      addedWorkspace?.name ?? l10n.string(.taskPaletteDestinationNoWorkspace))
  }
}
