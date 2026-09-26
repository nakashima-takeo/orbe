import Foundation

/// parsed な git/GitHub モデルから `[DispatchSection]` を組み立てる純粋関数（subprocess 非依存）。
/// 相関（行と PR の同一性 → branch チップ `#<PR>`・PR 行の行き先）・重複排除・空セクション除外・
/// フォールバック分岐をここに集約し、mock 入力で決定的にテストする。実データ取得は `DispatchDataProvider` が担う。
enum DispatchSectionBuilder {
  /// 組み立ての入力（parsed モデル一式＋GitHub 可否・ローディング状態）。
  struct Input {
    var worktrees: [GitWorktree] = []
    var localBranches: [GitBranch] = []
    var remoteBranches: [GitBranch] = []
    var issues: [GitHubIssue] = []
    var pullRequests: [GitHubPullRequest] = []
    var githubState: GitHubAvailability = .ready
    /// 一覧の取得が続いている（セクション末尾にローディング行を足す。値がまだ無ければローディング行
    /// だけのセクションになる）。
    var issuesFetching = false
    var pullRequestsFetching = false
    /// 行が GitHub のどのリポジトリのどのブランチかを決める台帳（紐付けの入力。`Linking`）。
    var remoteLedger: DispatchRemoteLedger = .pending
    /// 現在のチェックアウト（repo.root）。一致する worktree を primary（強調）にする。
    var currentWorktree: String?
    /// clean 行の候補件数（safe 群の件数）。nil は分類レーンが未着地＝バッジを出さない。
    var cleanCandidates: Int?
    /// 提示時の `fetch --prune` が着地した（列挙が fetch 後の値）。Local branch 行の同期ピルは
    /// 着地後の値だけを出す——fetch 前の差は古い remote 追跡 ref との差で、事実として嘘になる。
    /// PR 行の手順 3（`origin/<head>` から作れるか）も着地後の値で決め、着地前は着地を待つ。
    var remoteFetchLanded = false
  }

  static func build(_ input: Input) -> [DispatchSection] {
    let linking = Linking(input)
    // PR の head → number（worktree/branch 行の相関チップに使う）。
    let prByRef = Dictionary(
      input.pullRequests.compactMap { pr in pr.head.map { ($0, pr.number) } },
      uniquingKeysWith: { first, _ in first })
    let linkedPR = { (ref: GitHubBranchRef?) in ref.flatMap { prByRef[$0] } }
    var sections: [DispatchSection] = []
    append(&sections, title: "Worktrees", items: worktreeItems(input, linking, linkedPR))
    append(&sections, title: "Local branches", items: localBranchItems(input, linking, linkedPR))
    append(&sections, title: "Remote branches", items: remoteBranchItems(input, linking, linkedPR))
    if let issues = githubSection(
      title: "Issues", state: input.githubState, carriesInfo: true,
      items: issueItems(input) + fetchingRows(input.issuesFetching))
    {
      sections.append(issues)
    }
    if let prs = githubSection(
      title: "Pull requests", state: input.githubState, carriesInfo: false,
      items: pullRequestSectionItems(input, linking))
    {
      sections.append(prs)
    }
    return sections
  }

  /// 一覧で行と PR を紐付けるか。台帳から 1 回だけ導く。clean の事実（行ごとの答え）とは別の値で、
  /// clean は既定 remote を確かめられなくても行ごとに読む。
  private enum Linking {
    /// 台帳が未確定。チップを付けず、PR セクションはローディング行だけ。
    case pending
    /// 既定 remote（origin）を確かめられない。チップを付けず、PR セクションは情報行と、すべて
    /// ブラウザで開く PR 行——情報行の「PR はブラウザで開きます」と動きを一致させるため、origin 以外で
    /// 確かめられた行も紐付けない。
    case unlinked
    case linked(DispatchRowIdentities)

    init(_ input: Input) {
      switch input.remoteLedger {
      case .pending:
        self = .pending
      case .settled(let resolved):
        self =
          resolved.defaultRemoteUnverified
          ? .unlinked
          : .linked(DispatchRowIdentities(resolved: resolved, localBranches: input.localBranches))
      }
    }

    /// ローカルブランチ（worktree のブランチを含む）の ref。紐付けないとき・detached（nil）・GitHub の
    /// ブランチと確かめられない行は nil（チップも行き先も付けない）。
    func local(_ name: String?) -> GitHubBranchRef? {
      guard case .linked(let identities) = self, let name else { return nil }
      return Self.ref(identities.local(name))
    }

    func remote(_ name: String) -> GitHubBranchRef? {
      guard case .linked(let identities) = self else { return nil }
      return Self.ref(identities.remote(name))
    }

    private static func ref(_ identity: DispatchRowIdentity) -> GitHubBranchRef? {
      switch identity {
      case .ref(let ref): return ref
      case .notGitHub, .unverified: return nil
      }
    }
  }

  // MARK: - セクションごとの item 組み立て

  /// Worktrees（main 含む全チェックアウト）。現在のチェックアウトは primary で強調する。
  /// 末尾に clean 画面への入口を 1 行置く（**候補 0 件でも行は残り、バッジだけ消える**）。
  private static func worktreeItems(
    _ input: Input, _ linking: Linking, _ linkedPR: (GitHubBranchRef?) -> Int?
  ) -> [DispatchItem] {
    guard !input.worktrees.isEmpty else { return [] }
    return input.worktrees.map { worktree in
      let name = (worktree.path as NSString).lastPathComponent
      var detail = abbreviate(worktree.path)
      if let branch = worktree.branch { detail += " · \(branch)" }
      let isPrimary = input.currentWorktree == worktree.path
      let pr = linkedPR(linking.local(worktree.branch))
      return DispatchItem(
        glyph: .worktree, name: name, detail: detail,
        badges: badge(pr), linkedPRNumber: pr,
        showsWorkingIndicator: isPrimary, isPrimary: isPrimary,
        action: .open(.worktree(path: worktree.path)),
        footer: .launch(target: name, kind: .existing))
    } + [cleanItem(input)]
  }

  /// Worktrees セクション末尾の `clean` 行。`clean` は技術語で日英同一（`shell` と同じ扱い）。
  private static func cleanItem(_ input: Input) -> DispatchItem {
    DispatchItem(
      glyph: .clean, name: "clean", detailKey: .dispatchCleanSubtitle,
      aliases: ["rm", "prune", "掃除"], candidateCount: input.cleanCandidates,
      action: .clean, footer: .note(.dispatchCleanListNote))
  }

  /// Local branches（worktree で checkout 中のものは Worktrees に出るので重複排除）。
  private static func localBranchItems(
    _ input: Input, _ linking: Linking, _ linkedPR: (GitHubBranchRef?) -> Int?
  ) -> [DispatchItem] {
    let checkedOut = Set(input.worktrees.compactMap(\.branch))
    return input.localBranches
      .filter { !checkedOut.contains($0.name) }
      .map { branch in
        let pr = linkedPR(linking.local(branch.name))
        return DispatchItem(
          glyph: .localBranch, name: branch.name, detail: branch.relativeDate,
          badges: badge(pr), linkedPRNumber: pr,
          sync: input.remoteFetchLanded ? DispatchBranchSync(branch) : nil,
          action: .open(.localBranch(name: branch.name)),
          footer: .launch(target: branch.name, kind: .checkout))
      }
  }

  /// Remote branches（ローカル追跡済みは出さない・既存 worktree は action に焼き込む）。
  private static func remoteBranchItems(
    _ input: Input, _ linking: Linking, _ linkedPR: (GitHubBranchRef?) -> Int?
  ) -> [DispatchItem] {
    let localNames = Set(input.localBranches.map(\.name))
    return input.remoteBranches.compactMap { branch in
      let local = localName(fromRemote: branch.name)
      guard !localNames.contains(local) else { return nil }
      let pr = linkedPR(linking.remote(branch.name))
      return DispatchItem(
        glyph: .remoteBranch, name: branch.name, detail: branch.relativeDate,
        badges: badge(pr), linkedPRNumber: pr,
        action: .open(
          .remoteBranch(
            name: branch.name, existingWorktree: input.worktrees.first { $0.branch == local }?.path)
        ),
        footer: .launch(target: branch.name, kind: .checkout))
    }
  }

  /// Issues。`issue/<n>` を worktrees/localBranches と突合し他行種別と対称化する（既存 worktree 再利用／
  /// 既存ブランチから追加／新規作成）。行末ノート/footer は同じ突合結果から導き実挙動と一致させる（SSOT）。
  private static func issueItems(_ input: Input) -> [DispatchItem] {
    input.issues.map { issue in
      let branch = "issue/\(issue.number)"
      let existingWorktree = input.worktrees.first { $0.branch == branch }?.path
      let existingBranch = input.localBranches.contains { $0.name == branch }
      let kind = issueKind(existingWorktree: existingWorktree, existingBranch: existingBranch)
      return DispatchItem(
        glyph: .issue, idText: "#\(issue.number)", name: issue.title,
        enterNote: .worktree(kind),
        action: .open(
          .issue(
            number: issue.number, existingWorktree: existingWorktree, existingBranch: existingBranch
          )
        ),
        footer: .launch(target: "#\(issue.number)", kind: kind))
    }
  }

  /// Issue の実解決に一致した worktree 解決種別（行末ノート/footer 前置句の由来）。
  private static func issueKind(existingWorktree: String?, existingBranch: Bool)
    -> DispatchWorktreeKind
  {
    if existingWorktree != nil { return .existing }
    if existingBranch { return .checkout }
    return .new
  }

  /// Pull requests セクションの行。台帳が未確定の間は、PR 行の行き先（既存 worktree か・作れるか）も
  /// 決まらないのでローディング行だけ。ローディング行は、一覧の取得中か、台帳が未確定の間だけ出る。
  private static func pullRequestSectionItems(_ input: Input, _ linking: Linking) -> [DispatchItem]
  {
    switch linking {
    case .pending:
      return fetchingRows(true)
    case .unlinked:
      return [infoRow(.repositoryUnverified)] + pullRequestItems(input, linking)
        + fetchingRows(input.pullRequestsFetching)
    case .linked:
      return pullRequestItems(input, linking) + fetchingRows(input.pullRequestsFetching)
    }
  }

  /// PR 行。Enter の行き先は、ref が PR の head と等しい既存の物を次の順で引いて決め、どれも無ければ
  /// ブラウザで開く。行末ノートとフッターは同じ行き先から導く（SSOT）。
  /// 1. 自分の worktree → それを開く
  /// 2. 自分のローカルブランチ → Local branch 行と同じ作り方（遅れていれば最新化の選択画面）
  /// 3. `origin/<head>`（同じ名前のローカルブランチが無いとき）→ Remote branch 行と同じ作り方。
  ///    origin に限るのは鮮度のため——作成のベースは提示時の fetch の着地後の値であるべきで、提示時に
  ///    fetch するのは origin だけ。fetch の着地前は着地を待ち（見込みは checkout）、着地後に手元に
  ///    無ければブラウザ。
  private static func pullRequestItems(_ input: Input, _ linking: Linking) -> [DispatchItem] {
    let worktreeByRef = firstByRef(
      input.worktrees.compactMap { worktree in
        linking.local(worktree.branch).map { ($0, worktree.path) }
      })
    let localBranchByRef = firstByRef(
      input.localBranches.compactMap { branch in
        linking.local(branch.name).map { ($0, branch.name) }
      }
    )
    let localNames = Set(input.localBranches.map(\.name))
    let remoteNames = Set(input.remoteBranches.map(\.name))
    return input.pullRequests.map { pr in
      let route: DispatchPullRequestRoute =
        pr.head.map { head in
          if let path = worktreeByRef[head] { return .open(.worktree(path: path)) }
          if let name = localBranchByRef[head] { return .open(.localBranch(name: name)) }
          // 着地前の見込みと着地後の判定は、同じこの述語から作る。
          let base = "\(DispatchBranchSync.trustedRemote)/\(head.branch)"
          guard linking.remote(base) == head, !localNames.contains(head.branch) else {
            return .browser
          }
          guard input.remoteFetchLanded else { return .awaitingFetch }
          return remoteNames.contains(base)
            ? .open(.remoteBranch(name: base, existingWorktree: nil)) : .browser
        } ?? .browser
      let kind: DispatchWorktreeKind?
      switch route {
      case .open(.worktree): kind = .existing
      case .open, .awaitingFetch: kind = .checkout
      case .browser: kind = nil
      }
      let target = "#\(pr.number)"
      return DispatchItem(
        glyph: .pullRequest, idText: target, name: pr.title,
        reviewNote: reviewNote(pr.reviewDecision),
        enterNote: kind.map(DispatchEnterNote.worktree) ?? .browser,
        action: .pullRequest(number: pr.number, route: route),
        footer: kind.map { .launch(target: target, kind: $0) } ?? .browse(target: target))
    }
  }

  /// ref → 値（同じ ref が複数あれば先頭）。
  private static func firstByRef<T>(_ pairs: [(GitHubBranchRef, T)]) -> [GitHubBranchRef: T] {
    Dictionary(pairs, uniquingKeysWith: { first, _ in first })
  }

  // MARK: - 補助

  private static func append(
    _ sections: inout [DispatchSection], title: String, items: [DispatchItem]
  ) {
    guard !items.isEmpty else { return }
    sections.append(DispatchSection(title: title, items: items))
  }

  /// `linkedPR` の番号から行末チップを導く（番号が無ければ空）。
  private static func badge(_ number: Int?) -> [DispatchBadge] {
    guard let number else { return [] }
    return [DispatchBadge(text: "#\(number)")]
  }

  /// GitHub セクションの分岐: notGitHub→非表示 / gh 不在・未認証→誘導情報行 1 本（Issues のみ）/
  /// ready→実データ＋取得中のローディング行（空は非表示）。
  private static func githubSection(
    title: String, state: GitHubAvailability, carriesInfo: Bool, items: [DispatchItem]
  ) -> DispatchSection? {
    switch state {
    case .notGitHub:
      return nil
    case .ghMissing, .ghUnauthed:
      guard carriesInfo else { return nil }
      let kind: DispatchInfoKind = state == .ghMissing ? .ghMissing : .ghUnauthed
      return DispatchSection(title: title, items: [infoRow(kind)])
    case .ready:
      return items.isEmpty ? nil : DispatchSection(title: title, items: items)
    }
  }

  /// 情報行（文言は種別だけ持ち、View が言語別に引く。name は空）。
  private static func infoRow(_ kind: DispatchInfoKind) -> DispatchItem {
    DispatchItem(glyph: nil, name: "", infoKind: kind, isInteractive: false)
  }

  /// 一覧の取得が続く間、セクション末尾に置くローディング行（まだ届いていない分があることを示す）。
  private static func fetchingRows(_ fetching: Bool) -> [DispatchItem] {
    guard fetching else { return [] }
    return [
      DispatchItem(
        glyph: nil, name: "", infoKind: .loading, isInteractive: false, isLoadingRow: true)
    ]
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
    /// 実データ形（相関 `#145` は PR の head と行の ref の一致で焼く）。live git/gh は叩かない。
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
            name: "main", relativeDate: "1d ago",
            upstream: upstream("main", ahead: 0, behind: 12)),
          GitBranch(
            name: "perf/render-batching", relativeDate: "5d ago",
            upstream: upstream("perf/render-batching", ahead: 2, behind: 5)),
        ],
        remoteBranches: [
          GitBranch(
            name: "origin/feat/session-restore", relativeDate: "taro · 3h ago", upstream: nil)
        ],
        issues: [
          GitHubIssue(number: 151, title: "Status detection doesn't work inside tmux"),
          GitHubIssue(number: 149, title: "Tab drag order isn't persisted"),
        ],
        pullRequests: [
          GitHubPullRequest(
            number: 145, title: "feat: session restore", headRefName: "feat/session-restore",
            reviewDecision: "REVIEW_REQUIRED", headRepository: designRepository)
        ],
        githubState: .ready,
        remoteLedger: designLedger,
        currentWorktree: "\(home)/wt/agent-hooks",
        // clean 行の候補バッジ（design 正典の clean シーンの safe 群と同数）。
        cleanCandidates: 3,
        // Local branch 行の同期ピル（`↓12` / `↑2 ↓5`）は着地後の値だけ出る。
        remoteFetchLanded: true)
    }

    /// サンプルの origin のリポジトリ（PR の head もここから出る）。
    static let designRepository = GitHubRepoName(nameWithOwner: "nakashima-takeo/orbe")

    /// origin だけを持つ確定した台帳。
    static var designLedger: DispatchRemoteLedger {
      .settled(DispatchRemoteLedger.Resolved(repositories: ["origin": .github(designRepository)]))
    }

    /// origin を追跡する upstream（design 正典の `sync` に対応）。
    static func upstream(_ name: String, ahead: Int, behind: Int) -> GitUpstream {
      GitUpstream(
        short: "origin/\(name)", ref: "refs/remotes/origin/\(name)", remote: "origin",
        remoteRef: "refs/heads/\(name)", track: .counts(ahead: ahead, behind: behind))
    }
  }
#endif
