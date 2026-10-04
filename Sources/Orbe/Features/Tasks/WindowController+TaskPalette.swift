import AppKit

/// ⌘⇧X タスク画面の提示。画面はタスクのストア（唯一の正）を直接読み書きし、ここは開いた時点の
/// workspace の写しと GitHub の値の置き場を渡して配線するだけ。
extension WindowController {
  /// タスク画面を開く（開いていれば焦点をモデルが決めた行き先へ当て直すだけ）。タブが 0 枚の workspace でも開く。
  func showTaskPalette() {
    if model.overlay == .taskPalette {
      model.taskPalette?.focus()
      return
    }
    let entry = { (ws: Workspace) in
      TaskPaletteWorkspaces.Entry(id: ws.persistentId, name: ws.name)
    }
    let p = TaskPaletteModel(
      store: taskStore, githubItems: .shared, agents: worktreeAgents,
      workspaces: TaskPaletteWorkspaces(opened: entry(current), all: workspaces.map(entry)),
      now: Date(), timeZone: .current)
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    p.onOpenURL = { NSWorkspace.shared.open($0) }
    p.onOpenWorktreePalette = { [weak self] id in self?.openWorktreePalette(forTask: id) }
    p.onFocusTab = { [weak self] tabId in
      self?.dismissPalette()
      _ = self?.controlFocusTab(tabId: tabId)
    }
    model.taskPalette = p
    model.overlay = .taskPalette
    p.focus()
    reconfirmFocusNextTick()  // 別 overlay からの遷移で去りゆくカードの teardown に勝つ
  }

  /// タスク画面の ⌘T。タスク画面を確定して畳み、そのタスクのための ⌘T に差し替える。
  func openWorktreePalette(forTask id: Int) {
    settleTaskPaletteEditing()
    model.taskPalette = nil
    showWorktreePalette(task: id)
  }

  /// タスク画面で打ちかけの編集を確定する。画面を閉じる・別の画面へ差し替わる・アプリの終了の
  /// どれでも、打った内容を失わない。
  func settleTaskPaletteEditing() {
    model.taskPalette?.leaveEditing()
  }
}
