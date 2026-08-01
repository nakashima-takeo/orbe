import AppKit

/// アクティブ workspace の実効設定（global 層 → workspace 上書き層）を反映する集約点。
/// workspace 切替・設定パレット適用・起動復元の 3 点がここを共有して呼ぶ。
extension WindowController {
  /// global 層にアクティブ workspace の上書き層を重ねた実効設定。
  /// workspaces 未構築（init 途中の初回 `syncWindowOpacity`）は global をそのまま返す。
  func activeEffectiveSettings() -> EffectiveSettings {
    guard workspaces.indices.contains(activeWorkspace) else {
      return settingsStore.effective(override: nil)
    }
    return settingsStore.effective(override: current.settingsOverride)
  }

  /// アクティブ workspace の実効設定で外観（テーマ）・状態アイコン・gui.conf・右バー gate を反映し、
  /// ライブ反映（reloadConfig + 窓透過）を予約する。画面に載るのは常にアクティブ 1 workspace のみなので
  /// 全 surface 一律適用で常に正しい。
  func applyActiveWorkspaceConfig() {
    let settings = activeEffectiveSettings()
    // 状態アイコン上書きを chrome 3 面へ配る（gui.conf 非経由・env 直配信）。
    agentIconResolver.symbols = AgentStateIcon.decode(settings[SettingKeys.agentStateIcons])
    // フォント割り当て（絵文字 Noto/Apple・タブタイトルフォント）を chrome 全面へ配る（env 直配信）。
    // 端末セル側の絵文字は下の gui.conf 再生成（font-codepoint-map）→ reloadConfig が同時に反映する。
    fontResolver.emojiFont =
      settings[SettingKeys.emojiFont] == .noto ? TitleGlyphs.notoEmoji : nil
    // タブタイトルフォントは family 名を 11pt で厳密解決し、未設定・解決不能名は既定へ退避する。
    fontResolver.tabTitleFont =
      settings[SettingKeys.tabTitleFontFamily]
      .flatMap { FontCatalog.resolve(family: $0, size: Theme.Typography.chrome.pointSize) }
      ?? Theme.Typography.chrome
    // テーマ（外観スイッチ）。chrome は動的トークンが、ターミナルは既存配線が追従する。
    NSApp.appearance = settings[SettingKeys.theme].appearance
    // 開発中の機能 gate を実効値へ再評価（WS 切替で右バーが WS 毎に追従する）。
    devFeaturesEnabled = settings[SettingKeys.devFeaturesEnabled]
    projectEditorDisplayState()
    GuiConfig.regenerate(from: settings)
    scheduleConfigReload()
  }
}
