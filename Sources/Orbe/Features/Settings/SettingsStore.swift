import Foundation

/// 設定の in-memory SSOT（global 層）と書込 gate。起動時に 1 回 load し、以後の読みはメモリ・書きは即 save。
/// `WindowController` が 1 個所有し、パレット・control・AgentLauncher・opacity 系が全てここを読む
/// （散在していた `SettingsPersistence.load()→変異→save()` を廃止）。
/// WS 上書き層の所有は `Workspace.settingsOverride`（WS のライフサイクルと一体）に残す。
final class SettingsStore {
  private(set) var global: SettingsLayer

  init(global: SettingsLayer = SettingsPersistence.loadGlobal()) {
    self.global = global
  }

  /// global 層へ単一代入して即 save（書込 gate はここ 1 箇所）。値検証は `SettingChange` が済ませている前提。
  func applyGlobal(_ change: SettingChange) {
    global.apply(change)
    SettingsPersistence.saveGlobal(global)
  }

  /// global に WS 上書きを重ねた実効設定（override 無しは global そのまま）。
  func effective(override: SettingsLayer?) -> EffectiveSettings {
    EffectiveSettings(override.map { global.overlaid(with: $0) } ?? global)
  }
}
