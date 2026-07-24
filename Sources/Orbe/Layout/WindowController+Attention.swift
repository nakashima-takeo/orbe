import AppKit

/// Attention パレットの提示と、Attention snapshot（単一情報源 `AttentionStore`）の流し込み。
/// WindowController 本体から Attention の関心を分離する。
extension WindowController {
  /// `flushChrome` から呼ぶ snapshot 更新（既存 coalesce に相乗り。新たな走査タイミングは作らない）。
  /// パレット表示中は開いたまま行を追従させる（`reloadPalette` と同じ流儀）。
  func refreshAttentionSnapshot() {
    attentionStore.rows = AttentionSnapshot.rows(of: workspaces)
    if model.overlay == .attentionPalette {
      model.attentionPalette?.setRows(attentionStore.rows)
    }
  }

  /// ⌘⌘（前面時）のトグル。開いていれば閉じ、他パレット表示中は差し替える（既存パレット同士の
  /// 遷移規約）。languageSelect / onboarding / updateChanges の真のモーダル中は no-op。
  func toggleAttentionPalette() {
    switch model.overlay {
    case .attentionPalette:
      dismissPalette()
    case .languageSelect, .onboarding, .updateChanges:
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

  /// 一過性表示（メニューバー②）用の 1 行 snapshot。発信元ペインの所属 WS・タブから組む。
  /// 休眠 WS のペインは report が届かないため実質常に解決するが、見つからなければ nil。
  func attentionRow(for pane: SurfaceView) -> AttentionRow? {
    for ws in workspaces {
      for tab in ws.tabs where tab.controlAllPanes().contains(where: { $0 === pane }) {
        guard let state = pane.agentState else { return nil }
        return AttentionRow(
          paneId: pane.id,
          workspaceName: ws.name,
          tabTitle: tab.displayTitle(workspaceRoot: ws.rootPath),
          state: state,
          message: state == "working" ? nil : pane.agentMessage,
          stateChangedAt: pane.agentStateChangedAt ?? Date())
      }
    }
    return nil
  }
}
