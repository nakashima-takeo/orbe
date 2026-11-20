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
/// PR を取り違えない。取れたブランチの PR はキャッシュに書かない——キャッシュのブランチの PR は ⌘T の clean が gh の既定の
/// リポジトリから取った値で、この段は問い合わせ先が違う（push 先と親）。
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
              ledger: nil,
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
              GitHubBranchPullRequests(ledger: resolved, branches: answers))
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

  /// ブランチごとの、head が同一性と等しい PR。問い合わせ先は、同一性のリポジトリ（push 先）と、それが fork なら親の
  /// リポジトリ——fork から親へ出した PR も、fork の中の PR も引く。gh の既定（作業ディレクトリの remote から選ぶ
  /// リポジトリ）に任せると、remote の名前の付け方で引ける PR が変わる。どれか 1 つの問い合わせが失敗すれば、その
  /// ブランチの答えは失敗（ほかの問い合わせの PR だけで「無い」と読ませない）。
  private func pullRequests(
    _ repo: GitRepo, refs: [String: GitHubBranchRef],
    completion: @escaping ([String: Result<[GitHubBranchPR], GitHubFailure>]) -> Void
  ) {
    guard !refs.isEmpty else { return completion([:]) }
    let parents = Self.parents(cache.entry(for: repo.commonDir)?.repositoryNames ?? [:])
    var targets: [String: [GitHubRepoName]] = [:]
    for (branch, ref) in refs {
      targets[branch] = [ref.repo] + (parents[ref.repo].map { [$0] } ?? [])
    }
    let queries = refs.keys.sorted().flatMap { branch in
      (targets[branch] ?? []).map { GitHubBranchPRQuery(head: branch, repository: $0) }
    }
    var fetched: [GitHubBranchPRQuery: Result<[GitHubBranchPR], GitHubFailure>] = [:]
    var landed: [String: Result<[GitHubBranchPR], GitHubFailure>] = [:]
    gitHub.branchPullRequests(cwd: repo.root, queries: queries) { query, result in
      let branch = query.head
      guard let ref = refs[branch], let repositories = targets[branch] else { return }
      fetched[query] = result
      let results = repositories.compactMap {
        fetched[GitHubBranchPRQuery(head: branch, repository: $0)]
      }
      guard results.count == repositories.count else { return }
      let merged = Self.merge(results)
      landed[branch] = merged.map { GitHubBranchPR.filter($0, headedBy: ref) }
      if landed.count == refs.count { completion(landed) }
    }
  }

  /// 正式名の答えから、fork の正式名 → 親の正式名。
  private static func parents(_ answers: [GitHubRepoName: GitHubRepositoryResolution])
    -> [GitHubRepoName: GitHubRepoName]
  {
    var parents: [GitHubRepoName: GitHubRepoName] = [:]
    for case .found(let name, let parent?) in answers.values { parents[name] = parent }
    return parents
  }

  /// 問い合わせ先ごとの答え（push 先が先）を 1 つにする。失敗があれば最初の失敗にする。PR は作成日時の新しい順。
  private static func merge(_ results: [Result<[GitHubBranchPR], GitHubFailure>])
    -> Result<[GitHubBranchPR], GitHubFailure>
  {
    var all: [[GitHubBranchPR]] = []
    for result in results {
      switch result {
      case .failure(let failure): return .failure(failure)
      case .success(let pullRequests): all.append(pullRequests)
      }
    }
    return .success(all.joined().sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") })
  }
}
