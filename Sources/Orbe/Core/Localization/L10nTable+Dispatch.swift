import Foundation

/// Dispatch パレット（⌘⇧X）の文言。一覧・clean の 3 画面・3 軸の状態語彙をまとめて持つ。
///
/// **git / gh の語は訳さない**（`[gone]` / `locked` / `PR #N merged` / `merged → <既定>` /
/// `remote +N` / `main worktree`）——訳すと出力と対応が取れなくなる技術語なので、
/// `origin/…` と同じくそのまま出す。ここに無い語はその判断の結果であって、抜けではない。
extension L10n {
  static let dispatchTable: [L10nKey: (ja: String, en: String)] = [
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
    .dispatchCleanSubtitle: (
      "要らなくなった worktree を掃除", "Clean up worktrees you no longer need"
    ),
    .dispatchCleanCandidatesOne: ("候補 %lld 件", "%lld candidate"),
    .dispatchCleanCandidatesOther: ("候補 %lld 件", "%lld candidates"),
    .dispatchCleanListNote: (
      "rm / prune / 掃除 の入力もエイリアスでヒット · 候補 0 件でも行は残る（バッジだけ消える）",
      "rm / prune / 掃除 also match as aliases · the row stays at 0 candidates (only the badge goes)"
    ),
    .dispatchCleanSelected: ("%lld 件選択中", "%lld selected"),
    .dispatchCleanBack: ("esc 戻る", "esc Back"),
    .dispatchCleanSectionSafe: ("安全 — 掃除して問題なし", "Safe — nothing to lose"),
    .dispatchCleanSectionCaution: ("確認 — 消えるものがあります", "Check — something will be lost"),
    .dispatchCleanSectionInUse: ("使用中 — 削除できません", "In use — can't be deleted"),
    .dispatchCleanKeyHint: (
      "space 選択 · ←→ ブランチの扱い · a 安全を全選択",
      "space Select · ←→ Branch · a Select all safe"
    ),
    .dispatchCleanExecute: ("⌘⏎ %lld 件を削除", "⌘⏎ Delete %lld"),
    .dispatchCleanBranchLabel: ("ブランチ %@:", "Branch %@:"),
    .dispatchCleanBranchKeep: ("残す", "Keep"),
    .dispatchCleanBranchDelete: ("削除", "Delete"),
    .dispatchCleanBranchAlsoDeleted: ("ブランチも削除", "branch deleted too"),
    .dispatchCleanLossNote: ("%@ も消えます", "%@ will be lost too"),
    .dispatchCleanDeletingTitle: ("削除中", "Deleting"),
    .dispatchCleanProgress: ("%lld / %lld 件", "%lld / %lld"),
    .dispatchCleanCollapsedNote: ("未選択の行は畳んで非表示", "Unselected rows are collapsed"),
    .dispatchCleanCancelHint: (
      "esc 中断(実行済みは戻りません)", "esc Stop (what's done stays done)"
    ),
    .dispatchCleanRowRemoved: ("worktree を削除しました", "Removed the worktree"),
    .dispatchCleanRowRemovedWithBranch: (
      "worktree と %@ を削除しました", "Removed the worktree and %@"
    ),
    .dispatchCleanRowPruned: ("prune しました(実体なし)", "Pruned (no directory)"),
    .dispatchCleanRowPrunedWithBranch: (
      "prune と %@ を削除しました(実体なし)", "Pruned (no directory) and removed %@"
    ),
    .dispatchCleanRowRunning: ("worktree rm 実行中…", "Running worktree rm…"),
    .dispatchCleanRowPending: ("待機中 — worktree を削除", "Waiting — delete the worktree"),
    .dispatchCleanRowPendingWithBranch: (
      "待機中 — worktree + ブランチを削除", "Waiting — delete the worktree + branch"
    ),
    .dispatchCleanRowSkipped: ("中断のため未実行", "Not run (stopped)"),
    .dispatchCleanDoneTitle: ("完了(%lld 件失敗)", "Done (%lld failed)"),
    .dispatchCleanTally: ("%lld 成功 · %lld 失敗", "%lld succeeded · %lld failed"),
    .dispatchCleanRetryAll: ("⏎ 失敗分を再試行", "⏎ Retry the failures"),
    .dispatchCleanClose: ("esc 閉じる", "esc Close"),
    .dispatchCleanRetry: ("⏎ 再試行", "⏎ Retry"),
    .dispatchCleanOpenTab: ("o タブで開く", "o Open in a tab"),
    .dispatchCleanFailedDirty: (
      "未コミットの変更があるため中止しました", "Stopped: there are uncommitted changes"
    ),
    .dispatchCleanFailedOperation: (
      "git 操作が進行中のため中止しました", "Stopped: a git operation is in progress"
    ),
    .dispatchCleanFailedWorktree: (
      "削除できませんでした — ペインで使用中の可能性", "Couldn't delete — may be in use by a pane"
    ),
    .dispatchCleanFailedBranch: (
      "worktree は削除 · ブランチは残しました", "Worktree removed · branch kept"
    ),
    .dispatchCleanPrunable: ("prunable · 実体なし", "prunable · no directory"),
    .dispatchCleanUncommittedOne: ("未コミット %lld ファイル", "%lld uncommitted file"),
    .dispatchCleanUncommittedOther: ("未コミット %lld ファイル", "%lld uncommitted files"),
    .dispatchCleanUntrackedOne: ("untracked %lld ファイル", "%lld untracked file"),
    .dispatchCleanUntrackedOther: ("untracked %lld ファイル", "%lld untracked files"),
    .dispatchCleanInProgress: ("%@ 進行中", "%@ in progress"),
    .dispatchCleanSavedOnRemote: ("remote に保存済み", "Saved on remote"),
    .dispatchCleanRemoteSynced: ("remote に同期済み", "In sync with remote"),
    .dispatchCleanUnpushed: ("未 push · ローカルのみ", "Unpushed · local only"),
    .dispatchCleanOwnCommitsOne: ("独自コミット %lld 件", "%lld own commit"),
    .dispatchCleanOwnCommitsOther: ("独自コミット %lld 件", "%lld own commits"),
    .dispatchCleanAgentWorking: ("agent 作業中", "agent working"),
    .dispatchCleanAgentWaiting: ("agent 入力待ち", "agent waiting for input"),
    .dispatchCleanPaneOpen: ("タブで表示中", "Open in a tab"),
    .dispatchCleanUnverified: ("情報取得に失敗", "Couldn't fetch info"),
    .dispatchCleanUnverifiedNote: ("%@ を取得できませんでした", "Couldn't fetch %@"),
    .dispatchCleanUnverifiedItemStatus: ("作業ツリーの状態", "working tree status"),
    .dispatchCleanUnverifiedItemOperation: ("停止中の git 操作", "paused git operation"),
    .dispatchCleanUnverifiedItemContainment: ("取り込み判定", "merge status"),
  ]
}
