import Foundation

/// タスクの作業の場所に関わる操作（そのタスクのための agent を開く・agent のタブへ移る）。
extension TaskPaletteModel {
  /// タスクの worktree で動いている agent（状態を問わない。右の欄の agent の場所と ↵ でタブへ移る先）。
  func agent(of task: TaskItem) -> WorktreeAgentActivity.Agent? {
    task.agent(in: agents.agents)
  }

  /// ⌘T。選んでいるタスクのための agent を開く。入力の行き先なら足してから開く。編集中なら確定してから選択で決める。
  /// 完了の見出しでは何もしない。GitHub タブは `openWorktreePaletteFromGitHub`。受信タブでは何もしない。
  func openWorktreePalette() {
    guard pick == nil, visibleTab != .automation else { return }
    guard visibleTab == .tasks else { return openWorktreePaletteFromGitHub() }
    leaveEditingForAction()
    switch selectedID {
    case .task(let id): openAgent(forTask: id)
    case .add: if let id = addFromQuery() { openAgent(forTask: id) }
    case .doneHeader, nil: break
    }
  }

  /// そのタスクのための agent を開く（⌘T・行と右の欄の ⌘↵）。待ちが解けて会話を続きから始められるタスクなら続きから
  /// 始め、そうでなければそのタスクのための ⌘T を開く。完了のタスクでも同じ。選ぶ状態では何もしない。
  func openAgent(forTask id: Int) {
    guard pick == nil else { return }
    leaveEditingForAction()
    if let task = store.tasks.first(where: { $0.id == id }), case .ready = continuation(of: task) {
      error = onContinueWait(id)
    } else {
      onOpenWorktreePalette(id)
    }
  }

  /// agent の場所の ↵・クリック。そのタブへ移る（画面は閉じる）。
  func focusAgentTab() {
    guard let task = selectedTask, let agent = agent(of: task) else { return }
    leaveEditingForAction()
    onFocusTab(agent.tabId)
  }
}
