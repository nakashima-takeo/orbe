import Foundation

/// エディター面の PR のパネルと PR の diff の文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let pullRequestTable: [L10nKey: (ja: String, en: String)] = [
    .editorDiffPullRequest: ("（PR #%lld）", "(PR #%lld)"),
    .editorDiffNowherePullRequest: ("PR のどちらの側にもありません", "Not in either side of the PR"),
    .editorDiffPullRequestCommitsMissing: (
      "PR のコミットを取得できないため、差分を表示できません",
      "Can’t show the diff because the PR’s commits couldn’t be fetched"
    ),
    .editorDiffPullRequestUnrelated: (
      "ベースブランチと共通のコミットがないため、差分を表示できません",
      "Can’t show the diff because the PR shares no commits with its base branch"
    ),
    .editorRailPullRequest: ("プルリクエスト", "Pull Request"),
    .editorPrTitle: ("プルリクエスト", "Pull Request"),
    .editorPrRefresh: ("再読込", "Refresh"),
    .editorPrOpenOnGitHub: ("GitHub で開く", "Open on GitHub"),
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
    .editorPrTreeView: ("ツリー表示", "View as Tree"),
    .editorPrListView: ("リスト表示", "View as List"),
    .editorPrOlderCommitsHidden: ("古いコミット %lld 件は表示していません", "Older commits not shown: %lld"),
    .editorPrMarkViewed: ("確認済みにする", "Viewed"),
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
  ]
}
