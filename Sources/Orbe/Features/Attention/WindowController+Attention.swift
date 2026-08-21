import AppKit

/// Attention パレットの提示と、Attention snapshot（単一情報源 `AttentionStore`）の流し込み。
/// WindowController 本体から Attention の関心を分離する。
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

  /// メニューバー②（一過性の滲み出しピル）を立てる。ただし発信元ペインが**見ているタブ**に
  /// あるときは立てない——端末にその結果もプロンプトも出ている面で、注意だけを二重に奪わないため。
  /// 抑制は「立てない」だけで、既に出ているピル（別の場所で起きた変化の通知）には触らない。
  func noteAttentionTransient(for pane: SurfaceView) {
    // 抑制するのは「見ているタブが実在し、かつペインがそのタブに属する」ときだけ。visibleTab が
    // nil＝背面なら誰も見ていないので必ず立てる（controller は weak。nil 同士を一致と読ませない）。
    if let visibleTab, pane.controller === visibleTab { return }
    guard let row = attentionRow(for: pane) else { return }
    attentionStore.noteTransient(row)
  }

  /// 一過性表示（メニューバー②）用の 1 行 snapshot。発信元ペインの所属 WS・タブから組む。
  /// 対象は一覧（`AttentionSnapshot.rows`）と同じ **activatedタブのライブペインのみ**
  /// ——②は一覧の投影なので、立てる側と取り下げる側が同じ集合を見る。見つからなければ nil。
  private func attentionRow(for pane: SurfaceView) -> AttentionRow? {
    for ws in workspaces {
      for tab in ws.tabs
      where tab.activated && tab.controlAllPanes().contains(where: { $0 === pane }) {
        guard let report = pane.agentReport else { return nil }
        return AttentionRow(
          paneId: pane.id,
          workspaceName: ws.name,
          tabTitle: tab.displayTitle(workspaceRoot: ws.rootPath),
          state: report.state,
          message: report.state == "working" ? nil : report.message?.text,
          stateChangedAt: report.stateChangedAt)
      }
    }
    return nil
  }
}
