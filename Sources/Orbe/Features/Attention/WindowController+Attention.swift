import AppKit
import OrbeSound

/// Attention パレットの提示と、Attention snapshot（単一情報源 `AttentionStore`）の流し込み。
/// 加えて、知らせ 1 件（`ChromeNotification`）をメニューバー②と通知音の 2 面へ流す口と、
/// 見ていないタブの状態変化をその 1 件として成立させる入口を持つ。
extension WindowController {
  /// `flushChrome` から呼ぶ snapshot 更新（既存 coalesce に相乗り。新たな走査タイミングは作らない）。
  /// パレット表示中は開いたまま行を追従させる（`reloadPalette` と同じ流儀）。
  func refreshAttentionSnapshot() {
    attentionStore.apply(rows: AttentionSnapshot.rows(of: workspaces))
    if model.overlay == .attentionPalette {
      model.attentionPalette?.setRows(attentionStore.rows)
    }
  }

  /// ⌘⌘（前面時）のトグル。開いていれば閉じ、他パレット表示中は差し替える（既存パレット同士の
  /// 遷移規約）。差し替えてはならない画面（`Overlay.isModal`）の間は no-op。
  /// ヘルプ（⌘H）表示中も no-op——ヘルプはショートカットを試し押しして確かめる場で、押下は
  /// キーボード点灯と行ハイライトにのみ使う（実動作するのは ⌘H と esc だけ）。ヘルプに載る
  /// ⌘⌘ はそこで必ず試されるため、この規律から外すと試し押しでヘルプ自体が消える。
  func toggleAttentionPalette() {
    guard !model.overlay.isModal, model.overlay != .help else { return }
    switch model.overlay {
    case .attentionPalette:
      dismissPalette()
    case .taskPalette:
      // タスク画面は畳まずに差し替わるので、打ちかけの編集をここで確定する。
      settleTaskPaletteEditing()
      showAttentionPalette()
    default:
      showAttentionPalette()
    }
  }

  /// Attention パレットを開く（TopBar ストリップのクリック・⌘⌘）。既に開いていれば再フォーカス。
  func showAttentionPalette() {
    if model.overlay == .attentionPalette {
      model.attentionPalette?.focus()
      return
    }
    let p = AttentionPaletteModel(localization: localization)
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    p.onFocusTab = { [weak self] tabId in
      guard let self else { return }
      _ = self.controlFocusTab(tabId: tabId)  // WS activate＋タブ選択＋surface focus（既存経路を共用）
      self.dismissPalette()  // done のフォーカス消費は select() 経由で既存規律どおり効く
    }
    p.setRows(attentionStore.rows)
    model.attentionPalette = p
    model.overlay = .attentionPalette
    p.focus()
    reconfirmFocusNextTick()  // 別 overlay からの遷移で去りゆくカードの teardown に勝つ
  }

  /// メニューバー②のクリック直行・行クリックが使う「そのタブへ移動」（前面化は呼び出し側）。差し替えてはならない
  /// 画面の間は何もしない（焦点だけが裏の端末へ移り、画面に向けたキーが agent に届く）。
  func focusAttentionTab(tabId: Int) {
    guard !model.overlay.isModal else { return }
    _ = controlFocusTab(tabId: tabId)
  }

  /// 知らせ 1 件をメニューバー②と通知音の 2 面へ流す。成立条件（見ているか・所属）は知らせを組む側が
  /// 1 回だけ解き、面ごとに判断しない。②の滞留は知らせが持つ発信元 workspace の実効設定
  /// （`menubar-notification-duration`）から決まり、その到来が終わるまで動かない——設定を変えても
  /// 今出ているピルには効かず、次の到来から効く。
  func deliver(_ notification: ChromeNotification) {
    attentionStore.noteTransient(
      notification.notice,
      dwell: TimeInterval(notification.settings[SettingKeys.menuBarNotificationDuration]))
    playNotificationSound(notification)
  }

  /// 知らせ 1 件の文脈。メニューバー②と通知音は、この 1 つを投影する 2 つの面。
  struct ChromeNotification {
    let notice: MenuBarNotice
    /// 発信元（タブ・タスク）が属する workspace の実効設定。workspace 上書き（「この workspace で起きた
    /// 変化の通知はこう」）が意味を持つのはこの読み方だけ——見ている workspace の値ではない。
    /// workspace の無いタスクは全体の設定。
    let settings: EffectiveSettings

    /// 鳴らす音。agent は状態から、タスクの知らせは完了の音。
    var soundEvent: AgentSoundEvent? {
      switch notice {
      case .agent(let row): AgentSoundEvent(rawValue: row.state)
      case .task: .done
      }
    }
  }

  /// 状態変化 1 件を通知として成立させる（成立しなければ nil＝どの面も何もしない）。
  ///
  /// 成立しないのは 2 つ。**見ているタブ**——端末にその結果もプロンプトも出ている面で、
  /// 注意を二重に奪わないため。もう 1 つは**未activatedタブ**——対象は一覧と同じ activatedタブの
  /// ライブスロットのみで、一覧にもピルにも出ない通知だけが届くとユーザは出所を辿れない。
  func agentNotification(for tab: TerminalTab) -> ChromeNotification? {
    // 抑制するのは「見ているタブが実在し、かつそのタブ」のときだけ。visibleTab が
    // nil＝背面なら誰も見ていないので必ず成立する。
    if let visibleTab, tab === visibleTab { return nil }
    guard tab.activated, let report = tab.agentReport,
      let ws = workspaces.first(where: { ws in ws.tabs.contains { $0 === tab } })
    else { return nil }
    let row = AttentionRow(
      tabId: tab.id,
      workspaceName: ws.name,
      tabTitle: tab.displayTitle(workspaceRoot: ws.rootPath),
      state: report.state,
      message: report.state == "working" ? nil : report.message?.text,
      stateChangedAt: report.stateChangedAt)
    return ChromeNotification(
      notice: .agent(row), settings: settingsStore.effective(override: ws.settingsOverride))
  }
}
