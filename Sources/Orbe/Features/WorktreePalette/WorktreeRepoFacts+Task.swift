import Foundation

/// タスクの行き先から決まる用意の仕方。
enum WorktreeTaskPlan: Equatable {
  /// 今ある行き先を開く（worktree・ローカルブランチ・リモートブランチ）。
  case open(WorktreePaletteDestination)
  /// 名前のブランチをベースから新しく作る。
  case create(name: String)
}

/// タスクの行き先の決定。文脈の入力（タスクの worktree・主の結び付き・PR の head、または渡されたブランチ名）と、
/// git の一覧・remote の台帳の事実から 1 つの値を導く。⌘T の先頭の欄と `start_task` が同じ規則を通る。
extension WorktreeRepoFacts {
  /// remote の台帳の中で、あるリポジトリを指す remote。
  private enum RemoteMatch {
    case matched([String])
    /// まだ分からない（URL から読んだ名前では一致せず、正式名の答えを待っている）。
    case pending
    case none
  }

  /// 手元のローカルブランチが、PR の head と同じ GitHub のブランチか。
  private enum HeadMatch {
    case same, other
    /// まだ分からない（gh の確認か remote の正式名を待っている）。
    case pending
  }

  /// 先頭の欄の行き先。決まる順は、文脈 → タスクの worktree が今の一覧にあるか → 主の Issue・PR が手元の
  /// リポジトリから扱えるか → そのブランチが手元にあるか（無ければ fetch の着地まで決めない）。
  func taskTarget(_ inputs: WorktreePaletteTaskInputs) -> WorktreePaletteTaskTarget {
    awaitingFetch(resolvedTaskTarget(inputs))
  }

  /// 渡されたブランチ名の行き先。主の結び付きがあれば、そのリポジトリを指す remote のブランチを探し（無ければ欄を
  /// 出さない）、無ければ origin のブランチを探す。
  func taskTarget(branch name: String, primary: GitHubRepoName?) -> WorktreePaletteTaskTarget {
    guard repo != nil else { return .none }
    guard let primary else {
      return awaitingFetch(
        .branch(
          name: name, pullRequest: nil, remotes: [GitHubRemoteLedger.Resolved.defaultRemote]))
    }
    return awaitingFetch(branchTarget(name, in: primary, pullRequest: nil))
  }

  /// `repo` を指す remote が手元にあるか。まだ分からなければ nil。
  func hasRemote(for repo: GitHubRepoName) -> Bool? {
    switch remotes(of: repo) {
    case .matched: true
    case .none: false
    case .pending: nil
    }
  }

  /// 提示時の fetch がまだ着地していなければ、手元に無いブランチは fetch で現れうる。今決めると、PR は欄なしで
  /// 今の worktree に、Issue は push 済みのブランチと分岐した作成行に決まってしまう。
  private func awaitingFetch(_ target: WorktreePaletteTaskTarget) -> WorktreePaletteTaskTarget {
    guard case .branch(let name, _, let remotes) = target, !remoteFetchLanded,
      !hasBranch(name, on: remotes)
    else { return target }
    return .pending
  }

  /// 行き先 → 用意の仕方。worktree → ローカルブランチ → そのリポジトリの remote のブランチの順に、今の列挙から
  /// 探す。どれも無く、PR でなく、作成行の規則が名前を許すなら作る。どれでもなければ nil。
  static func plan(
    for target: WorktreePaletteTaskTarget, worktrees: [GitWorktree], localBranches: [GitBranch],
    remoteBranches: [GitBranch], newBranchRules: WorktreeNewBranchRules?
  ) -> WorktreeTaskPlan? {
    switch target {
    case .none, .pending:
      return nil
    case .worktree(let path):
      return .open(.directory(path: path))
    case .branch(let name, let pullRequest, let remotes):
      if let worktree = worktrees.first(where: { $0.branch == name }) {
        return .open(.directory(path: worktree.path))
      }
      if localBranches.contains(where: { $0.name == name }) {
        return .open(.localBranch(name: name))
      }
      let remote = remotes.lazy.map { "\($0)/\(name)" }.first { remote in
        remoteBranches.contains { $0.name == remote }
      }
      if let remote { return .open(.remoteBranch(name: remote, existingWorktree: nil)) }
      guard pullRequest == nil, newBranchRules?.allows(name) == true else { return nil }
      return .create(name: name)
    }
  }

  /// 名前のブランチが、ローカルブランチ（worktree のブランチを含む）か `remotes` のリモートブランチとして手元にあるか。
  private func hasBranch(_ name: String, on remotes: [String]) -> Bool {
    localBranches.contains { $0.name == name }
      || remoteBranches.contains { branch in remotes.contains { "\($0)/\(name)" == branch.name } }
  }

  private func resolvedTaskTarget(_ inputs: WorktreePaletteTaskInputs) -> WorktreePaletteTaskTarget
  {
    guard inputs.taskID != nil, repo != nil else { return .none }
    if let worktree = inputs.worktree,
      let match = worktrees.first(where: {
        GitWorktreeRoot.normalizedPath($0.path) == worktree.path
      })
    {
      return .worktree(path: match.path)
    }
    guard let primary = inputs.primary else { return .none }
    switch (primary.kind, inputs.pullRequestHead) {
    case (.issue, _):
      return branchTarget("issue/\(primary.item.number)", in: primary.item.repo, pullRequest: nil)
    case (.pr, .found(let head)):
      // 同じ名前のローカルブランチ（worktree のブランチを含む）は、別のリポジトリ（fork の main 等）のもの
      // かもしれない。head と同じ GitHub のブランチのときだけその行を使い、違えば欄を出さない（同名の
      // ローカルがあると、head のリモートブランチの行は一覧に出ない）。
      if localBranches.contains(where: { $0.name == head.branch }) {
        switch localBranch(head.branch, matches: head) {
        case .same: break
        case .other: return .none
        case .pending: return .pending
        }
      }
      return branchTarget(head.branch, in: head.repo, pullRequest: primary.item.number)
    case (.pr, .pending):
      return .pending
    case (.pr, .none), (.pr, .unavailable):
      return .none
    }
  }

  /// ローカルブランチの同一性（`GitHubBranchIdentities`。⌘T の clean と PR の自動の結び付けと同じ口）が
  /// `head` と等しいか。gh が使えないと決まったら、PR の自動の結び付けと同じく確かめられないものとして
  /// 欄を出さない側に決める。
  private func localBranch(_ name: String, matches head: GitHubBranchRef) -> HeadMatch {
    guard let probed = probedGitHubState else { return .pending }
    guard probed == .ready else { return .other }
    guard case .settled(let resolved) = remoteLedger else { return .pending }
    let identity = GitHubBranchIdentities(resolved: resolved, localBranches: localBranches)
      .local(name)
    return identity == .ref(head) ? .same : .other
  }

  /// `repo` のブランチ。そのリポジトリが手元のいずれかの remote でなければ欄を出さない。
  private func branchTarget(_ name: String, in repo: GitHubRepoName, pullRequest: Int?)
    -> WorktreePaletteTaskTarget
  {
    switch remotes(of: repo) {
    case .matched(let remotes):
      return .branch(name: name, pullRequest: pullRequest, remotes: remotes)
    case .pending:
      return .pending
    case .none:
      return .none
    }
  }

  /// `repo` を指す手元の remote（origin を先頭に）。名前は remote の URL から読んだものか、台帳が答えた正式名の
  /// どちらかが等しければよい——URL の名前で決まるのが普通なので、多くの場合は gh を待たない。
  private func remotes(of repo: GitHubRepoName) -> RemoteMatch {
    guard case .read(let remotes) = remoteListing else {
      return remoteListing == nil ? .pending : .none
    }
    let answers = cachedRepositoryNames
    let matched = remotes.compactMap { remote, url -> String? in
      guard let read = GitHubRepoName(remoteURL: url) else { return nil }
      if read == repo { return remote }
      if case .found(let name) = answers[read], name == repo { return remote }
      return nil
    }
    if !matched.isEmpty {
      let origin = GitHubRemoteLedger.Resolved.defaultRemote
      return .matched(matched.filter { $0 == origin } + matched.filter { $0 != origin }.sorted())
    }
    guard let probed = probedGitHubState else { return .pending }
    guard probed == .ready, case .pending = remoteLedger else { return .none }
    return .pending
  }
}
