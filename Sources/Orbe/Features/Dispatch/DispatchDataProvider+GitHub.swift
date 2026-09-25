import Foundation

/// gh レーンの取得と着地。probe（可否判定）→ 取得（issues / open PR 一覧 / ブランチの PR）→
/// 着地の規則（失敗は据え置き・等値は再描画しない）までを持ち、描画は本体の `rebuild()` へ流す。
extension DispatchDataProvider {

  /// 前回取得した gh 結果をリポジトリ（commonDir）単位で先に積む。最初の rebuild（git 着地時）に
  /// 既に issue/PR 行が載るので、2 回目以降は前回の行が即出る（末尾のローディング行が、今回の取得が
  /// まだ届いていないことを示す）。
  /// ここで rebuild は打たない（git 未着の中途半端なリストが一瞬描かれ、かえってちらつく）。
  /// 前回結果の無い側は、ローディング行だけのまま今回の取得を待つ。
  func applyCachedGitHub(_ repo: GitRepo) {
    guard let entry = DispatchGitHubCache.shared.entry(for: repo.commonDir) else { return }
    if let cached = entry.issues { issues = cached }
    if let cached = entry.pullRequests { pullRequests = cached }
    // 掃除の突き合わせ（PR が OPEN / MERGED か）はここでは積まない——head ごとの状態を組む
    // `branchPRStates` がキャッシュを直接読み、今回の取得が未着地／失敗の head だけを前回結果で
    // 埋める（合成点を 2 つに割ると、着地の順で結果が変わる）。
  }

  func loadGitHub(_ repo: GitRepo) {
    repo.originIsGitHub { [weak self] isGitHub in
      guard let self else { return }
      gitHub.probe(cwd: repo.root, isGitHub: isGitHub) { [weak self] state in
        guard let self else { return }
        self.probedGitHubState = state
        self.model?.githubState = state
        guard state == .ready else {
          self.issuesFetching = false
          self.pullRequestsFetching = false
          self.rebuild()
          return
        }
        // 取得はパレットを閉じても続くので、provider ではなく実行基盤だけを捕まえる。
        let gitHub = self.gitHub
        DispatchGitHubCache.shared.refreshIssues(
          for: repo.commonDir,
          fetch: { gitHub.openIssues(cwd: repo.root, page: $0, finished: $1) },
          updated: { [weak self] in self?.applyFetchedIssues($0, growing: $1) })
        DispatchGitHubCache.shared.refreshPullRequests(
          for: repo.commonDir,
          fetch: { gitHub.openPullRequests(cwd: repo.root, page: $0, finished: $1) },
          updated: { [weak self] in self?.applyFetchedPullRequests($0, growing: $1) })
        self.resolveRemoteRepositories(repo)
        self.loadBranchPullRequests(repo)
      }
    }
  }

  /// 正式名の問い合わせの状態。答え（見つかった・存在しない）はキャッシュが持つ。
  enum RepositoryLookup: Equatable {
    case fetching
    /// 失敗した。この回は問い合わせ直さない（開き直せば provider ごと作り直されて問い合わせ直す）。
    case failed
  }

  /// remote の一覧の読み取り結果。
  enum RemoteListing: Equatable {
    /// remote 名 → fetch の URL。
    case read([String: String])
    /// 読めなかった。どの remote が GitHub のどのリポジトリか分からないので、台帳は失敗になる
    /// （空の一覧として確定させると、どの行も「GitHub の行でない」になり、clean が PR の事実を
    /// 「確かめて 0 件」と読む）。
    case unreadable
  }

  /// remote の台帳（**導出値**。保存しない）。remote の一覧が未着なら未確定、読めなければ失敗。
  var remoteLedger: DispatchRemoteLedger {
    switch remoteListing {
    case nil: return .pending
    case .unreadable: return .failed
    case .read(let remotes):
      return DispatchRemoteLedger(
        remotes: remotes, resolutions: cachedRepositoryNames,
        failed: Set(repositoryLookups.filter { $0.value == .failed }.keys))
    }
  }

  private var cachedRepositoryNames: [GitHubRepoName: GitHubRepositoryResolution] {
    repo.flatMap { DispatchGitHubCache.shared.entry(for: $0.commonDir)?.repositoryNames } ?? [:]
  }

  /// GitHub の remote の正式名を問い合わせる（改名前の URL でも、行と PR が同じリポジトリと分かる）。
  /// git レーン（remote の一覧）と gh レーン（認証確認）の両方が揃ってはじめて撃てるので、両側の
  /// 着地点から同じこの入口を叩き、先に来た側は素通りする（`loadBranchPullRequests` と同じ形）。
  /// キャッシュに答えが無く、今回まだ撃っていない名前だけを撃ち、記録は発行の時点で置く。
  /// 1 つずつ撃つのは、1 つの `NOT_FOUND` で他の remote の答えまで失わないため。
  func resolveRemoteRepositories(_ repo: GitRepo) {
    guard githubReady, case .read(let remotes) = remoteListing else { return }
    let cached = cachedRepositoryNames
    let pending = Set(remotes.values.compactMap(GitHubRepoName.init(remoteURL:)))
      .filter { cached[$0] == nil && repositoryLookups[$0] == nil }
    for name in pending {
      repositoryLookups[name] = .fetching
      gitHub.resolveRepository(cwd: repo.root, name: name) { [weak self] resolution in
        // キャッシュ書き込みは `self` の生存判定より前（`loadBranchPullRequests` と同じ理由）。
        if let resolution {
          DispatchGitHubCache.shared.setRepositoryName(resolution, for: name, key: repo.commonDir)
        }
        self?.applyResolvedRepository(name, resolved: resolution != nil)
      }
    }
  }

  /// 正式名 1 つの着地。台帳が確定すれば行の ref が決まるので、ブランチの PR を引き、比較先の変わった
  /// 行の分類を引き直してから描く（`applyFetchedBranchPRs` と同じ順序の理由）。
  func applyResolvedRepository(_ name: GitHubRepoName, resolved: Bool) {
    guard repositoryLookups[name] == .fetching else { return }
    repositoryLookups[name] = resolved ? nil : .failed
    if let repo {
      loadBranchPullRequests(repo)
      startCleanProbe(repo, .changedTargets)
    }
    rebuild()
  }

  /// ブランチの PR（`--state all` で open / closed の両方。掃除の安全確認・推定にだけ使う）を、
  /// **worktree にあるブランチの名指し**で引く。直近 N 件の一覧窓では、窓落ちした PR のぶんだけ
  /// 「マージ済みなのに merged チップが出ない」「レビュー中なのに安全確認を素通りする」が起きる——
  /// 対象を worktree のブランチに絞れば件数は worktree 本数で抑えられ、窓の概念そのものが消える。
  /// パレットの PR 一覧（open 一覧）は closed / merged を含まず上限もあるので、掃除の事実はそれに頼らない。
  /// 名指しするのは worktree の ref のブランチ名（台帳が決める）で、ローカル名とは限らない——ローカル
  /// `feat` が `origin/feature-x` を追跡していれば `feature-x` で問う。
  ///
  /// git レーン（worktree 一覧）・gh レーン（認証確認）・remote の台帳の確定がすべて揃ってはじめて
  /// 引けるので、**各着地点から同じこの入口を叩き、揃う前に来た側は素通りする**。
  ///
  /// **まだ引いていないブランチだけを引く。** 着地点が複数ある以上この入口は何度も叩かれるが、
  /// 引き直しに意味があるのは worktree の顔ぶれが変わったときだけで、同じブランチの再取得は
  /// 往復をまるごと二重に払うだけになる。
  ///
  /// 記録は**発行の時点**で置く（`branchPRFetches[head] = .fetching`）——取得は 1 本あたり 1 秒前後
  /// かかるので、着地を待って記録すると、その間に来たもう一方の着地点が同じブランチを二重に引く。
  ///
  /// **取得に失敗したブランチはセッション中に引き直さない**（`pending` の抽出がここ 1 箇所に閉じて
  /// いるので、方針を変えるならこの 1 行）。パレットは開くたびに provider ごと作り直されるため、
  /// 開き直せば再取得される。
  func loadBranchPullRequests(_ repo: GitRepo) {
    guard githubReady, case .settled(let ledger) = remoteLedger else { return }
    let refs = branchPRRefs(ledger)
    var seen: Set<String> = []
    let heads = Self.worktreeBranches(of: worktrees).compactMap { refs[$0] ?? nil }.map(\.branch)
      .filter { seen.insert($0).inserted }
    // 削除で消えた worktree の残骸を持たない。
    branchPRFetches = branchPRFetches.filter { seen.contains($0.key) }
    let pending = heads.filter { branchPRFetches[$0] == nil }
    guard !pending.isEmpty else { return }
    for head in pending { branchPRFetches[head] = .fetching }
    gitHub.branchPullRequests(cwd: repo.root, heads: pending) { [weak self] head, prs in
      // キャッシュ書き込みは `self` の生存判定より前——provider はパレットと同じ寿命で、gh の応答前に
      // 閉じられるのが常用経路。self が消えたら捨てる作りだと次回の先描きが永遠に温まらない。
      if let prs {
        DispatchGitHubCache.shared.setBranchPullRequests(prs, head: head, for: repo.commonDir)
      }
      self?.applyFetchedBranchPRs(head: head, prs)
    }
  }

  /// 分類器へ渡す worktree のブランチ（ローカル名）ごとの状態（**導出値**。保存しない）。中身は
  /// その worktree の ref と head が等しい PR だけ——他人の fork の同名ブランチの PR は入らない。
  /// 判定は次の順:
  /// 1. probe が未完 → 取得中
  /// 2. gh が使えないと**確定**した → 確かめて 0 件（確認対象そのものが無いので、行は git の事実だけで
  ///    判定される）
  /// 3. 台帳が未確定 → 取得中、台帳が失敗 → 取得失敗（どちらも安全群に入らない）
  /// 4. ref が無い（GitHub の行でない）→ 確かめて 0 件
  /// 5. 今回の取得の結果。未着地／失敗のブランチは、前回セッションの結果があればそれで確定させる
  ///    （stale-while-revalidate。「取得失敗は据え置き」をブランチ単位に保つ）
  var branchPRStates: [String: BranchPRState] {
    let branches = Self.worktreeBranches(of: worktrees)
    func all(_ state: BranchPRState) -> [String: BranchPRState] {
      Dictionary(uniqueKeysWithValues: branches.map { ($0, state) })
    }
    guard let probed = probedGitHubState else { return all(.fetching) }
    guard probed == .ready else { return all(.loaded([])) }
    let ledger: DispatchRemoteLedger.Resolved
    switch remoteLedger {
    case .pending: return all(.fetching)
    case .failed: return all(.failed)
    case .settled(let resolved): ledger = resolved
    }
    let cached =
      repo.flatMap { DispatchGitHubCache.shared.entry(for: $0.commonDir)?.branchPullRequests }
      ?? [:]
    return branchPRRefs(ledger).mapValues { ref in
      guard let ref else { return .loaded([]) }
      let fetched: BranchPRState
      switch branchPRFetches[ref.branch] {
      case .loaded(let prs): fetched = .loaded(prs)
      case .failed: fetched = cached[ref.branch].map(BranchPRState.loaded) ?? .failed
      case .fetching, nil: fetched = cached[ref.branch].map(BranchPRState.loaded) ?? .fetching
      }
      guard case .loaded(let prs) = fetched else { return fetched }
      return .loaded(prs.filter { $0.head == ref })
    }
  }

  /// 着地済みの PR（worktree のブランチごと・ref で絞った後。`extraContainmentTargets` の入力）。
  var landedBranchPRs: [String: [GitHubBranchPR]] {
    branchPRStates.compactMapValues { state in
      guard case .loaded(let prs) = state else { return nil }
      return prs
    }
  }

  /// worktree のブランチ（ローカル名）→ その ref。
  private func branchPRRefs(_ ledger: DispatchRemoteLedger.Resolved) -> [String: GitHubBranchRef?] {
    let upstreams = Dictionary(
      localBranches.map { ($0.name, $0.upstream) }, uniquingKeysWith: { first, _ in first })
    return Dictionary(
      uniqueKeysWithValues: Self.worktreeBranches(of: worktrees).map { branch in
        (branch, ledger.ref(forLocal: branch, upstream: upstreams[branch] ?? nil))
      })
  }

  /// ブランチの PR を確かめる worktree のブランチ（ローカル名）。worktree にあるブランチだけ——main
  /// worktree は掃除の対象外、detached（`branch == nil`）は PR の head になり得ない。
  ///
  /// **一意にして返す。** `git worktree add --force` は同じブランチを 2 本の worktree へ置けるので、
  /// worktree の並びをそのままブランチの並びにすると同名が 2 度出る。重複はここで畳む——この並びを
  /// 辞書へ起こす読み手（`branchPRStates`）が守られる。
  static func worktreeBranches(of worktrees: [GitWorktree]) -> [String] {
    var seen: Set<String> = []
    return worktrees.filter { !$0.isMain }.compactMap(\.branch).filter { seen.insert($0).inserted }
  }

  /// 合流点（`DispatchGitHubCache`）が配る一覧の現在値の着地。取得が続く間はページごと、最後に
  /// `growing == false` で 1 回来る。値が無ければ（未取得のまま・失敗）差し替えず据え置く。値も取得中かも
  /// 前回と等しければ rebuild しない（ちらつかない）。
  /// 一覧 2 レーン（issues / open PR）の着地の規則は以下の 2 メソッドが、合流と一覧の組み立ては
  /// `DispatchGitHubCache` が持つ。head 単位で着地するブランチ PR は別の規則で、`applyFetchedBranchPRs` が持つ。
  func applyFetchedIssues(_ fetched: [GitHubIssue]?, growing: Bool) {
    let needsRebuild = growing != issuesFetching || (fetched != nil && fetched != issues)
    issuesFetching = growing
    if let fetched { issues = fetched }
    if needsRebuild { rebuild() }
  }

  /// issues 側（`applyFetchedIssues`）と同じ規則。片方の失敗が他方を巻き込まないよう別々に到着させる。
  func applyFetchedPullRequests(_ fetched: [GitHubPullRequest]?, growing: Bool) {
    let needsRebuild =
      growing != pullRequestsFetching || (fetched != nil && fetched != pullRequests)
    pullRequestsFetching = growing
    if let fetched { pullRequests = fetched }
    if needsRebuild { rebuild() }
  }

  /// ブランチ 1 本の着地。失敗（nil）もそのブランチに閉じる——1 本の失敗で全体を捨てると、取れた
  /// ブランチの事実まで一緒に消える。
  ///
  /// gh 着地で merged PR の base が判明したら、**取り込み判定の比較先の顔ぶれが変わった行だけ**
  /// 引き直す（`startCleanProbe` の発行時台帳が差分を判定する）——本再判定の入口はここ 1 点。
  /// **差分プローブを `rebuild()` より先に撃つ**のが要点。描いてから撃つと、比較先が増えた行が
  /// 一瞬「確定」に見え、自動チェックが誤って灯る（しかもその後プローブ着地で分類が変わる）。
  func applyFetchedBranchPRs(head: String, _ fetched: [GitHubBranchPR]?) {
    // 消えたブランチ（削除された worktree）への遅着は捨てる。
    guard branchPRFetches[head] == .fetching else { return }
    branchPRFetches[head] = fetched.map(BranchPRState.loaded) ?? .failed
    if let repo { startCleanProbe(repo, .changedTargets) }
    rebuild()
  }
}
