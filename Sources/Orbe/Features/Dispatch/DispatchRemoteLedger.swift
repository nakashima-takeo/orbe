import Foundation

/// remote の台帳。worktree / branch 行が「GitHub のどのリポジトリのどのブランチか」（`GitHubBranchRef`）を
/// 決める唯一の置き場で、行と PR の同一性（チップ・PR 行の行き先・clean の突き合わせ）はすべてここを
/// 通る。provider が remote の一覧（git）と正式名の問い合わせの状態から、そのつど導く（保存しない）。
///
/// 「確定したか」は最上位の case だけが表す。確定するまでは行の同一性も「まだ分からない」で、
/// 確定した台帳の `nil`（GitHub の行でない）とは型で分かれる。
enum DispatchRemoteLedger: Equatable {
  /// GitHub の remote に、正式名がまだ分からないもの（問い合わせ中・未発行）がある。
  case pending
  /// どの remote が GitHub のどのリポジトリかを決められなかった（正式名の問い合わせの失敗・remote の
  /// 一覧が読めない・GitHub の URL からリポジトリ名を読めない）。
  case failed
  case settled(Resolved)

  /// 全 remote の正式名が確定した台帳。問いは必ず答えを返し、`nil` は「GitHub の行でない＝どの PR とも
  /// 等しくない」という確定した答え。
  struct Resolved: Equatable {
    /// upstream を持たない行を push 先とみなす remote。fetch を信頼する remote
    /// （`DispatchBranchSync.trustedRemote`）とは別の関心で、片方を変えてももう片方は変わらない。
    static let defaultRemote = "origin"

    /// remote 名 → 正式名（`nil` = GitHub でない・存在しない）。
    let repositories: [String: GitHubRepoName?]

    /// ローカルブランチの ref。upstream の remote が台帳にあれば（その remote の正式名, remote 側の
    /// ブランチ名）、upstream が無い・台帳に無い remote を追跡している（ローカルブランチを追跡する `.` 等）
    /// なら（既定 remote の正式名, ローカル名）。
    func ref(forLocal name: String, upstream: GitUpstream?) -> GitHubBranchRef? {
      if let upstream, let entry = repositories[upstream.remote] {
        guard let repo = entry else { return nil }
        let prefix = "refs/heads/"
        let branch =
          upstream.remoteRef.hasPrefix(prefix)
          ? String(upstream.remoteRef.dropFirst(prefix.count)) : upstream.remoteRef
        return GitHubBranchRef(repo: repo, branch: branch)
      }
      guard let repo = repositories[Self.defaultRemote] ?? nil else { return nil }
      return GitHubBranchRef(repo: repo, branch: name)
    }

    /// remote 追跡ブランチ（`origin/feat/x`）の ref。remote 名は台帳の名前で切り分ける（`/` を含む
    /// remote 名もあるので、一致する最も長い名前を採る）。
    func ref(forRemoteBranch name: String) -> GitHubBranchRef? {
      let remote = repositories.keys.filter { name.hasPrefix($0 + "/") }.max { $0.count < $1.count }
      guard let remote, let repo = repositories[remote] ?? nil else { return nil }
      return GitHubBranchRef(repo: repo, branch: String(name.dropFirst(remote.count + 1)))
    }
  }

  /// remote の一覧（remote 名 → URL）と正式名の状態から台帳を導く。`resolutions` は GitHub が答えた
  /// 正式名（読んだ名前 → 結果）、`failed` は今回の問い合わせが失敗した読んだ名前。
  ///
  /// 全体で待つ——行が使わない remote まで待つが、remote は通常 1〜3 本で待ちは変わらず、
  /// 「確定したか」の規則が 1 つで済む。
  init(
    remotes: [String: String], resolutions: [GitHubRepoName: GitHubRepositoryResolution],
    failed: Set<GitHubRepoName>
  ) {
    var repositories: [String: GitHubRepoName?] = [:]
    var hasFailure = false
    for (remote, url) in remotes {
      let canonical: GitHubRepoName?
      if let read = GitHubRepoName(remoteURL: url) {
        switch resolutions[read] {
        case .found(let name): canonical = name
        case .notFound: canonical = nil
        case nil:
          guard failed.contains(read) else {
            self = .pending
            return
          }
          hasFailure = true
          continue
        }
      } else if GitHubRepoName.isGitHub(remoteURL: url) {
        // GitHub の remote なのにリポジトリ名を読めない。「GitHub の行でない」と確定させると、clean が
        // その remote を追跡する行の PR の事実を「確かめて 0 件」と読むので、分からないまま失敗にする。
        hasFailure = true
        continue
      } else {
        canonical = nil
      }
      repositories.updateValue(canonical, forKey: remote)
    }
    self = hasFailure ? .failed : .settled(Resolved(repositories: repositories))
  }
}
