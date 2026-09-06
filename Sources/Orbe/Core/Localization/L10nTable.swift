import Foundation

/// UI 文言の辞書（`L10nKey` → 日英）と言語別のルックアップ。`LocalizationStore` と AppKit `MainMenu` の
/// 両方がここを通す（`language == .ja` 分岐を 1 箇所へ集約）。全 `L10nKey` の網羅は `L10nCompletenessTests`。
/// 辞書はドメイン分冊（本体＋`L10nTable+Settings.swift`＋`L10nTable+Help.swift`＋
/// `L10nTable+Attention.swift`＋`L10nTable+Dispatch.swift`＋`L10nTable+ClosedAgents.swift`）を
/// `table` が結合する。
enum L10n {
  static let table: [L10nKey: (ja: String, en: String)] =
    baseTable
    .merging(settingsTable) { a, _ in a }
    .merging(helpTable) { a, _ in a }
    .merging(attentionTable) { a, _ in a }
    .merging(dispatchTable) { a, _ in a }
    .merging(closedAgentsTable) { a, _ in a }

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
    .quitConfirmMessage: ("終了するとプロセスは中断されます。", "Quitting will interrupt the process."),
    .quitConfirmQuit: ("終了", "Quit"),
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

    // MARK: Git
    .gitTimedOut: ("git から応答が無いため中断しました", "Stopped: no response from git"),

    // MARK: Relative date
    .relativeJustNow: ("たった今", "just now"),

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

    // MARK: Tab context menu
    .tabMenuResetAgentState: ("エージェント状態をリセット", "Reset Agent State"),

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
    .updateStateNotChecked: ("まだ確認していません", "Not checked yet"),
    .updateStateCheckDisabled: (
      "このビルドでは更新を確認しません", "This build doesn’t check for updates"
    ),
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
