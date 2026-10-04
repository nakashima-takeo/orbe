import Foundation

/// ⌘⇧X タスク画面の提示。画面はタスクのストア（唯一の正）を直接読み書きし、ここは開いた時点の
/// workspace の写しを渡して配線するだけ。
extension WindowController {
  /// タスク画面を開く（開いていれば入力欄へ焦点を戻すだけ）。タブが 0 枚の workspace でも開く。
  func showTaskPalette() {
    if model.overlay == .taskPalette {
      model.taskPalette?.focus()
      return
    }
    let entry = { (ws: Workspace) in TaskPaletteWorkspaces.Entry(id: ws.persistentId, name: ws.name)
    }
    let p = TaskPaletteModel(
      store: taskStore,
      workspaces: TaskPaletteWorkspaces(opened: entry(current), all: workspaces.map(entry)),
      now: Date(), timeZone: .current)
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    model.taskPalette = p
    model.overlay = .taskPalette
    p.focus()
    reconfirmFocusNextTick()  // 別 overlay からの遷移で去りゆくカードの teardown に勝つ
  }

  /// タスク画面で打ちかけの編集を確定する。画面を閉じる・別の画面へ差し替わる・アプリの終了の
  /// どれでも、打った内容を失わない。
  func settleTaskPaletteEditing() {
    model.taskPalette?.leaveEditing()
  }
}
