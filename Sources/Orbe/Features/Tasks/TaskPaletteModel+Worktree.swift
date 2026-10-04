import Foundation

/// タスクの作業の場所に関わる操作（⌘T でそのタスクのための ⌘T を開く・agent のタブへ移る）。
extension TaskPaletteModel {
  /// タスクの worktree で動いている agent（状態を問わない。詳細の agent の場所と ↵ でタブへ移る先）。
  func agent(of task: TaskItem) -> WorktreeAgentActivity.Agent? {
    task.agent(in: agents.agents)
  }

  /// ⌘T。選んでいるタスクのための ⌘T を開く。追加の行なら足してから開く。編集中なら確定してから選択で
  /// 決める。完了の見出し・GitHub のタブでは何もしない。
  func openWorktreePalette() {
    guard tab == .tasks else { return }
    leaveEditingForAction()
    switch selectedID {
    case .task(let id): onOpenWorktreePalette(id)
    case .add: if let id = addFromQuery() { onOpenWorktreePalette(id) }
    case .doneHeader, nil: break
    }
  }

  /// agent の場所の ↵・クリック。そのタブへ移る（画面は閉じる）。
  func focusAgentTab() {
    guard let task = selectedTask, let agent = agent(of: task) else { return }
    leaveEditingForAction()
    onFocusTab(agent.tabId)
  }
}
