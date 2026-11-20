import Foundation

/// worktree の、PR の head として見るブランチと、そのブランチの PR（引けなければ nil）。
struct WorktreeBranchPullRequest: Equatable {
  let branch: String
  let pullRequest: GitHubItemID?
}

/// worktree ごとに、PR の head として見るブランチを決め、そのブランチの PR を 1 つ引く（画面に依らない）。
/// ブランチの同一性と PR の突き合わせは `GitHubBranchPullRequestLookup` が持ち、ここが決めるのは見るブランチと選ぶ PR
/// だけ——選ぶのは open の最新、無ければ最新（`GitHubBranchPullRequestLookup` は作成日時の新しい順で返す）。
///
/// worktree はリポジトリ（commonDir）ごとにまとめ、ブランチの PR はリポジトリごとに 1 回でまとめて引く。ブランチを
/// 見るのは、今のブランチが期待したブランチと同じか、期待が未確定（無い・既定ブランチ）で今のブランチが既定ブランチで
/// ない worktree だけ——detached・既定ブランチの worktree は結果に現れない。ブランチは git の出力（`git worktree list`）で
/// 決まり、PR を引けないブランチ（GitHub に届かない・同一性を確かめられない・問い合わせの失敗）は PR だけを持たない。
/// 全メソッドはメインスレッドで呼ばれ、メインスレッドで返る。
final class WorktreePullRequestResolver {
  private let runner: GitRunner
  private let lookup: GitHubBranchPullRequestLookup

  init(runner: GitRunner = .shared, gitHub: GitHubCLI = .shared, cache: GitHubCache = .shared) {
    self.runner = runner
    lookup = GitHubBranchPullRequestLookup(gitHub: gitHub, cache: cache)
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
    var defaultBranch = ""
    let facts = DispatchGroup()
    facts.enter()
    repo.worktrees {
      checkouts = $0
      facts.leave()
    }
    facts.enter()
    repo.defaultBranch {
      defaultBranch = GitBranch.localName(fromRemote: $0)
      facts.leave()
    }
    facts.notify(queue: .main) {
      let branches = Self.branches(expected, checkouts: checkouts, defaultBranch: defaultBranch)
      guard !branches.isEmpty else { return completion([:]) }
      self.lookup.lookup(repo, branches: Set(branches.values)) { found in
        completion(
          branches.mapValues { branch in
            WorktreeBranchPullRequest(
              branch: branch,
              pullRequest: found.branches[branch]?.pullRequests.flatMap(Self.chosen))
          })
      }
    }
  }

  /// open の最新、無ければ最新。
  private static func chosen(_ pullRequests: [GitHubBranchPR]) -> GitHubItemID? {
    (pullRequests.first { $0.state == "OPEN" } ?? pullRequests.first)?.url.flatMap(
      GitHubItemID.init(pullRequestURL:))
  }

  /// パス → PR の head として見るブランチ。見ないのは、detached の worktree、既定ブランチ、確定した期待
  /// （既定ブランチ以外の期待）と違うブランチ。
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
}
