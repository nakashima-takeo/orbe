import Foundation

/// Attention（パレット・メニューバー投影・グローバル ⌘⌘ の権限）ドメインの文言分冊。
/// 本体 `L10n.table` が結合する。
extension L10n {
  static let attentionTable: [L10nKey: (ja: String, en: String)] = [
    .attentionHintJump: ("そのペインへ移動", "Jump to pane"),
    .attentionHintSelect: ("選択", "Select"),
    .attentionHintClose: ("閉じる", "Close"),
    .attentionEmpty: ("対応するものはありません", "Nothing needs your attention"),
    .menubarClickToPane: ("クリックでそのペインへ", "Click to jump to the pane"),
    .menubarOpenOrbe: ("orbe を開く", "Open orbe"),
    .menubarPermissionHint: (
      "背面からの ⌘⌘ はアクセシビリティ許可で使えます — クリックで設定へ",
      "⌘⌘ from the background needs Accessibility permission — click to open settings"
    ),
    .settingsGlobalCmdTapLabel: ("グローバル ⌘⌘（メニューバー）", "Global ⌘⌘ (menu bar)"),
    .settingsGlobalCmdTapGranted: ("有効", "Enabled"),
    .settingsGlobalCmdTapDenied: (
      "未許可 — ↵ で System Settings を開く", "Not granted — ↵ opens System Settings"
    ),
    .settingsGlobalCmdTapRestartNote: (
      "付与後に反映されない場合は Orbe を再起動", "Restart Orbe if it doesn't take effect after granting"
    ),
  ]
}
