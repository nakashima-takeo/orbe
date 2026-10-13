import AppKit

/// 自動化の知らせ。走らせ役が回を記録したことを知らせ、窓がその自動化の定義と最新の回から 1 つの知らせに組んで、agent の
/// 通知と同じ 2 面（メニューバー②・通知音）へ流す。ピルのクリックは Home のボードでその自動化を開く。
extension WindowController {
  /// 回を記録した（走らせ役から）。
  func notifyAutomationRecorded(_ id: Int) {
    guard let notification = automationNotification(id) else { return }
    deliver(notification)
  }

  /// 最新の回を知らせとして組む。自動化が消えている・通知が off・最新の回が何も出さなかった・その行を見ているときは nil。
  ///
  /// 本文はボードの実行履歴の最新の行の 1 行目——ピルと、押した先の行を同じ文で語るため。設定は Home の実効設定（押した先が
  /// Home なので、発信元の workspace の値という読み方に揃う）。
  func automationNotification(_ id: Int) -> ChromeNotification? {
    guard let automation = automationStore.automation(id), let latest = automation.runs.first,
      !isViewingAutomation(id)
    else { return nil }
    switch automation.definition.notify {
    case .menuBar: break
    case nil: return nil
    }
    let tone = BoardAutomationSummary.tone(latest)
    guard tone != .quiet else { return nil }
    let text = board.automation.text(localization, now: automationRunner.now())
    guard let line = BoardAutomationSummary(automation, text: text).latestLine else { return nil }
    let home = store.homeIndex.map { workspaces[$0] }
    return ChromeNotification(
      notice: .automation(
        AutomationNotice(
          automationId: id, name: automation.definition.name, text: line,
          failed: tone == .failed)),
      settings: settingsStore.effective(override: home?.settingsOverride))
  }

  /// その自動化を見ている——窓がキーで、パレットが無く、Home のボードでその自動化の行を選んでいる。一覧に行が見えているだけ
  /// では入れない（選んでいるときだけ、詳細に回の結果がその場で現れる）。
  func isViewingAutomation(_ id: Int) -> Bool {
    guard window.isKeyWindow, model.overlay == .none, store.isHome(activeWorkspace),
      current.selection == .board
    else { return false }
    return board.selects(automation: id)
  }

  /// Home のボードでその自動化を開く（ピルのクリック）。差し替えてはならない画面の間は何もしない。行き先はボードそのもの
  /// なので、ほかのパレットは閉じる。自動化が消えていれば欄を、自動化の部品が無ければボードを開くだけ。
  func showAutomation(_ id: Int) {
    guard !model.overlay.isModal, let home = store.homeIndex else { return }
    if model.overlay != .none { dismissPalette() }
    if activeWorkspace != home { switchWorkspace(to: home) }
    select(.board)
    board.open(automation: id)
  }
}
