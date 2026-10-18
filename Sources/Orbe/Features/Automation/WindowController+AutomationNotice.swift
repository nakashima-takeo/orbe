import AppKit

/// 自動化の知らせ。走らせ役が部品の回を記録したことを知らせ、窓がその部品の最新の回から 1 つの知らせに組んで、通知音と、
/// 通知先に応じてメニューバー②か通知センターへ流す。ピルや通知のクリックは Home のボードでその自動化を開く。
extension WindowController {
  /// 部品の回を記録した（走らせ役から）。
  func notifyAutomationRecorded(_ id: Int, _ part: String) {
    guard let notification = automationNotification(id, part) else { return }
    deliver(notification)
  }

  /// 部品の最新の回を知らせとして組む。1 回の記録に知らせは 1 つで、順は「出力が決まりを外した最初の回」→「失敗の続きの最初の
  /// 回」→「Orbe へ何かを渡した回」。自動化が消えている・通知が off・どれにも当たらない・その自動化を見ているときは nil。
  /// 失敗は続く間の最初の回だけ、決まりを外したことは部品の印が無かった回（何をするかが変わるまでに 1 度）だけ知らせる——
  /// 毎回鳴らすと、ピルと音を見なくなるため。外して失敗した回は、外したことの文で失敗も言う。
  ///
  /// 本文は、外した回のほかは実行履歴のその回の行の 1 行目——ピルと、押した先の行を同じ文で語るため。設定は Home の実効設定
  /// （押した先が Home なので、発信元の workspace の値という読み方に揃う）。
  func automationNotification(_ id: Int, _ part: String) -> ChromeNotification? {
    guard let automation = automationStore.automation(id), let notify = automation.notify,
      let state = automation.parts[part], let latest = state.runs.first, !isViewingAutomation(id)
    else { return nil }
    let tone = BoardAutomationSummary.tone(latest)
    let text = board.automation.text(localization, now: automationRunner.now())
    let line: String
    if let breach = state.breach, breach.at == latest.startedAt {
      line = breachLine(breach, part: automation.graph.node(part)?.part.name ?? part)
    } else if tone == .failed, state.runs.dropFirst().first?.failed != true {
      line = BoardAutomationSummary.line(latest, part: part, in: automation, text: text)
    } else if tone == .produced {
      line = BoardAutomationSummary.line(latest, part: part, in: automation, text: text)
    } else {
      return nil
    }
    let home = store.homeIndex.map { workspaces[$0] }
    return ChromeNotification(
      notice: .automation(
        AutomationNotice(
          automationId: id, name: automation.name, text: line, failed: tone == .failed)),
      settings: settingsStore.effective(override: home?.settingsOverride),
      systemNotification: notify == .notificationCenter
        ? SystemNotificationContent(
          identifier: Self.systemNotificationIdentifier(id), title: automation.name, body: line,
          automationId: id)
        : nil)
  }

  /// 「連絡 の出力の形式エラー（2 行）— 出し直して通った」。
  private func breachLine(_ breach: AutomationBreachMark, part name: String) -> String {
    localization.format(
      .automationBreachNotice, name, breach.lines.count,
      localization.string(breach.passed ? .automationBreachPassed : .automationBreachFailed))
  }

  /// 通知センターでの自動化の通知の識別子。自動化ごとに 1 つなので、新しい回が前の通知を差し替える。
  private static func systemNotificationIdentifier(_ id: Int) -> String { "automation.\(id)" }

  /// 定義を書いた（走らせ役から。AI の口でもボードでも通る）。通知先が通知センターなら、書いたその場で OS に許可を問う
  /// （未確認のときだけ）。
  func automationDefined(_ id: Int) {
    guard automationStore.automation(id)?.notify == .notificationCenter else { return }
    systemNotifier.requestAuthorizationIfUndetermined()
  }

  /// 自動化を消した（走らせ役から。どの経路で消しても通る）。その自動化の通知を通知センターから取り下げ、試走を止める。
  func automationDeleted(_ id: Int) {
    systemNotifier.remove(identifier: Self.systemNotificationIdentifier(id))
    automationTrials.discard(id)
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
