import Foundation

/// UI 文言の辞書（`L10nKey` → 日英）と言語別のルックアップ。`LocalizationStore` と AppKit `MainMenu` の
/// 両方がここを通す（`language == .ja` 分岐を 1 箇所へ集約）。全 `L10nKey` の網羅は `L10nCompletenessTests`。
/// 辞書はドメイン分冊（本体＋`L10nTable+Help.swift`）を `table` が結合する。
enum L10n {
  static let table: [L10nKey: (ja: String, en: String)] =
    baseTable.merging(helpTable) { a, _ in a }.merging(worktreePathTable) { a, _ in a }

  private static let baseTable: [L10nKey: (ja: String, en: String)] = [
    // MARK: Menu
    .menuHide: ("%@を隠す", "Hide %@"),
    .menuHideOthers: ("ほかを隠す", "Hide Others"),
    .menuShowAll: ("すべてを表示", "Show All"),
    .menuQuit: ("%@を終了", "Quit %@"),
    .menuEdit: ("編集", "Edit"),
    .menuUndo: ("取り消す", "Undo"),
    .menuRedo: ("やり直す", "Redo"),
    .menuCut: ("カット", "Cut"),
    .menuCopy: ("コピー", "Copy"),
    .menuPaste: ("ペースト", "Paste"),
    .menuSelectAll: ("すべてを選択", "Select All"),

    // MARK: Quit confirm
    .quitConfirmTitle: ("実行中のプロセスがあります", "A process is still running"),
    .quitConfirmMessage: ("閉じるとプロセスは中断されます。", "Closing will interrupt the process."),
    .quitConfirmClose: ("閉じる", "Close"),
    .quitConfirmCancel: ("キャンセル", "Cancel"),

    // MARK: Language select
    .languageSelectTitle: ("言語を選択", "Choose Language"),
    .languageSelectHint: ("↑↓ 選択   ↵ 決定", "↑↓ Select   ↵ Confirm"),
    .settingsLanguageLabel: ("言語", "Language"),
    .settingsLanguageBreadcrumb: ("‹ 言語", "‹ Language"),
    .settingsSubHintApply: ("↵ 設定   ←/esc 戻る", "↵ Set   ←/esc Back"),

    // MARK: Common
    .commonLoading: ("読み込み中…", "Loading…"),
    .commonCancel: ("キャンセル", "Cancel"),

    // MARK: EditorPane / FileViewer
    .editorSelectFile: ("ファイルを選択", "Select a file"),
    .editorSearchFiles: ("ファイルを検索", "Search files"),
    .editorSegSource: ("ソース", "Source"),
    .editorSegPreview: ("プレビュー", "Preview"),
    .editorSegFile: ("ファイル", "File"),
    .editorChangesHintLead: ("変更は ", "Changes go through "),
    .editorGitToolWord: ("git ツール", "the Git tool"),
    .editorChangesHintTail: (" で", "."),
    .editorPreviewOverlayTitle: ("プレビューに変更を重ねて表示", "Changes overlaid on preview"),
    .editorPreviewLegend: ("追加＝緑 / 削除＝打ち消し", "Added = green / Removed = strikethrough"),
    .editorStageHintLead: ("stage は ", "Stage from the "),
    .editorStageHintTail: (" 表示で", " view."),
    .editorNoteCannotShow: (
      "内容を表示できません（ファイル単位で操作）", "Can't display contents (operate per file)"
    ),
    .editorNoteConflict: ("競合 — ターミナルで解決", "Conflict — resolve in terminal"),
    .editorNoteBinary: ("バイナリファイル（ファイル単位で操作）", "Binary file (operate per file)"),
    .editorNoteRenameOnly: ("rename のみ（内容の変更なし）", "Rename only (no content change)"),
    .editorNoteEmptyFile: ("空のファイル", "Empty file"),
    .editorNoteModeOnly: ("mode 変更のみ", "Mode change only"),
    .editorEmptyNoCwd: ("ペインの作業ディレクトリが不明です", "Pane working directory is unknown"),
    .editorEmptyNotGit: ("git リポジトリではありません\n%@", "Not a git repository\n%@"),
    .editorEmptyStatusFailed: ("git の状態を取得できませんでした", "Couldn't get git status"),

    // MARK: Commit
    .commitMessagePlaceholder: ("コミットメッセージ", "Commit message"),
    .commitInProgress: ("コミット中…", "Committing…"),
    .commitButton: ("コミット ⌘⏎", "Commit ⌘⏎"),
    .commitSucceeded: ("コミットしました", "Committed"),
    .commitFailed: ("コミットに失敗しました", "Commit failed"),

    // MARK: Git workbench
    .gitNoCommits: ("コミットがありません", "No commits"),
    .gitUncommitted: ("未コミット", "Uncommitted"),
    .gitUncommittedChanges: ("未コミットの変更", "Uncommitted changes"),
    .gitMoreFilesOne: ("… 他 %lld files", "… %lld more file"),
    .gitMoreFilesOther: ("… 他 %lld files", "… %lld more files"),
    .gitNoChanges: ("変更はありません", "No changes"),
    .gitUnstageAction: ("解除 s", "Unstage s"),
    .gitDiscard: ("破棄", "Discard"),
    .gitDiscardChanges: ("変更を破棄", "Discard changes"),
    .gitDiscardTitle: ("「%@」の変更を破棄", "Discard changes in “%@”"),
    .gitDiscardConfirmOne: (
      "%lld 個のファイルの変更を破棄します（元に戻せません）。",
      "Discard changes to %lld file? This can't be undone."
    ),
    .gitDiscardConfirmOther: (
      "%lld 個のファイルの変更を破棄します（元に戻せません）。",
      "Discard changes to %lld files? This can't be undone."
    ),
    .gitChangesCount: ("変更 %lld ·", "Changed %lld ·"),
    .gitChangesTab: ("変更 %lld", "Changes %lld"),
    .gitHistory: ("履歴", "History"),
    .gitSortNewest: ("新しい順 ▾", "Newest ▾"),
    .gitUnpushed: ("未push", "Unpushed"),
    .gitAheadOfUpstream: ("%@ から ", "%@ · "),

    // MARK: Browser tool
    .browserDevServerOff: ("dev サーバー未起動", "Dev server not running"),
    .browserDevServerHint: (
      "このプロジェクトで dev サーバーを起動すると、ここにプレビューが表示されます",
      "Start a dev server for this project to preview it here"
    ),
    .browserDevServerRunning: ("dev サーバー稼働中", "Dev server running"),
    .browserDevServerStopped: ("dev サーバー停止中", "Dev server stopped"),
    .browserOpenExternal: ("外部ブラウザで開く ↗", "Open in browser ↗"),

    // MARK: Relative date
    .relativeJustNow: ("たった今", "just now"),
    .relativeYesterday: ("昨日", "yesterday"),
    .relativeMinutesAgoOne: ("%lld分前", "%lld minute ago"),
    .relativeMinutesAgoOther: ("%lld分前", "%lld minutes ago"),
    .relativeHoursAgoOne: ("%lld時間前", "%lld hour ago"),
    .relativeHoursAgoOther: ("%lld時間前", "%lld hours ago"),
    .relativeDaysAgoOne: ("%lld日前", "%lld day ago"),
    .relativeDaysAgoOther: ("%lld日前", "%lld days ago"),
    .relativeMonthsAgoOne: ("%lldヶ月前", "%lld month ago"),
    .relativeMonthsAgoOther: ("%lldヶ月前", "%lld months ago"),
    .relativeYearsAgoOne: ("%lld年前", "%lld year ago"),
    .relativeYearsAgoOther: ("%lld年前", "%lld years ago"),

    // MARK: Agent（共有）
    .agentNotFoundCLI: (
      "エージェント CLI が見つかりません（claude / codex / agy）",
      "No agent CLI found (claude / codex / agy)"
    ),
    .agentStateWorking: ("実行中", "Working"),
    .agentStateWaiting: ("入力待ち", "Waiting"),
    .agentStateDone: ("完了", "Done"),
    .agentStateIdle: ("アイドル", "Idle"),
    .agentStateDormant: ("休眠", "Dormant"),

    // MARK: Dispatch
    .dispatchWorktreeExisting: ("既存worktree", "existing worktree"),
    .dispatchWorktreeCheckout: ("checkout → worktree", "checkout → worktree"),
    .dispatchWorktreeNew: ("新規worktree", "new worktree"),
    .dispatchPrepExisting: ("の既存worktreeで", "· existing worktree ·"),
    .dispatchPrepCheckout: ("をcheckoutしたworktreeで", "· checkout worktree ·"),
    .dispatchPrepNew: ("の新規worktreeで", "· new worktree ·"),
    .dispatchLaunchSuffix: ("を新しいタブで起動", "· new tab"),
    .dispatchReviewRequired: ("review待ち", "review pending"),
    .dispatchChangesRequested: ("要修正", "changes requested"),
    .dispatchApproved: ("承認済み", "approved"),
    .dispatchGhMissing: (
      "gh CLI 未導入（brew install gh で issue/PR を表示）",
      "gh CLI not installed (brew install gh to show issues/PRs)"
    ),
    .dispatchGhUnauthed: (
      "gh 未認証（gh auth login で issue/PR を表示）",
      "gh not authenticated (gh auth login to show issues/PRs)"
    ),
    .dispatchAgentOpen: ("%@で開く", "open with %@"),
    .dispatchQueryPlaceholder: (
      "worktree / branch / issue を絞り込み", "Filter worktree / branch / issue"
    ),
    .dispatchPreparing: ("作成中…", "Preparing…"),
    .dispatchHintSelect: ("選択", "Select"),
    .dispatchHintAgent: ("agent変更", "Change agent"),
    .dispatchHintOpen: ("開く", "Open"),
    .dispatchHintClose: ("閉じる", "Close"),
    .dispatchErrNotGitRepo: (
      "git リポジトリを解決できませんでした", "Couldn't resolve a git repository"
    ),
    .dispatchErrForkPR: (
      "fork の PR #%lld は worktree 化に未対応です（⌘↵ でブラウザを開けます）",
      "Fork PR #%lld can't be made into a worktree (⌘↵ to open in browser)"
    ),

    // MARK: Onboarding
    .onboardingBegin: ("始める", "Get started"),
    .onboardingDetecting: ("CLI を検出中…", "Detecting CLIs…"),
    .onboardingIntro: (
      "状態追跡プラグインを各 CLI に導入して始めます",
      "We'll install the status-tracking plugin into each CLI to begin"
    ),
    .onboardingWelcome: ("Orbe へようこそ", "Welcome to Orbe"),
    .onboardingInstalling: ("プラグインを導入中 · %lld/%lld 完了", "Installing plugins · %lld/%lld done"),
    .onboardingHintDetecting: ("検出中…", "Detecting…"),
    .onboardingHintBegin: ("↵ 始める", "↵ Get started"),
    .onboardingHintSelectBegin: ("↑↓ デフォルト選択   ↵ 始める", "↑↓ Pick default   ↵ Get started"),
    .onboardingStatusWaiting: ("待機", "Waiting"),
    .onboardingStatusInstalling: ("導入中…", "Installing…"),
    .onboardingStatusDone: ("導入済み", "Installed"),
    .onboardingStatusFailed: ("失敗", "Failed"),
    .onboardingStatusSkipped: ("スキップ", "Skipped"),

    // MARK: Workspace 作成カード
    .wsCreateTitle: ("新規ワークスペース", "New workspace"),
    .wsCreateEscBack: ("esc 戻る", "esc Back"),
    .wsFieldPath: ("パス", "Path"),
    .wsFieldName: ("名前", "Name"),
    .wsFollowPath: ("パス", "path"),
    .wsFollowURL: ("URL", "URL"),
    .wsHintMove: ("↑↓ 移動", "↑↓ Move"),
    .wsHintComplete: ("⇥ 補完", "⇥ Complete"),
    .wsSuggestionCountOne: ("%lld 件", "%lld result"),
    .wsSuggestionCountOther: ("%lld 件", "%lld results"),
    .wsCreateOpen: ("作成して開く", "Create and open"),
    .wsCreateGuideLead: ("作成すると ", "Creates "),
    .wsCreateGuideOpenTail: (" が開きます", " on create"),
    .wsFolderMissing: ("フォルダが存在しません", "Folder doesn't exist"),
    .wsSourceFolder: ("既存フォルダ", "Existing folder"),
    .wsCloneGuideTail: (" が clone されます", " on clone"),
    .wsCloneEmptyHint: ("リポジトリ URL と clone 先を入力", "Enter a repository URL and clone destination"),
    .wsFieldRepoURL: ("リポジトリ URL", "Repository URL"),
    .wsFieldCloneDest: ("clone 先", "Clone into"),
    .wsCloneDestNote: ("フォルダは作成時に作られます", "The folder is created on create"),
    .wsCloning: ("clone 中…", "Cloning…"),
    .wsLinkedFollowing: ("⌁ %@に追従中", "⌁ following %@"),
    .wsUnlinkRelink: ("リンク解除中 — 再リンク", "Unlinked — relink"),

    // MARK: Workspace パレット
    .wsPalettePlaceholder: (
      "workspace を切替 / 入力で新規作成", "Switch workspace / type to create"
    ),
    .wsPaletteHintList: (
      "↵ 切替/作成   → 詳細   esc 閉じる", "↵ Switch/Create   → Details   esc Close"
    ),
    .wsPaletteHintSubmenu: ("↵ 実行   ← 戻る   esc 閉じる", "↵ Run   ← Back   esc Close"),
    .wsRenamePlaceholder: ("新しい名前", "New name"),
    .wsRenameHint: ("↵ 改名を確定   esc 取消", "↵ Confirm rename   esc Cancel"),
    .wsSetDirPlaceholder: ("ディレクトリのパス", "Directory path"),
    .wsSetDirHint: ("↵ ディレクトリを確定   esc 取消", "↵ Confirm directory   esc Cancel"),
    .wsCreateInline: ("＋ \"%@\" を新規作成", "＋ Create \"%@\""),
    .wsCreateFlowRow: ("＋ 新規ワークスペース — パスから作成", "＋ New workspace — create from a path"),
    .wsActionRename: ("改名", "Rename"),
    .wsActionSetDir: ("ディレクトリ", "Directory"),
    .wsActionClose: ("削除", "Delete"),

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

    // MARK: Search バー
    .searchPlaceholder: ("検索", "Search"),
    .searchNoMatch: ("一致なし", "No matches"),
    .searchMatchesOne: ("%lld 件", "%lld match"),
    .searchMatchesOther: ("%lld 件", "%lld matches"),

    // MARK: Editor 起動・タブ改名
    .editorNotFoundTitle: ("エディタが見つかりません", "No editor found"),
    .editorNotFoundMessage: (
      "VS Code・Cursor・Windsurf・Zed・Sublime のいずれかを PATH に追加するか、$VISUAL／$EDITOR に GUI エディタを設定してください。",
      "Add one of VS Code, Cursor, Windsurf, Zed, or Sublime to your PATH, or set a GUI editor in $VISUAL/$EDITOR."
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
    .settingsUnset: ("（未設定）", "(unset)"),
    .settingsToggleOn: ("オン", "On"),
    .settingsToggleOff: ("オフ", "Off"),
    .settingsIconsDefault: ("既定", "Default"),
    .settingsIconsCustomOne: ("%lld 状態カスタム", "%lld state customized"),
    .settingsIconsCustomOther: ("%lld 状態カスタム", "%lld states customized"),
    .settingsDefaultFont: ("既定（%@）", "Default (%@)"),

    // MARK: Agent palette
    .agentPaletteSetDefault: ("デフォルトに設定", "Set as default"),
    .agentPaletteHintList: ("↵ 起動   → 詳細   esc 閉じる", "↵ Launch   → Details   esc Close"),

    // MARK: Update
    .menuCheckForUpdates: ("更新を確認…", "Check for Updates…"),
    .settingsUpdateLabel: ("アップデート", "Updates"),
    .settingsUpdateBreadcrumb: ("‹ アップデート", "‹ Updates"),
    .settingsUpdateHint: ("↵ 実行/切替   ←/esc 戻る", "↵ Apply/Toggle   ←/esc Back"),
    .updateToastTitle: ("アップデートの準備ができました", "Update ready to install"),
    .updateToastAutoApply: ("次回終了時に自動で適用されます", "Applies automatically on next quit"),
    .updateToastManualApply: ("「今すぐ再起動」で適用されます", "Applies via “Restart Now”"),
    .updateRestartNow: ("今すぐ再起動", "Restart Now"),
    .updateShowChanges: ("変更内容", "What’s New"),
    .updateSheetTitle: ("%@ の変更内容", "What’s New in %@"),
    .updateVerifiedLine: (
      "Developer ID 署名と公証を検証済み", "Developer ID signature and notarization verified"
    ),
    .updateRestartAndUpdate: ("再起動して更新", "Restart & Update"),
    .updateCloseButton: ("閉じる", "Close"),
    .updateSheetFootnote: ("閉じても終了時に自動で適用されます", "Closing still applies the update on quit"),
    .updateStateChecking: ("アップデートを確認中…", "Checking for updates…"),
    .updateStateDownloading: ("%@ をダウンロード中", "Downloading %@"),
    .updateStateUpToDate: ("最新です", "Up to date"),
    .updateStateFailedTitle: ("ダウンロードに失敗しました", "Download failed"),
    .updateStateFailedHint: (
      "接続を確認してください。次回の自動確認でも再試行します",
      "Check your connection. It will retry on the next automatic check"
    ),
    .updateRetry: ("再試行", "Retry"),
    .updateStateWaiting: ("%@ 適用待ち", "%@ ready to install"),
    .updateWaitingApplyOnQuit: ("終了時に自動で更新されます", "Updates automatically on quit"),
    .updateWaitingApplyManual: ("「今すぐ再起動」で適用されます", "Applies via “Restart Now”"),
    .updateCurrentVersion: ("現在のバージョン", "Current version"),
    .updateLastChecked: ("最終確認: %@", "Last checked: %@"),
    .updateLastCheckedNever: ("最終確認: —", "Last checked: —"),
    .updateAutoCheckLabel: ("自動でアップデートを確認", "Check for updates automatically"),
    .updateAutoCheckSub: ("1日1回、バックグラウンドで", "Once a day, in the background"),
    .updateAutoDownloadLabel: ("自動でダウンロード", "Download automatically"),
    .updateAutoDownloadSub: ("署名の検証まで済ませておく", "Verifies the signature ahead of time"),
    .updateAutoInstallLabel: ("終了時に自動で適用", "Install automatically on quit"),
    .updateAutoInstallSub: ("オフにすると再起動ボタンからのみ", "When off, install only via the restart button"),
    .updateCheckNow: ("今すぐ確認", "Check Now"),
  ]

  /// 型付きキーを指定言語の文言へ引く。網羅はテストで保証（欠落は開発時にクラッシュで気づく）。
  static func string(_ key: L10nKey, _ language: Language) -> String {
    let entry = table[key]!
    return language == .ja ? entry.ja : entry.en
  }

  /// 位置引数付きテンプレートを指定言語で埋める。
  static func format(_ key: L10nKey, _ language: Language, _ args: CVarArg...) -> String {
    String(format: string(key, language), arguments: args)
  }
}
