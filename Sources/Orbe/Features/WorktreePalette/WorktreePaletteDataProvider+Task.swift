import Foundation

/// タスクから開いたときの先頭の欄の解決。文脈の入力（タスクの worktree・主の結び付き・PR の head）と、
/// git の一覧・remote の台帳の事実から、rebuild のたびに 1 つの値を導く。
extension WorktreePaletteDataProvider {
  /// remote の台帳の中で、あるリポジトリを指す remote。
  private enum RemoteMatch {
    case matched([String])
    /// まだ分からない（URL から読んだ名前では一致せず、正式名の答えを待っている）。
    case pending
    case none
  }

  /// 先頭の欄の行き先。決まる順は、文脈 → タスクの worktree が今の一覧にあるか → 主の Issue・PR が手元の
  /// リポジトリから扱えるか。
  func taskTarget(_ inputs: WorktreePaletteTaskInputs) -> WorktreePaletteTaskTarget {
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
      return branchTarget(head.branch, in: head.repo, pullRequest: primary.item.number)
    case (.pr, .pending):
      return .pending
    case (.pr, .none), (.pr, .unavailable):
      return .none
    }
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
