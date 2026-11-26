import Foundation

/// エディター面の PR のパネルと PR の diff の文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let pullRequestTable: [L10nKey: (ja: String, en: String)] = [
    .editorPrNoFiles: ("変更ファイルなし", "No Files Changed"),
    .editorPrNoFilesLead: (
      "このプルリクエストで変更されたファイルはありません。", "This pull request doesn’t change any files."
    ),
    .editorDiffNowherePullRequest: ("PR のどちらの側にもありません", "Not in either side of the PR"),
    .editorDiffPullRequestCommitsMissing: (
      "PR のコミットを取得できないため、差分を表示できません",
      "Can’t show the diff because the PR’s commits couldn’t be fetched"
    ),
    .editorDiffPullRequestUnrelated: (
      "ベースブランチと共通のコミットがないため、差分を表示できません",
      "Can’t show the diff because the PR shares no commits with its base branch"
    ),
    .editorPrTitle: ("プルリクエスト", "Pull Request"),
    .editorPrRefresh: ("再読込", "Refresh"),
    .editorPrOpenOnGitHub: ("GitHub で開く", "Open on GitHub"),
    .editorPrBarChip: ("プルリクエスト #%lld、%@ → %@", "Pull request #%lld, %@ → %@"),
    .editorPrInSync: ("この worktree でチェックアウト済み", "Checked out in this worktree"),
    .editorPrUnpushed: ("未 push のコミットが %lld 件あります", "Unpushed commits: %lld"),
    .editorPrUnfetched: ("PR に未取得のコミットが %lld 件あります", "Commits in the PR not fetched: %lld"),
    .editorPrHeadDiffers: (
      "この worktree の HEAD は PR の先頭と違います", "This worktree’s HEAD differs from the PR’s head"
    ),
    .editorPrDescription: ("説明", "Description"),
    .editorPrCommits: ("コミット", "Commits"),
    .editorPrFiles: ("変更ファイル", "Files Changed"),
    .editorPrViewedCount: ("%lld/%lld 確認済み", "%lld/%lld viewed"),
    .editorPrMarkViewed: ("確認済みにする", "Mark as viewed"),
    .editorPrUnmarkViewed: ("確認済みを外す", "Unmark as viewed"),
    .editorPrTreeView: ("ツリー表示", "View as Tree"),
    .editorPrListView: ("リスト表示", "View as List"),
    .editorPrOlderCommitsHidden: ("古いコミット %lld 件は表示していません", "Older commits not shown: %lld"),
    .editorPrCreate: ("プルリクエストを作成", "Create Pull Request"),
    .editorPrPublishFirst: ("先にブランチを公開してください", "Publish the branch first"),
    .editorPrNotDetached: ("ブランチにいません", "Not on a branch"),
    .editorPrNotDefaultBranch: (
      "既定のブランチではプルリクエストを表示・作成しません",
      "Pull requests aren’t shown or created for the default branch"
    ),
    .editorPrNotGitHub: ("GitHub のリポジトリではありません", "Not a GitHub repository"),
    .editorPrUnverified: (
      "GitHub のどのリポジトリかを確かめられません", "Can’t verify which GitHub repository this is"
    ),
    .editorPrGhMissing: (
      "gh が見つかりません — プルリクエストを表示するには gh をインストールしてください",
      "gh isn’t installed — install gh to show pull requests"
    ),
    .editorPrGhUnauthed: (
      "gh が認証されていません — gh auth login で認証してください", "gh isn’t signed in — run gh auth login"
    ),
    .editorPrFailedUnauthenticated: (
      "GitHub の認証が拒否されました — gh auth login で認証し直してください",
      "GitHub rejected the sign-in — run gh auth login again"
    ),
    .editorPrFailedRateLimited: (
      "GitHub のレート制限に達しました。しばらくしてから再読込してください",
      "GitHub rate limit reached. Refresh again later"
    ),
    .editorPrFailedUnreachable: ("GitHub に接続できません", "Can’t reach GitHub"),
    .editorPrFailedTimedOut: ("GitHub の応答がありません", "GitHub didn’t respond"),
    .editorPrFailedRead: ("GitHub から取得できませんでした", "Couldn’t fetch from GitHub"),
    .editorPrFailedWrite: ("GitHub に反映できませんでした", "Couldn’t update GitHub"),
    .editorPrThreadLine: ("行 %lld", "Line %lld"),
    .editorPrThreadPending: ("未送信", "Pending"),
    .editorPrThreadResolved: ("解決済み", "Resolved"),
    .editorPrThreadResolve: ("解決", "Resolve"),
    .editorPrThreadUnresolve: ("解決を取り消す", "Unresolve"),
    .editorPrThreadCollapse: ("折りたたむ", "Collapse"),
    .editorPrThreadExpand: ("展開", "Expand"),
    .editorPrThreadAdd: ("レビューに追加", "Add to Review"),
    .editorPrThreadResolveReply: ("解決して返信", "Reply and Resolve"),
    .editorPrThreadCancel: ("取り消す", "Cancel"),
    .editorPrThreadReplyPlaceholder: ("返信", "Reply"),
    .editorPrThreadNotReady: (
      "PR の最新の内容を読み込んでから、もう一度お試しください", "Try again after the latest pull request is loaded"
    ),
    .editorPrThreadNotCurrent: (
      "この PR のレビューは、PR のブランチの worktree か GitHub で送信してください",
      "Send this pull request’s review from a worktree on its branch or on GitHub"
    ),
    .editorPrThreadLineGone: ("この行は現在の diff にありません", "This line isn’t in the current diff"),
    .editorPrThreadDetached: (
      "このスレッドは現在の diff の行に付いていません", "This thread isn’t on a line of the current diff"
    ),
    .editorPrThreadDeleted: ("このスレッドは GitHub から削除されました", "This thread was deleted on GitHub"),
    .editorPrWriteTimedOut: (
      "GitHub の応答がありません。反映されたかは GitHub で確かめてください",
      "GitHub didn’t respond. Check on GitHub whether it was applied"
    ),
    .editorPrReview: ("レビュー", "Review"),
    .editorPrReviewPending: ("未送信のコメント %lld", "Pending comments: %lld"),
    .editorPrReviewButtonPending: (
      "レビュー、未送信のコメント %lld", "Review, pending comments: %lld"
    ),
    .editorPrReviewOverall: ("全体へのコメント", "Overall Comment"),
    .editorPrReviewApprove: ("承認", "Approve"),
    .editorPrReviewComment: ("コメント", "Comment"),
    .editorPrReviewRequestChanges: ("変更を依頼", "Request Changes"),
    .editorPrReviewSubmit: ("レビューを送信", "Submit Review"),
    .editorPrReviewAwaitsLatest: (
      "PR の最新の内容を読み込むまで送信できません", "Can’t submit until the latest pull request is loaded"
    ),
    .editorPrReviewStoppedAligning: (
      "PR の最新の内容を揃えて読めませんでした。再読込してください",
      "Couldn’t load a consistent version of the pull request. Refresh to try again"
    ),
    .editorPrReviewNoDiff: (
      "PR の diff を表示できないため、送信できません。再読込するか、GitHub で送信してください",
      "Can’t submit because the pull request diff can’t be shown. Refresh, or submit on GitHub"
    ),
    .editorPrViewedFailed: ("確認済みを反映できませんでした（%@）", "Couldn’t update Viewed (%@)"),
    .editorPrViewedTimedOut: (
      "確認済みの書き込みに GitHub の応答がありません。反映されたかは GitHub で確かめてください",
      "GitHub didn’t respond to the Viewed update. Check on GitHub whether it went through."
    ),
    .editorPrSubmitFailed: ("レビューを送信できませんでした（%@）", "Couldn’t submit the review (%@)"),
    .editorPrSubmitTimedOut: (
      "レビューの送信に GitHub の応答がありません。反映されたかは GitHub で確かめてください",
      "GitHub didn’t respond to the review submission. Check on GitHub whether it went through."
    ),
    .editorPrReviewReadFailed: (
      "レビューのコメントを読み込めません（%@）", "Couldn’t load review comments (%@)"
    ),
    .editorPrCommentCount: ("コメント %lld 件", "Comments: %lld"),
    .editorPrOutdatedThreads: (
      "現在の diff に表示できない未解決のスレッド %lld 件",
      "Unresolved threads not in the current diff: %lld"
    ),
  ]
}
