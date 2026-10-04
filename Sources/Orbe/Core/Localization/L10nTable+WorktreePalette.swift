import Foundation

/// worktree パレット（⌘T）の文言。一覧・ベースを選ぶ画面・clean の 3 画面・最新化・3 軸の状態語彙をまとめて持つ。
///
/// **git / gh の語は訳さない**（`[gone]` / `locked` / `PR #N merged` / `merged → <実マージ先>` /
/// `remote +N` / `main worktree`）——訳すと出力と対応が取れなくなる技術語なので、
/// `origin/…` と同じくそのまま出す。ここに無い語はその判断の結果であって、抜けではない。
extension L10n {
  static let worktreePaletteTable: [L10nKey: (ja: String, en: String)] = [
    .worktreePaletteWorktreeCheckout: ("checkout → worktree", "checkout → worktree"),
    .worktreePaletteLaunchSuffix: ("を新しいタブで起動", "· new tab"),
    .worktreePaletteQueryPlaceholder: (
      "worktree・ブランチを検索、または新しいブランチ名",
      "Search worktrees and branches, or type a new branch name"
    ),
    .worktreePaletteTaskQueryPlaceholder: ("worktree・ブランチを検索", "Search worktrees and branches"),
    .worktreePaletteSectionTask: ("%@ の worktree", "worktree for %@"),
    .worktreePaletteSectionThisTask: ("このタスクの worktree", "this task’s worktree"),
    .worktreePaletteTaskTitle: ("『%@』", "“%@”"),
    .worktreePalettePullRequestBranch: ("PR #%lld のブランチ", "PR #%lld branch"),
    .worktreePaletteEffectBegin: (" · %1$@ を進行中に", " · start %1$@"),
    .worktreePaletteEffectBeginReassign: (
      " · %1$@ を進行中に（%2$@ から付け替え）", " · start %1$@ (moved from %2$@)"
    ),
    .worktreePaletteEffectReassign: (" · %2$@ から %1$@ へ付け替え", " · move from %2$@ to %1$@"),
    .worktreePaletteHintRemoveTask: ("外す", "Remove"),
    .worktreePalettePreparing: ("作成中…", "Preparing…"),
    .worktreePaletteHintSelect: ("選択", "Select"),
    .worktreePaletteHintClose: ("閉じる", "Close"),
    .worktreePaletteErrNotGitRepo: (
      "git リポジトリを解決できませんでした", "Couldn't resolve a git repository"
    ),
    .worktreePaletteSectionNewBranch: ("新しいブランチ", "NEW BRANCH"),
    .worktreePaletteThisDirectory: ("このディレクトリ", "This directory"),
    .worktreePaletteCreateSuffix: ("を作る", "— create"),
    .worktreePaletteNoMatch: (
      "一致する worktree・ブランチはありません", "No matching worktrees or branches"
    ),
    .worktreePaletteCurrentTag: ("現在", "current"),
    .worktreePaletteDefaultTag: ("既定", "default"),
    .worktreePaletteTargetLabel: ("起動先", "Launch"),
    .worktreePaletteBaseLabel: ("ベース", "Base"),
    .worktreePaletteHintSwitch: ("切り替え", "Switch"),
    .worktreePaletteBasePreviousTag: ("前回", "last"),
    .worktreePaletteBaseOther: ("ほか…", "Other…"),
    .worktreePaletteBaseNoneWorktree: (
      "なし — 作らずに、既存の worktree を開く", "None — opens the existing worktree as is"
    ),
    .worktreePaletteBaseNoneDirectory: (
      "なし — このディレクトリをそのまま開く", "None — opens this directory as is"
    ),
    .worktreePaletteBaseNoneCheckout: (
      "なし — 新しいブランチは切らず、%1$@ を worktree にする",
      "None — no new branch; makes %1$@ a worktree"
    ),
    .worktreePaletteBaseNoneTrackRemote: (
      "なし — %1$@ を追跡するブランチ %2$@ を作り、worktree にする",
      "None — creates branch %2$@ tracking %1$@ and makes it a worktree"
    ),
    .worktreePaletteBaseNoneClean: (
      "なし — 作らずに、要らなくなった worktree を掃除する",
      "None — cleans up worktrees you no longer need"
    ),
    .worktreePaletteEnterOpen: ("%1$@ で %2$@ を新しいタブで開く", "Open %2$@ in %1$@ in a new tab"),
    .worktreePaletteEnterCheckout: (
      "%1$@ を worktree にして %2$@ で開く", "Make %1$@ a worktree and open %2$@"
    ),
    .worktreePaletteEnterCreate: (
      "%1$@ を %3$@ から作り、%2$@ で開く", "Create %1$@ from %3$@ and open %2$@"
    ),
    .worktreePaletteEnterPickBase: ("ベースを選ぶ", "Choose a base"),
    .worktreePaletteEnterClean: (
      "要らなくなった worktree を選んで掃除する", "Pick worktrees you no longer need and clean them up"
    ),
    .worktreePaletteBaseQueryPlaceholder: ("ベースのブランチを検索", "Search for a base branch"),
    .worktreePaletteBaseNoMatch: ("一致するブランチはありません", "No matching branches"),
    .worktreePaletteBasePickEnter: ("%1$@ をベースにする", "Use %1$@ as the base"),
    .worktreeCleanSubtitle: (
      "要らなくなった worktree を掃除", "Clean up worktrees you no longer need"
    ),
    .worktreeCleanCandidatesOne: ("候補 %lld 件", "%lld candidate"),
    .worktreeCleanCandidatesOther: ("候補 %lld 件", "%lld candidates"),
    .worktreeCleanSelected: ("%lld 件選択中", "%lld selected"),
    .worktreeCleanBack: ("esc 戻る", "esc Back"),
    .worktreeCleanSectionSafe: (
      "安全 — worktree を削除（対象によってはローカルブランチも削除）",
      "Safe — deletes the worktree (and, for some, its local branch)"
    ),
    .worktreeCleanSectionCaution: ("確認 — 消えるものがあります", "Check — something will be lost"),
    .worktreeCleanSectionInUse: ("使用中 — 削除できません", "In use — can't be deleted"),
    .worktreeCleanKeyHint: (
      "space 選択 · ←→ ブランチの扱い",
      "space Select · ←→ Branch"
    ),
    .worktreeCleanExecute: ("⌘⏎ %@を削除", "⌘⏎ Delete %@"),
    .worktreeCleanExecuteWithBranches: ("⌘⏎ %@と%@を削除", "⌘⏎ Delete %@ (+%@)"),
    .worktreeCleanExecuteWorktreesOne: ("worktree %lld 件", "%lld worktree"),
    .worktreeCleanExecuteWorktreesOther: ("worktree %lld 件", "%lld worktrees"),
    .worktreeCleanExecuteBranchesOne: ("ローカルブランチ %lld 件", "%lld branch"),
    .worktreeCleanExecuteBranchesOther: ("ローカルブランチ %lld 件", "%lld branches"),
    .worktreeCleanBranchLabel: ("ブランチ %@:", "Branch %@:"),
    .worktreeCleanBranchKeep: ("残す", "Keep"),
    .worktreeCleanBranchDelete: ("削除", "Delete"),
    .worktreeCleanLossNote: ("%@ も消えます", "%@ will be lost too"),
    .worktreeCleanDeletingTitle: ("削除中", "Deleting"),
    .worktreeCleanProgress: ("%lld / %lld 件", "%lld / %lld"),
    .worktreeCleanCollapsedNote: ("未選択の行は畳んで非表示", "Unselected rows are collapsed"),
    .worktreeCleanCancelHint: (
      "esc 中断(実行済みは戻りません)", "esc Stop (what's done stays done)"
    ),
    .worktreeCleanRowRemoved: ("worktree を削除しました", "Removed the worktree"),
    .worktreeCleanRowRemovedWithBranch: (
      "worktree と %@ を削除しました", "Removed the worktree and %@"
    ),
    .worktreeCleanRowPruned: ("prune しました(実体なし)", "Pruned (no directory)"),
    .worktreeCleanRowPrunedWithBranch: (
      "prune と %@ を削除しました(実体なし)", "Pruned (no directory) and removed %@"
    ),
    .worktreeCleanRowRunning: ("worktree rm 実行中…", "Running worktree rm…"),
    .worktreeCleanRowPending: ("待機中 — worktree を削除", "Waiting — delete the worktree"),
    .worktreeCleanRowPendingWithBranch: (
      "待機中 — worktree + ブランチを削除", "Waiting — delete the worktree + branch"
    ),
    .worktreeCleanRowSkipped: ("中断のため未実行", "Not run (stopped)"),
    .worktreeCleanDoneTitle: ("完了(%lld 件失敗)", "Done (%lld failed)"),
    .worktreeCleanTally: ("%lld 成功 · %lld 失敗", "%lld succeeded · %lld failed"),
    .worktreeCleanRetryAll: ("⏎ 失敗分を再試行", "⏎ Retry the failures"),
    .worktreeCleanClose: ("esc 閉じる", "esc Close"),
    .worktreeCleanRetry: ("⏎ 再試行", "⏎ Retry"),
    .worktreeCleanOpenTab: ("o タブで開く", "o Open in a tab"),
    .worktreeCleanFailedDirty: (
      "未コミットの変更があるため中止しました", "Stopped: there are uncommitted changes"
    ),
    .worktreeCleanFailedOperation: (
      "git 操作が進行中のため中止しました", "Stopped: a git operation is in progress"
    ),
    .worktreeCleanFailedWorktree: (
      "削除できませんでした — タブで使用中の可能性", "Couldn't delete — may be in use by a tab"
    ),
    .worktreeCleanFailedBranch: (
      "worktree は削除 · ブランチは残しました", "Worktree removed · branch kept"
    ),
    .worktreeCleanPrunable: ("prunable · 実体なし", "prunable · no directory"),
    .worktreeCleanUncommittedOne: ("未コミット %lld ファイル", "%lld uncommitted file"),
    .worktreeCleanUncommittedOther: ("未コミット %lld ファイル", "%lld uncommitted files"),
    .worktreeCleanUntrackedOne: ("untracked %lld ファイル", "%lld untracked file"),
    .worktreeCleanUntrackedOther: ("untracked %lld ファイル", "%lld untracked files"),
    .worktreeCleanInProgress: ("%@ 進行中", "%@ in progress"),
    .worktreeCleanOnRemote: ("リモート反映済み", "On remote"),
    .worktreeCleanUnpushed: ("未 push · ローカルのみ", "Unpushed · local only"),
    .worktreeCleanOwnCommitsOne: ("独自コミット %lld 件", "%lld own commit"),
    .worktreeCleanOwnCommitsOther: ("独自コミット %lld 件", "%lld own commits"),
    .worktreeCleanAgentWorking: ("agent 作業中", "agent working"),
    .worktreeCleanAgentWaiting: ("agent 入力待ち", "agent waiting for input"),
    .worktreeCleanTabOpen: ("タブで表示中", "Open in a tab"),
    .worktreeCleanUnverified: ("情報取得に失敗", "Couldn't fetch info"),
    .worktreePaletteRefreshSection: ("worktree の作り方", "How to create the worktree"),
    .worktreePaletteRefreshTitle: ("最新化して作成", "Update, then create"),
    .worktreePaletteRefreshAsIsTitle: ("そのまま作成", "Create as is"),
    .worktreePaletteRefreshDesc: (
      "fetch → fast-forward → %@ と同じ地点から", "fetch → fast-forward → start from %@"
    ),
    .worktreePaletteRefreshAsIsDesc: ("ローカルの %@ のまま · %@", "local %@ as is · %@"),
    .worktreePaletteRefreshBehindOne: (
      "— %1$@ より %2$lld コミット遅れています", "— %2$lld commit behind %1$@"
    ),
    .worktreePaletteRefreshBehindOther: (
      "— %1$@ より %2$lld コミット遅れています", "— %2$lld commits behind %1$@"
    ),
    .worktreePaletteRefreshFailedHeader: ("— 最新化に失敗（%@）", "— update failed (%@)"),
    .worktreePaletteRefreshFailedDesc: ("%@ に失敗 — %@", "%@ failed — %@"),
    .worktreePaletteRefreshDiverged: ("%@ と分岐", "diverged from %@"),
    .worktreePaletteRefreshRetry: ("r 再試行", "r Retry"),
    .worktreePaletteHintRetry: ("再試行", "Retry"),
    .worktreePaletteHintBack: ("戻る", "Back"),
    .worktreePalettePrepRefreshed: (
      "を最新化してcheckoutしたworktreeで", "· updated checkout worktree ·"
    ),
    .worktreePalettePrepAsIs: ("をそのままcheckoutしたworktreeで", "· checkout worktree as is ·"),
    .worktreePaletteRefreshing: (
      "最新化中… %@ を fetch → fast-forward", "Updating… fetch → fast-forward %@"
    ),
  ]
}
