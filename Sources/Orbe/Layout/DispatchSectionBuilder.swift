import Foundation

/// parsed な git/GitHub モデルから `[DispatchSection]` を組み立てる純粋関数（subprocess 非依存）。
/// 相関（PR headRef → branch チップ `#<PR>`）・重複排除・空セクション除外・フォールバック分岐をここに集約し、
/// mock 入力で決定的にテストする。実データ取得は `DispatchDataProvider` が担う。
enum DispatchSectionBuilder {
  /// 組み立ての入力（parsed モデル一式＋GitHub 可否・ローディング状態）。
  struct Input {
    var worktrees: [GitWorktree] = []
    var localBranches: [GitBranch] = []
    var remoteBranches: [GitBranch] = []
    var issues: [GitHubIssue] = []
    var pullRequests: [GitHubPullRequest] = []
    var githubState: GitHubAvailability = .ready
    var issuesLoading = false
    var pullRequestsLoading = false
    /// 現在のチェックアウト（repo.root）。一致する worktree を primary（強調）にする。
    var currentWorktree: String?
  }

  static func build(_ input: Input) -> [DispatchSection] {
    // PR の headRef → number マップ（worktree/branch 行の相関チップに使う）。
    let prByHead = Dictionary(
      input.pullRequests.map { ($0.headRefName, $0.number) },
      uniquingKeysWith: { first, _ in first }
    )
    var sections: [DispatchSection] = []
    append(&sections, title: "Worktrees", items: worktreeItems(input, prByHead))
    append(&sections, title: "Local branches", items: localBranchItems(input, prByHead))
    append(&sections, title: "Remote branches", items: remoteBranchItems(input, prByHead))
    if let issues = githubSection(
      title: "Issues", state: input.githubState, loading: input.issuesLoading, carriesInfo: true,
      items: issueItems(input))
    {
      sections.append(issues)
    }
    if let prs = githubSection(
      title: "Pull requests", state: input.githubState, loading: input.pullRequestsLoading,
      carriesInfo: false, items: pullRequestItems(input))
    {
      sections.append(prs)
    }
    return sections
  }

  // MARK: - セクションごとの item 組み立て

  /// Worktrees（main 含む全チェックアウト）。現在のチェックアウトは primary で強調する。
  private static func worktreeItems(_ input: Input, _ prByHead: [String: Int]) -> [DispatchItem] {
    input.worktrees.map { worktree in
      let name = (worktree.path as NSString).lastPathComponent
      var detail = abbreviate(worktree.path)
      if let branch = worktree.branch { detail += " · \(branch)" }
      let isPrimary = input.currentWorktree == worktree.path
      let pr = linkedPR(prByHead, forBranch: worktree.branch)
      return DispatchItem(
        glyph: .worktree, name: name, detail: detail,
        badges: badge(pr), linkedPRNumber: pr,
        showsWorkingIndicator: isPrimary, isPrimary: isPrimary,
        action: .worktree(path: worktree.path),
        footer: DispatchFooter(target: name, kind: .existing))
    }
  }

  /// Local branches（既に worktree があるものは Worktrees に出るので重複排除）。
  private static func localBranchItems(_ input: Input, _ prByHead: [String: Int]) -> [DispatchItem]
  {
    input.localBranches
      .filter { $0.worktreePath == nil }
      .map { branch in
        let pr = linkedPR(prByHead, forBranch: branch.name)
        return DispatchItem(
          glyph: .localBranch, name: branch.name, detail: branch.relativeDate,
          badges: badge(pr), linkedPRNumber: pr,
          action: .localBranch(name: branch.name, existingWorktree: branch.worktreePath),
          footer: DispatchFooter(target: branch.name, kind: .checkout))
      }
  }

  /// Remote branches（ローカル追跡済みは出さない・既存 worktree は action に焼き込む）。
  private static func remoteBranchItems(_ input: Input, _ prByHead: [String: Int]) -> [DispatchItem]
  {
    let localNames = Set(input.localBranches.map(\.name))
    return input.remoteBranches.compactMap { branch in
      let local = localName(fromRemote: branch.name)
      guard !localNames.contains(local) else { return nil }
      let pr = linkedPR(prByHead, forBranch: local)
      return DispatchItem(
        glyph: .remoteBranch, name: branch.name, detail: branch.relativeDate,
        badges: badge(pr), linkedPRNumber: pr,
        action: .remoteBranch(
          name: branch.name, existingWorktree: input.worktrees.first { $0.branch == local }?.path),
        footer: DispatchFooter(target: branch.name, kind: .checkout))
    }
  }

  /// Issues。`issue/<n>` を worktrees/localBranches と突合し他行種別と対称化する（既存 worktree 再利用／
  /// 既存ブランチから追加／新規作成）。trailingNote/footer は同じ突合結果から導き実挙動と一致させる（SSOT）。
  private static func issueItems(_ input: Input) -> [DispatchItem] {
    input.issues.map { issue in
      let branch = "issue/\(issue.number)"
      let existingWorktree = input.worktrees.first { $0.branch == branch }?.path
      let existingBranch = input.localBranches.contains { $0.name == branch }
      let kind = issueKind(existingWorktree: existingWorktree, existingBranch: existingBranch)
      return DispatchItem(
        glyph: .issue, idText: "#\(issue.number)", name: issue.title,
        worktreeNote: kind,
        action: .issue(
          number: issue.number, existingWorktree: existingWorktree, existingBranch: existingBranch),
        footer: DispatchFooter(target: "#\(issue.number)", kind: kind))
    }
  }

  /// Issue の実解決に一致した worktree 解決種別（trailingNote/footer 前置句の由来）。
  private static func issueKind(existingWorktree: String?, existingBranch: Bool)
    -> DispatchWorktreeKind
  {
    if existingWorktree != nil { return .existing }
    if existingBranch { return .checkout }
    return .new
  }

  private static func pullRequestItems(_ input: Input) -> [DispatchItem] {
    input.pullRequests.map { pr in
      DispatchItem(
        glyph: .pullRequest, idText: "#\(pr.number)", name: pr.title,
        reviewNote: reviewNote(pr.reviewDecision),
        worktreeNote: .checkout,
        action: .pullRequest(
          number: pr.number, headRef: pr.headRefName, isCrossRepo: pr.isCrossRepository,
          existingWorktree: input.worktrees.first { $0.branch == pr.headRefName }?.path),
        footer: DispatchFooter(target: "#\(pr.number)", kind: .checkout))
    }
  }

  // MARK: - 補助

  private static func append(
    _ sections: inout [DispatchSection], title: String, items: [DispatchItem]
  ) {
    guard !items.isEmpty else { return }
    sections.append(DispatchSection(title: title, items: items))
  }

  /// 行が紐づく open PR 番号（head ブランチ名一致・存在しなければ nil）。
  /// バッジ `#<PR>` と `linkedPRNumber` を同じ 1 回のルックアップから導く SSOT。
  private static func linkedPR(_ prByHead: [String: Int], forBranch branch: String?) -> Int? {
    guard let branch else { return nil }
    return prByHead[branch]
  }

  /// `linkedPR` の番号から行末チップを導く（番号が無ければ空）。
  private static func badge(_ number: Int?) -> [DispatchBadge] {
    guard let number else { return [] }
    return [DispatchBadge(text: "#\(number)")]
  }

  /// GitHub セクションの分岐: notGitHub→非表示 / gh 不在・未認証→誘導情報行 1 本（Issues のみ）/
  /// ready→ローディング行 or 実データ（空は非表示）。
  private static func githubSection(
    title: String, state: GitHubAvailability, loading: Bool, carriesInfo: Bool,
    items: [DispatchItem]
  ) -> DispatchSection? {
    switch state {
    case .notGitHub:
      return nil
    case .ghMissing, .ghUnauthed:
      guard carriesInfo else { return nil }
      let kind: DispatchInfoKind = state == .ghMissing ? .ghMissing : .ghUnauthed
      return DispatchSection(title: title, items: [infoRow(kind)])
    case .ready:
      if loading { return DispatchSection(title: title, items: [loadingRow()]) }
      return items.isEmpty ? nil : DispatchSection(title: title, items: items)
    }
  }

  /// 情報/ローディング行（文言は種別だけ持ち、View が言語別に引く。name は空）。
  private static func infoRow(_ kind: DispatchInfoKind) -> DispatchItem {
    DispatchItem(glyph: nil, name: "", infoKind: kind, isInteractive: false)
  }

  private static func loadingRow() -> DispatchItem {
    DispatchItem(
      glyph: nil, name: "", infoKind: .loading, isInteractive: false, isLoadingRow: true)
  }

  private static func reviewNote(_ decision: String?) -> DispatchReviewNote? {
    switch decision {
    case "REVIEW_REQUIRED": return .reviewRequired
    case "CHANGES_REQUESTED": return .changesRequested
    case "APPROVED": return .approved
    default: return nil
    }
  }

  /// `origin/feat/x` → `feat/x`（先頭のリモート名を落とす）。
  private static func localName(fromRemote name: String) -> String {
    let parts = name.split(separator: "/", maxSplits: 1)
    return parts.count == 2 ? String(parts[1]) : name
  }

  private static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}

#if DEBUG
  extension DispatchSectionBuilder.Input {
    /// Dispatch の代表シーンに対応する決定的サンプル（preview / gallery / 視覚突合用）。
    /// 実データ形（worktree 相関 `#145` は PR headRef 一致で焼く）。live git/gh は叩かない。
    static var designSample: DispatchSectionBuilder.Input {
      let home = NSHomeDirectory()
      return DispatchSectionBuilder.Input(
        worktrees: [
          GitWorktree(
            path: "\(home)/wt/agent-hooks", branch: "feature/agent-hooks", head: "a1", isMain: false
          ),
          GitWorktree(
            path: "\(home)/wt/diff-panel", branch: "fix/diff-panel", head: "b2", isMain: false),
        ],
        localBranches: [
          GitBranch(
            name: "main", relativeDate: "1d ago", worktreePath: nil, upstream: "origin/main"),
          GitBranch(
            name: "perf/render-batching", relativeDate: "5d ago", worktreePath: nil, upstream: nil),
        ],
        remoteBranches: [
          GitBranch(
            name: "origin/feat/session-restore", relativeDate: "taro · 3h ago", worktreePath: nil,
            upstream: nil)
        ],
        issues: [
          GitHubIssue(number: 151, title: "Status detection doesn't work inside tmux"),
          GitHubIssue(number: 149, title: "Tab drag order isn't persisted"),
        ],
        pullRequests: [
          GitHubPullRequest(
            number: 145, title: "feat: session restore", headRefName: "feat/session-restore",
            reviewDecision: "REVIEW_REQUIRED", isCrossRepository: false)
        ],
        githubState: .ready, issuesLoading: false, pullRequestsLoading: false,
        currentWorktree: "\(home)/wt/agent-hooks")
    }
  }
#endif
