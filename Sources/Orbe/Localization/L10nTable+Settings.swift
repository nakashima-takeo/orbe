import Foundation

/// Settings（⌘, パレット・レジストリのラベル）ドメインの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let settingsTable: [L10nKey: (ja: String, en: String)] = [
    // MARK: Settings パレット
    .settingsScopeGlobal: ("グローバル", "Global"),
    .settingsScopeWorkspace: ("この workspace", "This workspace"),
    .settingsScopeWord: ("スコープ", "Scope"),
    .settingsInheritGlobal: ("グローバルを継承（%@）", "Inherit global (%@)"),
    .settingsWorkspaceOverrideNote: ("（この WS では %@）", "(this workspace: %@)"),
    .settingsInheritedNote: ("（継承）", "(inherited)"),
    .settingsFilterPlaceholder: ("設定を絞り込み", "Filter settings"),
    .settingsRootHintWorkspace: (
      "↵/→ 開く   ←→ 増減/切替   delete 継承へ戻す   esc 閉じる",
      "↵/→ Open   ←→ Adjust/Toggle   delete Reset to inherited   esc Close"
    ),
    .settingsRootHintGlobal: (
      "↵/→ 開く   ←→ 増減/切替   esc 閉じる", "↵/→ Open   ←→ Adjust/Toggle   esc Close"
    ),
    .settingsNoMatch: ("一致する設定がありません", "No matching settings"),
    .settingsThemeBreadcrumb: ("‹ テーマ", "‹ Theme"),
    .settingsAgentBreadcrumb: ("‹ デフォルトエージェント", "‹ Default agent"),
    .settingsFontBreadcrumb: ("‹ フォント", "‹ Font"),
    .settingsFontFilterPlaceholder: ("フォントを絞り込み", "Filter fonts"),
    .settingsFontHint: ("↵ 適用   ←/esc 戻る", "↵ Apply   ←/esc Back"),
    .settingsNoFonts: ("フォントが見つかりません", "No fonts found"),
    .settingsNoMatchingFonts: ("一致するフォントがありません", "No matching fonts"),
    .settingsEmojiFontBreadcrumb: ("‹ 絵文字フォント", "‹ Emoji Font"),
    .settingsTabTitleFontBreadcrumb: ("‹ タブタイトルのフォント", "‹ Tab Title Font"),
    .settingsAgentIconsBreadcrumb: ("‹ エージェントアイコン", "‹ Agent icons"),
    .settingsSubHintOpen: ("↵/→ 開く   ←/esc 戻る", "↵/→ Open   ←/esc Back"),
    .settingsGlassDefault: ("Glass（既定）", "Glass (default)"),
    .settingsWorktreeDirBreadcrumb: ("‹ worktree の作成場所", "‹ Worktree Location"),
    .settingsWorktreeDirPlaceholder: (
      "テンプレート（空のまま確定で解除）", "Template (confirm empty to reset)"
    ),
    .settingsWorktreeDirHint: ("↵ 確定（空で解除）   esc 戻る", "↵ Apply (empty resets)   esc Back"),
    .settingsWorktreeDirInfo: (
      "{parent}（リポジトリ親）・{repo}（リポジトリ名）・{slug}（branch）が使えます",
      "Use {parent} (repo's parent dir), {repo} (repo name), and {slug} (branch)"
    ),
    .settingsWorktreeDirErrUnknownToken: ("不正なプレースホルダ: %@", "Invalid placeholder: %@"),
    .settingsWorktreeDirErrMissingSlug: ("{slug} を含めてください", "Template must include {slug}"),
    .settingsWorktreeDirErrNotAbsolute: (
      "絶対パスに解決される形にしてください（先頭 ~ 可）", "Must resolve to an absolute path (leading ~ allowed)"
    ),

    // MARK: Settings registry
    .settingsFontSize: ("フォントサイズ", "Font Size"),
    .settingsFontFamily: ("フォント", "Font"),
    .settingsEmojiFont: ("絵文字フォント", "Emoji Font"),
    .settingsEmojiFontNoto: ("Noto（同梱）", "Noto (bundled)"),
    .settingsEmojiFontApple: ("Apple（システム）", "Apple (system)"),
    .settingsTabTitleFont: ("タブタイトルのフォント", "Tab Title Font"),
    .settingsTabTitleFontSystemName: ("システム等幅", "System monospace"),
    .settingsTheme: ("テーマ", "Theme"),
    .settingsDefaultAgent: ("デフォルトエージェント", "Default Agent"),
    .settingsBackgroundOpacity: ("背景の不透明度", "Background Opacity"),
    .settingsBackgroundBlur: ("背景のブラー", "Background Blur"),
    .settingsCursorBlink: ("カーソルの点滅", "Cursor Blink"),
    .settingsAgentIcons: ("エージェントアイコン", "Agent Icons"),
    .settingsDevFeatures: ("開発中の機能を有効化", "Enable In-Development Features"),
    .settingsWorktreeDir: ("worktree の作成場所", "Worktree Location"),
    .settingsUnset: ("（未設定）", "(unset)"),
    .settingsToggleOn: ("オン", "On"),
    .settingsToggleOff: ("オフ", "Off"),
    .settingsIconsDefault: ("既定", "Default"),
    .settingsIconsCustomOne: ("%lld 状態カスタム", "%lld state customized"),
    .settingsIconsCustomOther: ("%lld 状態カスタム", "%lld states customized"),
    .settingsDefaultFont: ("既定（%@）", "Default (%@)"),
  ]
}
