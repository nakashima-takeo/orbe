import Foundation

/// PR のパネルと PR の diff が GitHub に問い合わせる口。既定（`live`）は本物の gh を呼ぶ。見た目の検証とテストは、これを
/// 差し替えて gh を起動しない。git は手元のリポジトリに直に問い合わせる（ネットに出るのは、コミットを名指しする fetch
/// だけ）。
struct PullRequestSource {
  /// リポジトリ `repo` のブランチ `branch` の PR（→ `GitHubBranchPullRequestLookup`）。
  var branchPullRequests:
    (
      _ repo: GitRepo, _ branch: String,
      _ completion: @escaping (GitHubBranchPullRequests) -> Void
    ) -> Void
  /// ブランチが GitHub に在るか（→ `GitHubCLI.branchExists`）。
  var branchExists:
    (_ ref: GitHubBranchRef, _ completion: @escaping (Result<Bool, GitHubFailure>) -> Void)
      -> Void
  /// PR の中身（→ `GitHubCLI.pullRequestContent`）。
  var content:
    (
      _ id: GitHubItemID,
      _ completion: @escaping (Result<GitHubPullRequestContent, GitHubFailure>) -> Void
    ) -> Void
  /// 確認済みを付ける・外す（→ `GitHubCLI.setViewed`）。
  var setViewed:
    (
      _ viewed: Bool, _ paths: Set<String>, _ nodeID: String,
      _ completion: @escaping (GitHubViewedWrite) -> Void
    ) -> Void

  static func gh(_ cli: GitHubCLI = .shared, cache: GitHubCache = .shared) -> PullRequestSource {
    PullRequestSource(
      branchPullRequests: { repo, branch, completion in
        GitHubBranchPullRequestLookup(gitHub: cli, cache: cache).lookup(
          repo, branches: [branch], completion: completion)
      },
      branchExists: { cli.branchExists($0, completion: $1) },
      content: { cli.pullRequestContent($0, completion: $1) },
      setViewed: { cli.setViewed($0, paths: $1, pullRequest: $2, completion: $3) })
  }
}
