import Foundation

/// 前回取得した gh 結果（正式名・ブランチの PR）を手元のリポジトリ単位で保持する置き場。⌘T の行の札と clean・PR の
/// 自動の結び付けが読む。前回結果は次に開いたときの先描き（stale-while-revalidate）の元になる。保存先は
/// この型に閉じており、ディスク永続へ移す場合もここの中だけを差し替える。
/// キーは `GitRepo.commonDir`（worktree 間で共有される唯一の識別子）。
/// メインスレッド専用（呼び出し側はメインスレッドで呼び、`GitHubCLI` の completion もメインで返る
/// 契約に乗るため、ロックは張らない）。
final class GitHubCache {
  static let shared = GitHubCache()

  struct Entry {
    /// head → その head の PR。**キーが無い＝未取得**（`[]` は 0 件）。区別を head 単位に保つ
    /// ——1 本の失敗が、他の head の先描きを消さない。
    var branchPullRequests: [String: [GitHubBranchPR]] = [:]
    /// remote の URL から読んだ名前 → GitHub の答え。**キーが無い＝まだ答えを得ていない**。
    /// `.unverified` も書く——次に開いたときは最初のフレームからその扱いで描き、裏で問い直す。
    var repositoryNames: [GitHubRepoName: GitHubRepositoryResolution] = [:]
  }

  private var entries: [String: Entry] = [:]

  func entry(for key: String) -> Entry? { entries[key] }

  /// 正式名は remote ごとに問い合わせて届くので、保存も読んだ名前の単位。
  func setRepositoryName(
    _ resolution: GitHubRepositoryResolution, for name: GitHubRepoName, key: String
  ) {
    entries[key, default: Entry()].repositoryNames[name] = resolution
  }

  /// ブランチの PR は head 単位で到着し head 単位で失敗するので、保存も head 単位。
  func setBranchPullRequests(_ pullRequests: [GitHubBranchPR], head: String, for key: String) {
    entries[key, default: Entry()].branchPullRequests[head] = pullRequests
  }
}
