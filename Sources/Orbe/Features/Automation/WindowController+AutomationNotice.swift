import AppKit

/// 自動化の知らせ。走らせ役が回を記録したことを知らせ、窓がその自動化の定義と最新の回から 1 つの知らせに組んで、通知音と、
/// 通知先に応じてメニューバー②か通知センターへ流す。ピルや通知のクリックは Home のボードでその自動化を開く。
extension WindowController {
  /// 回を記録した（走らせ役から）。
  func notifyAutomationRecorded(_ id: Int) {
    guard let notification = automationNotification(id) else { return }
    deliver(notification)
  }

  /// 最新の回を知らせとして組む。自動化が消えている・通知が off・最新の回が何も出さなかった・前の回に続く失敗・その行を
  /// 見ているときは nil。失敗は続く間の最初の回だけ知らせる——直るまで毎回鳴らすと、ピルと音を見なくなるため。
  ///
  /// 本文はボードの実行履歴の最新の行の 1 行目——ピルと、押した先の行を同じ文で語るため。設定は Home の実効設定（押した先が
  /// Home なので、発信元の workspace の値という読み方に揃う）。
  func automationNotification(_ id: Int) -> ChromeNotification? {
    guard let automation = automationStore.automation(id), let latest = automation.runs.first,
      !isViewingAutomation(id)
    else { return nil }
    guard let notify = automation.definition.notify else { return nil }
    let tone = BoardAutomationSummary.tone(latest)
    guard tone != .quiet else { return nil }
    let previous = automation.runs.dropFirst().first.map(BoardAutomationSummary.tone)
    guard tone != .failed || previous != .failed else { return nil }
    let text = board.automation.text(localization, now: automationRunner.now())
    guard let line = BoardAutomationSummary(automation, text: text).latestLine else { return nil }
    let home = store.homeIndex.map { workspaces[$0] }
    let name = automation.definition.name
    return ChromeNotification(
      notice: .automation(
        AutomationNotice(automationId: id, name: name, text: line, failed: tone == .failed)),
      settings: settingsStore.effective(override: home?.settingsOverride),
      systemNotification: notify == .notificationCenter
        ? SystemNotificationContent(
          identifier: Self.systemNotificationIdentifier(id), title: name, body: line,
          automationId: id)
        : nil)
  }

  /// 通知センターでの自動化の通知の識別子。自動化ごとに 1 つなので、新しい回が前の通知を差し替える。
  private static func systemNotificationIdentifier(_ id: Int) -> String { "automation.\(id)" }

  /// 定義を書いた直後。通知先が通知センターなら、頼んだその場で OS に許可を問う（未確認のときだけ）。
  func automationDefinitionSet(_ definition: AutomationDefinition) {
    guard definition.notify == .notificationCenter else { return }
    systemNotifier.requestAuthorizationIfUndetermined()
  }

  /// 自動化を消した直後。その自動化の通知を通知センターから取り下げる。
  func automationDeleted(_ id: Int) {
    systemNotifier.remove(identifier: Self.systemNotificationIdentifier(id))
  }

  /// 通知センターの通知のクリック。ピルのクリックと同じく、前面化してから Home のボードでその自動化を開く。
  func openAutomationFromSystemNotification(_ id: Int) {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    showAutomation(id)
  }

  /// その自動化を見ている——窓がキーで、パレットが無く、Home のボードでその自動化の行を選んでいる。一覧に行が見えているだけ
  /// では入れない（選んでいるときだけ、詳細に回の結果がその場で現れる）。
  func isViewingAutomation(_ id: Int) -> Bool {
    guard window.isKeyWindow, model.overlay == .none, store.isHome(activeWorkspace),
      current.selection == .board
    else { return false }
    return board.selects(automation: id)
  }

  /// Home のボードでその自動化を開く（ピル・通知のクリック）。差し替えてはならない画面の間は何もしない。行き先はボードそのもの
  /// なので、ほかのパレットは閉じる。自動化が消えていれば欄を、自動化の部品が無ければボードを開くだけ。
  func showAutomation(_ id: Int) {
    guard !model.overlay.isModal, let home = store.homeIndex else { return }
    if model.overlay != .none { dismissPalette() }
    if activeWorkspace != home { switchWorkspace(to: home) }
    select(.board)
    board.open(automation: id)
  }
}
