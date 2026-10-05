import Foundation

/// worktree の、PR の head として見るブランチと、そのブランチの PR（引けなければ nil）。
struct WorktreeBranchPullRequest: Equatable {
  let branch: String
  let pullRequest: GitHubItemID?
}

/// worktree ごとに、PR の head として見るブランチを決め、そのブランチの PR を 1 つ引く（画面に依らない）。
/// 突き合わせの規則は ⌘T の clean と同じ——ブランチの同一性は remote の台帳（push 先の remote の正式名＋
/// ローカル名）で決め、PR は head がそれと等しいものだけを数える。選ぶのは open の最新、無ければ最新
/// （`gh pr list` は作成日時の降順で返す）。
///
/// worktree はリポジトリ（commonDir）ごとにまとめ、gh の可否・remote の一覧・正式名・台帳はリポジトリごとに
/// 1 回だけ求め、ブランチの PR はその本数をまとめて引く。ブランチを見るのは、今のブランチが期待したブランチ
/// と同じか、期待が未確定（無い・既定ブランチ）で今のブランチが既定ブランチでない worktree だけ——detached・
/// 既定ブランチの worktree は答えを持たない。ブランチは git の答え（`git worktree list`）で決まり、GitHub に
/// 届かない（GitHub でない・gh が無い・未認証）リポジトリ、同一性を確かめられないブランチは PR だけを持たない。
/// 失敗（オフライン等）も答えが無いだけで、外に出さない。全メソッドはメインで呼ばれ、メインで返る。
final class WorktreePullRequestResolver {
  private let runner: GitRunner
  private let gitHub: GitHubCLI
  private let cache: GitHubCache

  init(runner: GitRunner = .shared, gitHub: GitHubCLI = .shared, cache: GitHubCache = .shared) {
    self.runner = runner
    self.gitHub = gitHub
    self.cache = cache
  }

  /// `worktrees`（worktree のパス → そこにいるはずのブランチ。nil は未確定）ごとのブランチと PR。ブランチを
  /// 見ない worktree はキーごと無い。
  func resolve(
    worktrees: [String: String?],
    completion: @escaping ([String: WorktreeBranchPullRequest]) -> Void
  ) {
    var repositories: [String: (repo: GitRepo, branches: [String: String?])] = [:]
    let opened = DispatchGroup()
    for (path, branch) in worktrees {
      opened.enter()
      GitRepo.open(cwd: path, runner: runner) { repo in
        if let repo {
          repositories[repo.commonDir, default: (repo, [:])].branches[path] = branch
        }
        opened.leave()
      }
    }
    opened.notify(queue: .main) {
      var found: [String: WorktreeBranchPullRequest] = [:]
      let resolved = DispatchGroup()
      for (repo, branches) in repositories.values {
        resolved.enter()
        self.resolve(repo, branches: branches) { answers in
          found.merge(answers) { $1 }
          resolved.leave()
        }
      }
      resolved.notify(queue: .main) { completion(found) }
    }
  }

  /// リポジトリ 1 つ分（`expected` はパス → そこにいるはずのブランチ。nil は未確定）。
  private func resolve(
    _ repo: GitRepo, branches expected: [String: String?],
    completion: @escaping ([String: WorktreeBranchPullRequest]) -> Void
  ) {
    var checkouts: [GitWorktree] = []
    var localBranches: [GitBranch] = []
    var defaultBranch = ""
    var isGitHub = false
    var remotes: [String: String]?
    let facts = DispatchGroup()
    facts.enter()
    repo.worktrees {
      checkouts = $0
      facts.leave()
    }
    facts.enter()
    repo.localBranches {
      localBranches = $0
      facts.leave()
    }
    facts.enter()
    repo.defaultBranch {
      defaultBranch = GitBranch.localName(fromRemote: $0)
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
      let branches = Self.branches(expected, checkouts: checkouts, defaultBranch: defaultBranch)
      let withoutPullRequests = branches.mapValues {
        WorktreeBranchPullRequest(branch: $0, pullRequest: nil)
      }
      guard !branches.isEmpty else { return completion([:]) }
      self.gitHub.probe(cwd: repo.root, isGitHub: isGitHub) { availability in
        guard availability == .ready else { return completion(withoutPullRequests) }
        self.ledger(repo, remotes: remotes) { resolved in
          let identities = GitHubBranchIdentities(
            resolved: resolved, localBranches: localBranches)
          var refs: [String: GitHubBranchRef] = [:]
          for branch in Set(branches.values) {
            if case .ref(let ref) = identities.local(branch) { refs[branch] = ref }
          }
          self.pullRequests(repo, refs: refs) { chosen in
            completion(
              branches.mapValues {
                WorktreeBranchPullRequest(branch: $0, pullRequest: chosen[$0])
              })
          }
        }
      }
    }
  }

  /// パス → PR の head として見るブランチ。detached・既定ブランチ・確定した期待（既定ブランチ以外の期待）と
  /// 違うブランチは見ない。
  private static func branches(
    _ expected: [String: String?], checkouts: [GitWorktree], defaultBranch: String
  ) -> [String: String] {
    var branches: [String: String] = [:]
    for (path, expectedBranch) in expected {
      let key = GitWorktreeRoot.normalizedPath(path)
      guard
        let branch = checkouts.first(where: { GitWorktreeRoot.normalizedPath($0.path) == key })?
          .branch, branch != defaultBranch
      else { continue }
      if let expectedBranch, expectedBranch != defaultBranch, expectedBranch != branch { continue }
      branches[path] = branch
    }
    return branches
  }

  /// remote の台帳。正式名は置き場の答えを使い、正式名でなければ問い合わせて置き場へ書く。
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

  /// ブランチごとの PR（open の最新、無ければ最新）。取れたブランチの PR は置き場にも書く（次に ⌘T を
  /// 開いたときの先描きになる）。
  private func pullRequests(
    _ repo: GitRepo, refs: [String: GitHubBranchRef],
    completion: @escaping ([String: GitHubItemID]) -> Void
  ) {
    guard !refs.isEmpty else { return completion([:]) }
    var chosen: [String: GitHubItemID] = [:]
    var remaining = refs.count
    gitHub.branchPullRequests(cwd: repo.root, heads: Array(refs.keys)) { head, fetched in
      if let fetched, let ref = refs[head] {
        self.cache.setBranchPullRequests(fetched, head: head, for: repo.commonDir)
        let mine = GitHubBranchPR.filter(fetched, headedBy: ref)
        if let pick = mine.first(where: { $0.state == "OPEN" }) ?? mine.first,
          let item = pick.url.flatMap(GitHubItemID.init(pullRequestURL:))
        {
          chosen[head] = item
        }
      }
      remaining -= 1
      if remaining == 0 { completion(chosen) }
    }
  }
}
