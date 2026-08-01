import AppKit

/// アップデート UI の提示（トースト層の据え付け・変更内容シート・メニュー導線）。
/// 状態は `UpdateState` が唯一の情報源で、ここは overlay の出し入れと focus 規律だけを担う。
extension WindowController {
  /// アップデートの状態モデル（updaterService が生成・所有する実体への近道）。
  var updateState: UpdateState { updaterService.state }

  /// 起動時の配線（init 末尾から一度だけ）。トースト・状態カードの「変更内容」提示と、
  /// シートを閉じる導線を束ね、起動ゲートを通れば update サイクルを開始する。
  func wireUpdateUI() {
    model.update = updateState
    updateState.onShowChanges = { [weak self] in self?.showUpdateChanges() }
    updateState.onCloseChanges = { [weak self] in self?.dismissUpdateChanges() }
    updaterService.startIfPermitted()
  }

  /// 変更内容シートを開く（トースト・設定の「変更内容」が同じここへ着地する。見本 2b）。
  func showUpdateChanges() {
    guard updateState.ready != nil else { return }
    updateState.dismissToast()  // シートが開けばトーストの役目は済み
    model.overlay = .updateChanges
    updateState.focusChanges()
    reconfirmFocusNextTick()
  }

  /// シートを閉じる。設定パレットから開いていればパレットへ戻し、そうでなければ端末へ返す。
  func dismissUpdateChanges() {
    guard model.overlay == .updateChanges else { return }
    if model.settingsPalette != nil {
      model.overlay = .settingsPalette
      model.settingsPalette?.focus()
    } else {
      model.overlay = .none
      focusActivePane()
    }
    reconfirmFocusNextTick()
  }

  /// App メニュー「更新を確認…」。設定パレットのアップデートセクションを開いて確認を走らせる
  /// （設定の「今すぐ確認」と同一導線。結果は状態カードに現れる）。
  func showUpdateCheck() {
    showSettingsPalette()
    model.settingsPalette?.drillIntoUpdate()
    updateState.onCheckNow()
  }
}
