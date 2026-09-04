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
    .settingsWorktreeDirDescParent: (
      "{parent} — リポジトリの親ディレクトリ", "{parent} — the repository's parent directory"
    ),
    .settingsWorktreeDirDescRepo: ("{repo} — リポジトリ名", "{repo} — the repository name"),
    .settingsWorktreeDirDescRepoPath: (
      "{repo_path} — リポジトリの場所", "{repo_path} — the repository's location"
    ),
    .settingsWorktreeDirDescSlug: (
      "{slug} — ブランチ名（/ は - にする）", "{slug} — the branch name (/ becomes -)"
    ),
    .settingsWorktreeDirDescTilde: ("先頭の ~ — ホームディレクトリ", "Leading ~ — your home directory"),
    .settingsWorktreeDirErrUnknownToken: ("不正なプレースホルダ: %@", "Invalid placeholder: %@"),
    .settingsWorktreeDirErrMissingSlug: ("{slug} を含めてください", "Template must include {slug}"),
    .settingsWorktreeDirErrNotAbsolute: (
      "絶対パスに解決される形にしてください（先頭 ~ 可）", "Must resolve to an absolute path (leading ~ allowed)"
    ),
    .settingsWorktreeDirWarnMissingRepo: (
      "{repo} も {repo_path} も無いため別リポジトリの同名ブランチと衝突します",
      "Without {repo} or {repo_path}, same-named branches of other repositories collide"
    ),
    .settingsWorktreeDirPresetSibling: ("リポジトリの隣（既定）", "Next to the repository (default)"),
    .settingsWorktreeDirPresetHome: ("ホームにまとめる", "Collect under home"),
    .settingsWorktreeDirPresetInside: ("リポジトリの中", "Inside the repository"),
    .settingsWorktreeDirPresetFlat: ("隣にフラット", "Flat beside the repository"),
    .settingsWorktreeDirCustom: ("カスタム…", "Custom…"),
    .settingsNotificationSoundBreadcrumb: ("‹ 通知音", "‹ Notification Sound"),
    .settingsNotificationSoundHint: (
      "↑↓ 選ぶと鳴る   ⇥ 完了⇄入力待ち   ↵ 適用   ←/esc 戻る",
      "↑↓ Preview   ⇥ Done⇄Waiting   ↵ Apply   ←/esc Back"
    ),
    .settingsNotificationSoundCaption: (
      "↑↓ で音を、⇥ で対象を切り替えると、その場ですぐ鳴る",
      "↑↓ picks the sound, ⇥ the event — either one plays instantly"
    ),
    .settingsNotificationSoundNone: ("なし", "None"),
    .settingsNotificationSoundOffRow: ("なし（オフ）", "None (off)"),
    .settingsNotificationSoundCustom: ("カスタム", "Custom"),
    .settingsSoundCustomHint: (
      "↵/→ 選ぶ・切替   ←/esc 戻る", "↵/→ Choose / Toggle   ←/esc Back"
    ),
    .settingsSoundCustomUnset: ("未設定", "Not set"),
    .settingsSoundCustomSameAsDoneValue: ("（完了と同じ）", "(same as done)"),
    .settingsSoundCustomErrUnreadable: ("読み込めない形式です（%@）", "Unsupported audio file (%@)"),
    .settingsSoundCustomErrSilent: ("音が入っていません（%@）", "No audio in this file (%@)"),
    .settingsSoundCustomErrStorage: (
      "音源を保存できませんでした", "Couldn't save the imported sound"
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
    .settingsWorktreeDir: ("worktree の作成場所", "Worktree Location"),
    .settingsNotificationSound: ("通知音", "Notification Sound"),
    .settingsNotificationSoundVolume: ("音量", "Volume"),
    .settingsNotificationSoundEnabled: ("通知音のオン/オフ", "Notification Sound On/Off"),
    .settingsSoundCustomDoneRow: ("完了の音源", "Done Sound File"),
    .settingsSoundCustomWaitingRow: ("入力待ちの音源", "Waiting Sound File"),
    .settingsSoundCustomSameAsDone: ("入力待ちも完了と同じ音", "Waiting Uses the Done Sound"),
    .settingsMenuBarNoticeDwell: ("メニューバー通知の表示時間", "Menu Bar Notice Duration"),
    .settingsSecondsValue: ("%lld秒", "%lld s"),
    .settingsUnset: ("（未設定）", "(unset)"),
    .settingsToggleOn: ("オン", "On"),
    .settingsToggleOff: ("オフ", "Off"),
    .settingsIconsDefault: ("既定", "Default"),
    .settingsIconsCustomOne: ("%lld 状態カスタム", "%lld state customized"),
    .settingsIconsCustomOther: ("%lld 状態カスタム", "%lld states customized"),
    .settingsDefaultFont: ("既定（%@）", "Default (%@)"),

    // MARK: Notification sound（12 案の名前。日本語 UI にカナは併記しない）
    .soundGlass: ("硝子", "Glass"),
    .soundPulse: ("電紫", "Pulse"),
    .soundWood: ("木肌", "Wood"),
    .soundAir: ("気配", "Air"),
    .soundEmblem: ("紋章", "Emblem"),
    .soundReply: ("返事", "Reply"),
    .soundBounce: ("弾み", "Bounce"),
    .soundArcade: ("遊技", "Arcade"),
    .soundSteel: ("鋼", "Steel"),
    .soundPiano: ("洋琴", "Piano"),
    .soundWhistle: ("口笛", "Whistle"),
    .soundDeep: ("深層", "Deep"),
  ]
}
