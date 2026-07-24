import Foundation

/// UI 文言の型付きキー。フラット enum・`CaseIterable`（辞書欠落を `L10nCompletenessTests` が機械検出できる）。
/// 命名はドメイン接頭辞つき（衝突と重複を避ける）。粒度は「1 つの UI 文言 = 1 キー」。値は `L10n.table`。
///
/// 複数形は `xxxOne`/`xxxOther` の 2 キーで持ち、`LocalizationStore.plural(_:one:other:)` が件数で選ぶ。
/// 位置引数付きテンプレート（`%@`/`%lld`）は `format(_:_:)` で埋める。
enum L10nKey: String, CaseIterable, Sendable {
  // MARK: - Menu（AppKit メインメニュー）
  case menuHide
  case menuHideOthers
  case menuShowAll
  case menuQuit
  case menuEdit
  case menuUndo
  case menuRedo
  case menuCut
  case menuCopy
  case menuPaste
  case menuSelectAll

  // MARK: - Quit confirm（実行中プロセスの終了確認）
  case quitConfirmTitle
  case quitConfirmMessage
  case quitConfirmClose
  case quitConfirmCancel

  // MARK: - Language select（初回言語選択カード・設定の言語ドリルイン）
  case languageSelectTitle
  case languageSelectHint
  case settingsLanguageLabel
  case settingsLanguageBreadcrumb
  case settingsSubHintApply

  // MARK: - Common（複数ドメインで共有）
  case commonLoading
  case commonCancel

  // MARK: - EditorPane / FileViewer
  case editorSelectFile
  case editorSearchFiles
  case editorSegSource
  case editorSegPreview
  case editorSegFile
  case editorChangesHintLead
  case editorGitToolWord
  case editorChangesHintTail
  case editorPreviewOverlayTitle
  case editorPreviewLegend
  case editorStageHintLead
  case editorStageHintTail
  case editorNoteCannotShow
  case editorNoteConflict
  case editorNoteBinary
  case editorNoteRenameOnly
  case editorNoteEmptyFile
  case editorNoteModeOnly
  case editorEmptyNoCwd
  case editorEmptyNotGit
  case editorEmptyStatusFailed

  // MARK: - Commit
  case commitMessagePlaceholder
  case commitInProgress
  case commitButton
  case commitSucceeded
  case commitFailed

  // MARK: - Git workbench（変更・履歴レール / CommitDetail）
  case gitNoCommits
  case gitUncommitted
  case gitUncommittedChanges
  case gitMoreFilesOne
  case gitMoreFilesOther
  case gitNoChanges
  case gitUnstageAction
  case gitDiscard
  case gitDiscardChanges
  case gitDiscardTitle
  case gitDiscardConfirmOne
  case gitDiscardConfirmOther
  case gitChangesCount
  case gitChangesTab
  case gitHistory
  case gitSortNewest
  case gitUnpushed
  case gitAheadOfUpstream

  // MARK: - Browser tool
  case browserDevServerOff
  case browserDevServerHint
  case browserDevServerRunning
  case browserDevServerStopped
  case browserOpenExternal

  // MARK: - Relative date（履歴レール・CommitDetail）
  case relativeJustNow
  case relativeYesterday
  case relativeMinutesAgoOne
  case relativeMinutesAgoOther
  case relativeHoursAgoOne
  case relativeHoursAgoOther
  case relativeDaysAgoOne
  case relativeDaysAgoOther
  case relativeMonthsAgoOne
  case relativeMonthsAgoOther
  case relativeYearsAgoOne
  case relativeYearsAgoOther

  // MARK: - Agent（共有: 状態名・検出無し）
  case agentNotFoundCLI
  case agentStateWorking
  case agentStateWaiting
  case agentStateDone
  case agentStateIdle
  case agentStateDormant

  // MARK: - Dispatch パレット
  case dispatchWorktreeExisting
  case dispatchWorktreeCheckout
  case dispatchWorktreeNew
  case dispatchPrepExisting
  case dispatchPrepCheckout
  case dispatchPrepNew
  case dispatchLaunchSuffix
  case dispatchReviewRequired
  case dispatchChangesRequested
  case dispatchApproved
  case dispatchGhMissing
  case dispatchGhUnauthed
  case dispatchAgentOpen
  case dispatchQueryPlaceholder
  case dispatchPreparing
  case dispatchHintSelect
  case dispatchHintAgent
  case dispatchHintOpen
  case dispatchHintClose
  case dispatchErrNotGitRepo
  case dispatchErrForkPR

  // MARK: - Onboarding
  case onboardingBegin
  case onboardingDetecting
  case onboardingIntro
  case onboardingWelcome
  case onboardingInstalling
  case onboardingHintDetecting
  case onboardingHintBegin
  case onboardingHintSelectBegin
  case onboardingStatusWaiting
  case onboardingStatusInstalling
  case onboardingStatusDone
  case onboardingStatusFailed
  case onboardingStatusSkipped

  // MARK: - Workspace 作成カード
  case wsCreateTitle
  case wsCreateEscBack
  case wsFieldPath
  case wsFieldName
  case wsFollowPath
  case wsFollowURL
  case wsHintMove
  case wsHintComplete
  case wsSuggestionCountOne
  case wsSuggestionCountOther
  case wsCreateOpen
  case wsCreateGuideLead
  case wsCreateGuideOpenTail
  case wsFolderMissing
  case wsSourceFolder
  case wsCloneGuideTail
  case wsCloneEmptyHint
  case wsFieldRepoURL
  case wsFieldCloneDest
  case wsCloneDestNote
  case wsCloning
  case wsLinkedFollowing
  case wsUnlinkRelink

  // MARK: - Workspace パレット
  case wsPalettePlaceholder
  case wsPaletteHintList
  case wsPaletteHintSubmenu
  case wsRenamePlaceholder
  case wsRenameHint
  case wsSetDirPlaceholder
  case wsSetDirHint
  case wsCreateInline
  case wsCreateFlowRow
  case wsActionRename
  case wsActionSetDir
  case wsActionClose

  // MARK: - Settings パレット（root / サブ）
  case settingsScopeGlobal
  case settingsScopeWorkspace
  case settingsScopeWord
  case settingsInheritGlobal
  case settingsWorkspaceOverrideNote
  case settingsInheritedNote
  case settingsFilterPlaceholder
  case settingsRootHintWorkspace
  case settingsRootHintGlobal
  case settingsNoMatch
  case settingsThemeBreadcrumb
  case settingsAgentBreadcrumb
  case settingsFontBreadcrumb
  case settingsFontFilterPlaceholder
  case settingsFontHint
  case settingsNoFonts
  case settingsNoMatchingFonts
  case settingsEmojiFontBreadcrumb
  case settingsTabTitleFontBreadcrumb
  case settingsAgentIconsBreadcrumb
  case settingsSubHintOpen
  case settingsGlassDefault

  // MARK: - Search バー
  case searchPlaceholder
  case searchNoMatch
  case searchMatchesOne
  case searchMatchesOther

  // MARK: - Editor 起動
  case editorNotFoundTitle
  case editorNotFoundMessage

  // MARK: - Settings registry（descriptor ラベル・値語彙）
  case settingsFontSize
  case settingsFontFamily
  case settingsEmojiFont
  case settingsEmojiFontNoto
  case settingsEmojiFontApple
  case settingsTabTitleFont
  case settingsTabTitleFontSystemName
  case settingsTheme
  case settingsDefaultAgent
  case settingsBackgroundOpacity
  case settingsBackgroundBlur
  case settingsCursorBlink
  case settingsAgentIcons
  case settingsDevFeatures
  case settingsUnset
  case settingsToggleOn
  case settingsToggleOff
  case settingsIconsDefault
  case settingsIconsCustomOne
  case settingsIconsCustomOther
  case settingsDefaultFont

  // MARK: - Agent palette
  case agentPaletteSetDefault
  case agentPaletteHintList

  // MARK: - Update（メニュー・トースト・変更内容シート・設定›アップデート）
  case menuCheckForUpdates
  case settingsUpdateLabel
  case settingsUpdateBreadcrumb
  case settingsUpdateHint
  case updateToastTitle
  case updateToastAutoApply
  case updateToastManualApply
  case updateRestartNow
  case updateShowChanges
  case updateSheetTitle
  case updateVerifiedLine
  case updateRestartAndUpdate
  case updateCloseButton
  case updateSheetFootnote
  case updateStateChecking
  case updateStateDownloading
  case updateStateUpToDate
  case updateStateFailedTitle
  case updateStateFailedHint
  case updateRetry
  case updateStateWaiting
  case updateWaitingApplyOnQuit
  case updateWaitingApplyManual
  case updateCurrentVersion
  case updateLastChecked
  case updateLastCheckedNever
  case updateAutoCheckLabel
  case updateAutoCheckSub
  case updateAutoDownloadLabel
  case updateAutoDownloadSub
  case updateAutoInstallLabel
  case updateAutoInstallSub
  case updateCheckNow

  // MARK: - Attention（パレット・メニューバー投影・グローバル ⌘⌘ の権限）
  case attentionHintJump
  case attentionHintSelect
  case attentionHintClose
  case attentionEmpty
  case menubarClickToPane
  case menubarOpenOrbe
  case menubarPermissionHint
  case settingsGlobalCmdTapLabel
  case settingsGlobalCmdTapGranted
  case settingsGlobalCmdTapDenied
  case settingsGlobalCmdTapRestartNote
}
