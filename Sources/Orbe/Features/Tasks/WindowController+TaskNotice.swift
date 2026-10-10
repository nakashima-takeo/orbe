import AppKit

/// タスク由来の知らせ。待ちの条件の係が解けたことを知らせ、窓がそれを 1 つの知らせに組んで
/// agent の通知と同じ 2 面（メニューバー②・通知音）へ流す。ピルのクリックは ⌘⇧X でそのタスクを選んで開く。
extension WindowController {
  /// 待ちの条件が解けた（係から）。
  func notifyWaitResolved(task id: Int, _ resolution: WaitResolution) {
    guard let notification = taskNotification(task: id, resolution) else { return }
    deliver(notification)
  }

  /// 解けたタスク 1 件を知らせとして組む。タスクが消えている・そのタスクを見ているときは nil。
  ///
  /// 本文は「#214 レビューが付いた」——主の結び付きの番号（無ければタイトル）と起きたこと。
  func taskNotification(task id: Int, _ resolution: WaitResolution) -> ChromeNotification? {
    guard let task = taskStore.tasks.first(where: { $0.id == id }), !isViewingTask(id) else {
      return nil
    }
    let ws = task.workspace.flatMap { wsId in workspaces.first { $0.persistentId == wsId } }
    let subject = task.links.first.map { "#\($0.item.number)" } ?? task.title
    let text = subject + " " + TaskWaitText.headline(resolution.headline, l10n: localization)
    return ChromeNotification(
      notice: .task(TaskNotice(taskId: id, workspaceName: ws?.name, text: text)),
      settings: settingsStore.effective(override: ws?.settingsOverride))
  }

  /// そのタスクを見ている——窓がキーで、⌘⇧X のタスクのタブでそのタスクを選んでいる。一覧に行が
  /// 見えているだけでは入れない（選んでいるときだけ、詳細欄に起きたことがその場で現れる）。
  func isViewingTask(_ id: Int) -> Bool {
    guard window.isKeyWindow, model.overlay == .taskPalette, let palette = model.taskPalette
    else { return false }
    return palette.visibleTab == .tasks && palette.selectedID == .task(id)
  }

  /// ⌘⇧X を開いてそのタスクを選ぶ（ピルのクリック）。差し替えてはならない画面の間は何もしない。
  /// 絞り込み・範囲・畳んだ完了の欄で隠れていても見えるようにする。タスクが消えていれば開くだけ。
  func showTaskPalette(selecting id: Int) {
    guard !model.overlay.isModal else { return }
    showTaskPalette()
    model.taskPalette?.showTask(id)
  }
}
