import AppKit

/// Attention パレットの提示と、Attention snapshot（単一情報源 `AttentionStore`）の流し込み。
/// 加えて、見ていないペインの状態変化 1 件を通知（`AgentNotification`）として成立させる入口を持つ
/// ——メニューバー②と通知音はその 1 件を投影するだけの面で、成立条件も読む設定も面ごとに判断しない。
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
  /// 遷移規約）。languageSelect / onboarding / updateChanges の真のモーダル中は no-op。
  /// ヘルプ（⌘H）表示中も no-op——ヘルプはショートカットを試し押しして確かめる場で、押下は
  /// キーボード点灯と行ハイライトにのみ使う（実動作するのは ⌘H と esc だけ）。ヘルプに載る
  /// ⌘⌘ はそこで必ず試されるため、この規律から外すと試し押しでヘルプ自体が消える。
  func toggleAttentionPalette() {
    switch model.overlay {
    case .attentionPalette:
      dismissPalette()
    case .languageSelect, .onboarding, .updateChanges, .help:
      return
    case .none, .workspacePalette, .workspaceCreate, .agentPalette, .dispatchPalette,
      .settingsPalette:
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
    p.onFocusPane = { [weak self] paneId in
      guard let self else { return }
      _ = self.controlFocusPane(paneId: paneId)  // WS activate＋タブ選択＋ペイン focus（既存経路を共用）
      self.dismissPalette()  // done のフォーカス消費は select() 経由で既存規律どおり効く
    }
    p.setRows(attentionStore.rows)
    model.attentionPalette = p
    model.overlay = .attentionPalette
    p.focus()
    reconfirmFocusNextTick()  // 別 overlay からの遷移で去りゆくカードの teardown に勝つ
  }

  /// メニューバー②のクリック直行・行クリックが使う「そのペインへ移動」（前面化は呼び出し側）。
  func focusAttentionPane(paneId: Int) {
    _ = controlFocusPane(paneId: paneId)
  }

  /// メニューバー②（一過性の滲み出しピル）を立てる。滞留は通知が持つ発信元 workspace の
  /// 実効設定（`menubar-notification-duration`）から決まり、その到来が終わるまで動かない
  /// ——設定を変えても今出ているピルには効かず、次の到来から効く。
  func noteAttentionTransient(_ notification: AgentNotification) {
    attentionStore.noteTransient(
      notification.row,
      dwell: TimeInterval(notification.settings[SettingKeys.menuBarNotificationDuration]))
  }

  /// 「見ていないペインで起きた状態変化」1 件の文脈。メニューバー②と通知音は、この 1 つの通知を
  /// 投影する 2 つの面で、成立条件（抑制・所属）も読む設定も面ごとに判断しない。
  struct AgentNotification {
    /// 発信元ペインの行（一覧＝`AttentionSnapshot.rows` と同じ組み立て）。
    let row: AttentionRow
    /// 発信元ペインが属する workspace の実効設定。workspace 上書き（「この workspace で起きた
    /// 変化の通知はこう」）が意味を持つのはこの読み方だけ——見ている workspace の値ではない。
    let settings: EffectiveSettings
  }

  /// 状態変化 1 件を通知として成立させる（成立しなければ nil＝どの面も何もしない）。
  ///
  /// 成立しないのは 2 つ。**見ているタブ**のペイン——端末にその結果もプロンプトも出ている面で、
  /// 注意を二重に奪わないため。もう 1 つは**所属が引けない**ペイン（未activatedタブ）——対象は
  /// 一覧と同じ activatedタブのライブペインのみで、一覧にもピルにも出ない通知だけが届くと
  /// ユーザは出所を辿れない。
  func agentNotification(for pane: SurfaceView) -> AgentNotification? {
    // 抑制するのは「見ているタブが実在し、かつペインがそのタブに属する」ときだけ。visibleTab が
    // nil＝背面なら誰も見ていないので必ず成立する（controller は weak。nil 同士を一致と読ませない）。
    if let visibleTab, pane.controller === visibleTab { return nil }
    for ws in workspaces {
      for tab in ws.tabs
      where tab.activated && tab.controlAllPanes().contains(where: { $0 === pane }) {
        guard let report = pane.agentReport else { return nil }
        let row = AttentionRow(
          paneId: pane.id,
          workspaceName: ws.name,
          tabTitle: tab.displayTitle(workspaceRoot: ws.rootPath),
          state: report.state,
          message: report.state == "working" ? nil : report.message?.text,
          stateChangedAt: report.stateChangedAt)
        return AgentNotification(
          row: row, settings: settingsStore.effective(override: ws.settingsOverride))
      }
    }
    return nil
  }
}
