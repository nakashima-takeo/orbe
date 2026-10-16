import Foundation

/// エディター面のソース管理の文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let sourceControlTable: [L10nKey: (ja: String, en: String)] = [
    .editorRailSourceControl: ("ソース管理", "Source Control"),
    .editorScmTitle: ("ソース管理", "Source Control"),
    .editorScmStaged: ("ステージされている変更", "Staged Changes"),
    .editorScmChanges: ("変更", "Changes"),
    .editorScmGraph: ("ソース管理グラフ", "Source Control Graph"),
    .editorScmPlaceholderBranch: ("メッセージ (⌘↵ で \"%@\" にコミット)", "Message (⌘↵ to commit on \"%@\")"),
    .editorScmPlaceholder: ("メッセージ (⌘↵ でコミット)", "Message (⌘↵ to commit)"),
    .editorScmCommit: ("コミット", "Commit"),
    .editorScmSync: ("同期", "Sync Changes"),
    .editorScmPublish: ("ブランチを公開", "Publish Branch"),
    .editorScmMoreActions: ("その他の操作", "More Actions"),
    .editorScmCommitActions: ("その他のコミット操作", "More Commit Actions"),
    .editorScmAmend: ("コミット (amend)", "Commit (Amend)"),
    .editorScmCommitAndPush: ("コミットしてプッシュ", "Commit & Push"),
    .editorScmUndo: ("最後のコミットを取り消す", "Undo Last Commit"),
    .editorScmPull: ("プル", "Pull"),
    .editorScmPush: ("プッシュ", "Push"),
    .editorScmFetch: ("フェッチ", "Fetch"),
    .editorScmRefresh: ("再読込", "Refresh"),
    .editorScmOpenFile: ("ファイルを開く", "Open File"),
    .editorScmStage: ("変更をステージ", "Stage Changes"),
    .editorScmUnstage: ("ステージを解除", "Unstage Changes"),
    .editorScmDiscard: ("変更を破棄", "Discard Changes"),
    .editorScmStageAll: ("すべての変更をステージ", "Stage All Changes"),
    .editorScmUnstageAll: ("すべてのステージを解除", "Unstage All Changes"),
    .editorScmDiscardAll: ("すべての変更を破棄", "Discard All Changes"),
    .editorScmShowMore: ("さらに表示", "Show More"),
    .editorScmStop: ("止める", "Stop"),
    .editorScmRunningStage: ("ステージ中", "Staging"),
    .editorScmRunningUnstage: ("ステージを解除中", "Unstaging"),
    .editorScmRunningDiscard: ("変更を破棄中", "Discarding"),
    .editorScmRunningCommit: ("コミット中", "Committing"),
    .editorScmRunningAmend: ("コミット中 (amend)", "Committing (Amend)"),
    .editorScmRunningUndo: ("コミットを取り消し中", "Undoing Commit"),
    .editorScmRunningPull: ("プル中", "Pulling"),
    .editorScmRunningPush: ("プッシュ中", "Pushing"),
    .editorScmRunningFetch: ("フェッチ中", "Fetching"),
    .editorScmRunningSync: ("同期中", "Syncing"),
    .editorScmRunningPublish: ("ブランチを公開中", "Publishing Branch"),
    .editorScmRunningCommitAndPush: ("コミットしてプッシュ中", "Committing & Pushing"),
    .editorScmNotManaged: ("このフォルダは git で管理されていません", "This folder isn't a git repository"),
    .editorScmDiscardTitleOne: ("\"%@\" の変更を破棄しますか？", "Discard changes in \"%@\"?"),
    .editorScmDiscardTitleOther: ("%lld 件のファイルの変更を破棄しますか？", "Discard changes in %lld files?"),
    .editorScmDiscardMessage: (
      "作業ツリーを index の版に戻します。この操作は元に戻せません。",
      "The working tree goes back to the staged version. This can't be undone."
    ),
    .editorScmDiscardUntracked: ("未追跡の %lld 件はゴミ箱へ移します。", "%lld untracked files go to the Trash."),
    .editorScmDiscardConfirm: ("破棄", "Discard"),
    .editorScmFailureAuthentication: (
      "認証できませんでした。端末で git の認証（ssh の鍵・資格情報）を設定してください。",
      "Authentication failed. Set up git authentication (ssh key or credentials) in the terminal."
    ),
    .editorScmFailureHostKey: (
      "ホストの鍵を確かめられません。端末で一度 ssh で接続して鍵を登録してください。",
      "The host key couldn't be verified. Connect once with ssh in the terminal to add it."
    ),
    .editorScmFailurePushRejected: (
      "push できませんでした。リモートに取り込んでいない変更があります。先にプルしてください。",
      "Push was rejected. The remote has changes you don't have yet. Pull first."
    ),
    .editorScmFailureConflicted: (
      "プルが競合で止まりました（%@）。競合を解決してコミットしてください。rebase なら端末で続けてください。",
      "Pull stopped on conflicts (%@). Resolve them and commit, or continue the rebase in the terminal."
    ),
    .editorScmFailureInProgress: (
      "%@ の途中です。端末で終えてからプルしてください。", "A %@ is in progress. Finish it in the terminal, then pull."
    ),
    .editorScmFailureDetached: (
      "ブランチに居ないため（detached HEAD）、プル・プッシュできません。",
      "Not on a branch (detached HEAD), so you can't pull or push."
    ),
    .editorScmFailureNoUpstream: (
      "このブランチには upstream がありません。先にブランチを公開してください。",
      "This branch has no upstream. Publish the branch first."
    ),
    .editorScmFailureNoPushDestination: (
      "push 先の remote がありません。端末で remote を追加してください。",
      "There's no remote to push to. Add one in the terminal."
    ),
    .editorScmFailureShallow: (
      "shallow clone の境界のコミットは取り消せません。", "The commit at the shallow clone boundary can't be undone."
    ),
  ]
}
