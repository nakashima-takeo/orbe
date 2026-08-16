import Foundation

/// UI 文言の型付きキー。フラット enum・`CaseIterable`（辞書欠落を `L10nCompletenessTests` が機械検出できる）。
/// 命名はドメイン接頭辞つき（衝突と重複を避ける）。粒度は「1 つの UI 文言 = 1 キー」。値は `L10n.table`。
///
/// 複数形は `xxxOne`/`xxxOther` の 2 キーで持ち、`LocalizationStore.plural(_:one:other:)` が件数で選ぶ。
/// 位置引数付きテンプレート（`%@`/`%lld`）は `format(_:_:)` で埋める。
///
/// 行数上限は適用外（下記 disable）——ここは「文言を 1 つ増やせば 1 行増える」台帳で、長さは複雑さでなく
/// 製品の文言数そのもの。分割もできない（enum の case は extension に置けない）。
enum L10nKey: String, CaseIterable, Sendable {
  // swiftlint:disable:previous type_body_length
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
  case quitConfirmQuit
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

  // MARK: - Git（実行層の共通失敗）
  case gitTimedOut

  // MARK: - Relative date
  case relativeJustNow

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
  case dispatchCleanSubtitle
  case dispatchCleanCandidatesOne
  case dispatchCleanCandidatesOther
  case dispatchCleanListNote
  case dispatchCleanSelected
  case dispatchCleanBack
  case dispatchCleanSectionSafe
  case dispatchCleanSectionCaution
  case dispatchCleanSectionInUse
  case dispatchCleanKeyHint
  case dispatchCleanExecute
  case dispatchCleanExecuteWithBranches
  case dispatchCleanExecuteWorktreesOne
  case dispatchCleanExecuteWorktreesOther
  case dispatchCleanExecuteBranchesOne
  case dispatchCleanExecuteBranchesOther
  case dispatchCleanBranchLabel
  case dispatchCleanBranchKeep
  case dispatchCleanBranchDelete
  case dispatchCleanLossNote
  case dispatchCleanDeletingTitle
  case dispatchCleanProgress
  case dispatchCleanCollapsedNote
  case dispatchCleanCancelHint
  case dispatchCleanRowRemoved
  case dispatchCleanRowRemovedWithBranch
  case dispatchCleanRowPruned
  case dispatchCleanRowPrunedWithBranch
  case dispatchCleanRowRunning
  case dispatchCleanRowPending
  case dispatchCleanRowPendingWithBranch
  case dispatchCleanRowSkipped
  case dispatchCleanDoneTitle
  case dispatchCleanTally
  case dispatchCleanRetryAll
  case dispatchCleanClose
  case dispatchCleanRetry
  case dispatchCleanOpenTab
  case dispatchCleanFailedDirty
  case dispatchCleanFailedOperation
  case dispatchCleanFailedWorktree
  case dispatchCleanFailedBranch
  case dispatchCleanPrunable
  case dispatchCleanUncommittedOne
  case dispatchCleanUncommittedOther
  case dispatchCleanUntrackedOne
  case dispatchCleanUntrackedOther
  case dispatchCleanInProgress
  case dispatchCleanOnRemote
  case dispatchCleanUnpushed
  case dispatchCleanOwnCommitsOne
  case dispatchCleanOwnCommitsOther
  case dispatchCleanAgentWorking
  case dispatchCleanAgentWaiting
  case dispatchCleanPaneOpen
  case dispatchCleanUnverified

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
  case settingsWorktreeDirBreadcrumb
  case settingsWorktreeDirPlaceholder
  case settingsWorktreeDirHint
  case settingsWorktreeDirDescParent
  case settingsWorktreeDirDescRepo
  case settingsWorktreeDirDescRepoPath
  case settingsWorktreeDirDescSlug
  case settingsWorktreeDirDescTilde
  case settingsWorktreeDirErrUnknownToken
  case settingsWorktreeDirErrMissingSlug
  case settingsWorktreeDirErrNotAbsolute
  case settingsWorktreeDirWarnMissingRepo
  case settingsWorktreeDirPresetSibling
  case settingsWorktreeDirPresetHome
  case settingsWorktreeDirPresetInside
  case settingsWorktreeDirPresetFlat
  case settingsWorktreeDirCustom
  case settingsNotificationSoundBreadcrumb
  case settingsNotificationSoundHint
  case settingsNotificationSoundCaption
  case settingsNotificationSoundNone
  case settingsNotificationSoundOffRow

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
  case settingsWorktreeDir
  case settingsNotificationSound
  case settingsNotificationSoundVolume
  case settingsNotificationSoundEnabled
  case settingsUnset
  case settingsToggleOn
  case settingsToggleOff
  case settingsIconsDefault
  case settingsIconsCustomOne
  case settingsIconsCustomOther
  case settingsDefaultFont

  // MARK: - Notification sound（12 案の名前）
  case soundGlass
  case soundPulse
  case soundWood
  case soundAir
  case soundEmblem
  case soundReply
  case soundBounce
  case soundArcade
  case soundSteel
  case soundPiano
  case soundWhistle
  case soundDeep

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
  case updateStateNotChecked
  case updateStateCheckDisabled
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
  case menubarWorkingSummary
  case menubarClickToPane
  case menubarOpenOrbe
  case menubarPermissionHint
  case settingsGlobalCmdTapLabel
  case settingsGlobalCmdTapGranted
  case settingsGlobalCmdTapDenied
  case settingsGlobalCmdTapRestartNote

  // MARK: - Help（⌘H チートシート）
  case helpSearchPlaceholder
  case helpHitCountOne
  case helpHitCountOther
  case helpCatBasics
  case helpCatAllShortcuts
  case helpCatGeneral
  case helpCatWorkspaceTabsPanes
  case helpCatAgents
  case helpCatTerminal
  case helpTopSubtitle
  case helpLegendTitle
  case helpLegendWorking
  case helpLegendWaiting
  case helpLegendDone
  case helpLegendIdle
  case helpKeyFilterChip
  case helpKeyboardCaption
  case helpFooterType
  case helpFooterEscClose
  case helpShortcutHelp
  case helpShortcutSettings
  case helpShortcutOpenEditor
  case helpShortcutQuit
  case helpShortcutSwitchWorkspace
  case helpShortcutNewWorkspace
  case helpShortcutNewTab
  case helpShortcutReopenClosedAgentTab
  case helpShortcutRenameTab
  case helpShortcutNextTab
  case helpShortcutPrevTab
  case helpShortcutSplitRight
  case helpShortcutSplitDown
  case helpShortcutClosePane
  case helpShortcutLaunchDefaultAgent
  case helpShortcutAgentPalette
  case helpShortcutDispatchPalette
  case helpShortcutAttentionPalette
  case helpShortcutFind
  case helpShortcutScrollTop
  case helpShortcutScrollBottom
  case helpShortcutCopy
  case helpShortcutPaste
  case helpShortcutFontLarger
  case helpShortcutFontSmaller
  case helpShortcutFontReset
}
