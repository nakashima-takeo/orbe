import Foundation

/// Help（⌘H チートシート）ドメインの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let helpTable: [L10nKey: (ja: String, en: String)] = [
    .helpSearchPlaceholder: ("ショートカットを検索…", "Search shortcuts…"),
    .helpHitCountOne: ("%lld 件", "%lld match"),
    .helpHitCountOther: ("%lld 件", "%lld matches"),
    .helpCatBasics: ("基本操作", "Basics"),
    .helpCatAllShortcuts: ("すべて", "All"),
    .helpCatGeneral: ("全般", "General"),
    .helpCatWorkspaceTabs: ("ワークスペース・タブ", "Workspaces & Tabs"),
    .helpCatAgents: ("エージェント", "Agents"),
    .helpCatTerminal: ("ターミナル", "Terminal"),
    .helpTopSubtitle: (
      "全ショートカットは検索または左のカテゴリから", "Search or pick a category on the left for all shortcuts"
    ),
    .helpLegendTitle: ("エージェントステータス", "Agent status"),
    .helpLegendWorking: ("作業中", "Working"),
    .helpLegendWaiting: ("入力・確認待ち", "Waiting for input"),
    .helpLegendDone: ("完了", "Finished"),
    .helpLegendIdle: ("しばらく動きなし", "No recent activity"),
    .helpKeyFilterChip: ("%@ を含む", "Contains %@"),
    .helpKeyboardCaption: (
      "行にホバー / 実際にキーを押すと光る · キーをクリックでそのキーを含むものだけに絞り込み",
      "Hover a row or press keys to light them up · click a key to filter by it"
    ),
    .helpFooterType: ("そのままタイプで検索", "Just type to search"),
    .helpFooterEscClose: ("閉じる", "close"),
    .helpShortcutHelp: ("ヘルプ / チートシート", "Help / cheat sheet"),
    .helpShortcutSettings: ("設定を開く", "Open settings"),
    .helpShortcutOpenEditor: ("cwd を GUI エディタで開く", "Open cwd in GUI editor"),
    .helpShortcutQuit: ("Orbe を終了", "Quit Orbe"),
    .helpShortcutSwitchWorkspace: ("ワークスペース切替", "Switch workspace"),
    .helpShortcutNewWorkspace: ("新規ワークスペース", "New workspace"),
    .helpShortcutNewTab: ("新しいタブ", "New tab"),
    .helpShortcutReopenClosedAgentTab: (
      "最後に閉じたエージェントタブを開き直す", "Reopen last closed agent tab"
    ),
    .helpShortcutRenameTab: ("タブをリネーム", "Rename tab"),
    .helpShortcutNextTab: ("次のタブへ", "Next tab"),
    .helpShortcutPrevTab: ("前のタブへ", "Previous tab"),
    .helpShortcutCloseTab: ("タブを閉じる", "Close tab"),
    .helpShortcutLaunchDefaultAgent: ("デフォルトエージェントを起動", "Launch default agent"),
    .helpShortcutAgentPalette: ("エージェント起動パレット", "Agent launch palette"),
    .helpShortcutDispatchPalette: (
      "Dispatch パレット（worktree/branch/issue/PR から起動）",
      "Dispatch palette (launch from worktree/branch/issue/PR)"
    ),
    // 「⌘ を 2 回」はキー表記 ⌘⌘ が語るのでラベルからは落とす（トップ厳選の 1 行に収める）。
    .helpShortcutAttentionPalette: (
      "Attention パレット（要対応のタブ）", "Attention palette (tabs needing you)"
    ),
    .helpShortcutFind: ("スクロールバック検索", "Search scrollback"),
    .helpShortcutScrollTop: ("スクロールバック先頭へ", "Jump to scrollback top"),
    .helpShortcutScrollBottom: ("スクロールバック末尾へ", "Jump to scrollback bottom"),
    .helpShortcutCopy: ("コピー（選択範囲）", "Copy selection"),
    .helpShortcutPaste: ("ペースト", "Paste"),
    .helpShortcutFontLarger: ("文字を大きく", "Increase font size"),
    .helpShortcutFontSmaller: ("文字を小さく", "Decrease font size"),
    .helpShortcutFontReset: ("文字サイズをリセット", "Reset font size"),
  ]
}
