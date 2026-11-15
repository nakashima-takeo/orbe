import Foundation

/// エディター面の PR の diff の文言分冊。本体 `L10n.table` が結合する。
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
  ]
}
