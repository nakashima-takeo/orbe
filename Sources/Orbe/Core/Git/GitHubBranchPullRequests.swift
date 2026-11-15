import Foundation

/// ブランチの PR を引けない理由（GitHub のどのブランチかが決まらない）。
enum GitHubBranchPullRequestsUnavailable: Equatable {
  /// gh が PATH に無い。
  case ghMissing
  /// gh はあるが認証情報を持っていない。
  case ghUnauthed
  /// GitHub のブランチでない（origin が GitHub でない・push 先の remote が GitHub でない）。
  case notGitHub
  /// GitHub のどのブランチかを確かめられない（push 先の remote の正式名を確かめられない・push 先が台帳に無い・remote の
  /// 一覧を読めない）。
  case unverified

  /// gh の可否が「使える」でないときの、PR を引けない理由。使えるなら nil。
  init?(_ availability: GitHubAvailability) {
    switch availability {
    case .ready: return nil
    case .ghMissing: self = .ghMissing
    case .ghUnauthed: self = .ghUnauthed
    case .notGitHub: self = .notGitHub
    }
  }
}

/// リポジトリ 1 つの、名指ししたブランチごとの PR。
struct GitHubBranchPullRequests: Equatable {
  enum Branch: Equatable {
    /// GitHub のどのブランチかが決まらず、PR を引けない。
    case unavailable(GitHubBranchPullRequestsUnavailable)
    /// GitHub のブランチ `ref` と決まった。PR は head が `ref` と等しいもの（作成日時の新しい順）か、問い合わせの失敗。
    case gitHub(GitHubBranchRef, pullRequests: Result<[GitHubBranchPR], GitHubFailure>)

    /// PR の一覧（引けない・問い合わせが失敗したなら nil）。
    var pullRequests: [GitHubBranchPR]? {
      guard case .gitHub(_, .success(let pullRequests)) = self else { return nil }
      return pullRequests
    }
  }

  let availability: GitHubAvailability
  /// remote の台帳。gh が使えなければ nil（正式名を問い合わせない）。
  let ledger: GitHubRemoteLedger.Resolved?
  /// 名指ししたブランチ名 → 答え。
  let branches: [String: Branch]
}

/// リポジトリとブランチ名から、ブランチごとの GitHub 上の同一性と、そのブランチを head とする PR を引く（画面に依らない）。
/// どの PR を選ぶかは使う側が決める。
///
/// 手順: ローカルブランチ・origin が GitHub か・remote の一覧を並行して読む → gh の可否 → 正式名（キャッシュに正式名が無い
/// 名前だけ問い合わせ、キャッシュへ書く）→ 台帳 → ブランチの同一性 → 同一性が GitHub のブランチと決まったものだけ `gh pr list` →
/// head の照合。同一性は ⌘T の clean と同じ規則（push 先の remote の正式名＋ローカル名）で、他人の fork の同名ブランチの
/// PR を取り違えない。取れたブランチの PR はキャッシュにも書く（次に ⌘T を開いたとき、取り直しを待たずに描く材料になる）。
/// 全メソッドはメインスレッドで呼ばれ、メインスレッドで返る。
final class GitHubBranchPullRequestLookup {
  private let gitHub: GitHubCLI
  private let cache: GitHubCache

  init(gitHub: GitHubCLI = .shared, cache: GitHubCache = .shared) {
    self.gitHub = gitHub
    self.cache = cache
  }

  func lookup(
    _ repo: GitRepo, branches: Set<String>,
    completion: @escaping (GitHubBranchPullRequests) -> Void
  ) {
    var localBranches: [GitBranch] = []
    var isGitHub = false
    var remotes: [String: String]?
    let facts = DispatchGroup()
    facts.enter()
    repo.localBranches {
      localBranches = $0
      facts.leave()
    }
    facts.enter()
    repo.originIsGitHub {
      isGitHub = $0
      facts.leave()
    }
    facts.enter()
    repo.remotes {
      remotes = $0
      facts.leave()
    }
    facts.notify(queue: .main) {
      self.gitHub.probe(cwd: repo.root, isGitHub: isGitHub) { availability in
        if let reason = GitHubBranchPullRequestsUnavailable(availability) {
          let unavailable = GitHubBranchPullRequests.Branch.unavailable(reason)
          return completion(
            GitHubBranchPullRequests(
              availability: availability, ledger: nil,
              branches: Dictionary(uniqueKeysWithValues: branches.map { ($0, unavailable) })))
        }
        self.ledger(repo, remotes: remotes) { resolved in
          let identities = GitHubBranchIdentities(
            resolved: resolved, localBranches: localBranches)
          var answers: [String: GitHubBranchPullRequests.Branch] = [:]
          var refs: [String: GitHubBranchRef] = [:]
          for branch in branches {
            switch identities.local(branch) {
            case .ref(let ref): refs[branch] = ref
            case .notGitHub: answers[branch] = .unavailable(.notGitHub)
            case .unverified: answers[branch] = .unavailable(.unverified)
            }
          }
          self.pullRequests(repo, refs: refs) { fetched in
            for (branch, result) in fetched {
              guard let ref = refs[branch] else { continue }
              answers[branch] = .gitHub(ref, pullRequests: result)
            }
            completion(
              GitHubBranchPullRequests(availability: .ready, ledger: resolved, branches: answers))
          }
        }
      }
    }
  }

  /// remote の台帳。キャッシュに正式名がある名前はそれを使い、無い名前（「確かめられない」を含む）は問い合わせてキャッシュへ
  /// 書く。
  private func ledger(
    _ repo: GitRepo, remotes: [String: String]?,
    completion: @escaping (GitHubRemoteLedger.Resolved) -> Void
  ) {
    let names = Set((remotes ?? [:]).values.compactMap(GitHubRepoName.init(remoteURL:)))
    let asked = DispatchGroup()
    for name in names {
      if case .found = cache.entry(for: repo.commonDir)?.repositoryNames[name] { continue }
      asked.enter()
      gitHub.resolveRepository(cwd: repo.root, name: name) { resolution in
        self.cache.setRepositoryName(resolution, for: name, key: repo.commonDir)
        asked.leave()
      }
    }
    asked.notify(queue: .main) {
      let answers = self.cache.entry(for: repo.commonDir)?.repositoryNames ?? [:]
      guard case .settled(let resolved) = GitHubRemoteLedger(remotes: remotes, answers: answers)
      else { return completion(GitHubRemoteLedger.Resolved(repositories: nil)) }
      completion(resolved)
    }
  }

  /// ブランチごとの、head が同一性と等しい PR。
  private func pullRequests(
    _ repo: GitRepo, refs: [String: GitHubBranchRef],
    completion: @escaping ([String: Result<[GitHubBranchPR], GitHubFailure>]) -> Void
  ) {
    guard !refs.isEmpty else { return completion([:]) }
    var landed: [String: Result<[GitHubBranchPR], GitHubFailure>] = [:]
    gitHub.branchPullRequests(cwd: repo.root, heads: Array(refs.keys)) { head, fetched in
      guard let ref = refs[head] else { return }
      if case .success(let pullRequests) = fetched {
        self.cache.setBranchPullRequests(pullRequests, head: head, for: repo.commonDir)
      }
      landed[head] = fetched.map { GitHubBranchPR.filter($0, headedBy: ref) }
      if landed.count == refs.count { completion(landed) }
    }
  }
}
