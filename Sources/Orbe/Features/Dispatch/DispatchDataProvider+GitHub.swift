import Foundation

/// gh レーンの取得と着地。probe（可否判定）→ 取得（issues / open PR 一覧 / ブランチの PR）→
/// 着地の規則（失敗は据え置き・等値は再描画しない）までを持ち、描画は本体の `rebuild()` へ流す。
extension DispatchDataProvider {

  /// 前回取得した gh 結果をリポジトリ（commonDir）単位で先に積む。最初の rebuild（git 着地時）に
  /// 既に issue/PR 行が載るので、2 回目以降はローディング行を経由せず前回の行が即出る。
  /// ここで rebuild は打たない（git 未着の中途半端なリストが一瞬描かれ、かえってちらつく）。
  /// 取得済みの側だけ載せる——片方が前回失敗していれば、そちらは loading のまま今回の取得を待つ。
  func applyCachedGitHub(_ repo: GitRepo) {
    guard let entry = DispatchGitHubCache.shared.entry(for: repo.commonDir) else { return }
    if let cached = entry.issues {
      issues = cached
      issuesLoading = false
    }
    if let cached = entry.pullRequests {
      pullRequests = cached
      pullRequestsLoading = false
    }
    // 掃除の突き合わせ（PR が OPEN / MERGED か）はここでは積まない——head ごとの状態を組む
    // `branchPRStates` がキャッシュを直接読み、今回の取得が未着地／失敗の head だけを前回結果で
    // 埋める（合成点を 2 つに割ると、着地の順で結果が変わる）。
  }

  func loadGitHub(_ repo: GitRepo) {
    repo.originIsGitHub { [weak self] isGitHub in
      guard let self else { return }
      GitHubCLI.shared.probe(cwd: repo.root, isGitHub: isGitHub) { [weak self] state in
        guard let self else { return }
        self.probedGitHubState = state
        self.model?.githubState = state
        guard state == .ready else {
          self.issuesLoading = false
          self.pullRequestsLoading = false
          self.rebuild()
          return
        }
        // キャッシュ書き込みは `self` の生存判定より前——provider はパレットと同じ寿命で、gh の応答前に
        // 閉じられるのが常用経路。self が消えたら捨てる作りだと次回の先描きが永遠に温まらない。
        GitHubCLI.shared.issues(cwd: repo.root, limit: self.ghLimit) { [weak self] fetched in
          if let fetched { DispatchGitHubCache.shared.setIssues(fetched, for: repo.commonDir) }
          self?.applyFetchedIssues(fetched)
        }
        GitHubCLI.shared.pullRequests(cwd: repo.root, limit: self.ghLimit) { [weak self] fetched in
          if let fetched {
            DispatchGitHubCache.shared.setPullRequests(fetched, for: repo.commonDir)
          }
          self?.applyFetchedPullRequests(fetched)
        }
        self.loadBranchPullRequests(repo)
      }
    }
  }

  /// ブランチの PR（`--state all` で open / closed の両方。掃除の安全確認・推定・チップにだけ使う）を、
  /// **worktree にあるブランチの名指し**で引く。直近 N 件の一覧窓では、窓落ちした PR のぶんだけ
  /// 「マージ済みなのに merged チップが出ない」「レビュー中なのに安全確認を素通りする」が起きる——
  /// 対象を worktree のブランチに絞れば件数は worktree 本数で抑えられ、窓の概念そのものが消える。
  /// パレットの PR 一覧 UI は別（bulk の open 一覧。一覧表示は窓で正当）。
  ///
  /// git レーン（worktree 一覧）と gh レーン（認証確認）の両方が揃ってはじめて引けるので、
  /// **両側の着地点から同じこの入口を叩き、先に来た側は素通りする**（worktree 未着なら対象が
  /// 空・probe 未完なら `githubReady` が false）。
  ///
  /// **まだ引いていない head だけを引く。** 着地点が複数ある以上この入口は何度も叩かれるが、
  /// 引き直しに意味があるのは worktree の顔ぶれが変わったときだけで、同じ head の再取得は
  /// 往復をまるごと二重に払うだけになる。
  ///
  /// 記録は**発行の時点**で置く（`branchPRFetches[head] = .fetching`）——取得は 1 本あたり 1 秒前後
  /// かかるので、着地を待って記録すると、その間に来たもう一方の着地点が同じ head を二重に引く。
  ///
  /// **取得に失敗した head はセッション中に引き直さない**（`pending` の抽出がここ 1 箇所に閉じて
  /// いるので、方針を変えるならこの 1 行）。パレットは開くたびに provider ごと作り直されるため、
  /// 開き直せば再取得される。
  func loadBranchPullRequests(_ repo: GitRepo) {
    guard githubReady else { return }
    let heads = Self.branchPRHeads(of: worktrees)
    // 削除で消えた worktree の残骸を持たない。
    let alive = Set(heads)
    branchPRFetches = branchPRFetches.filter { alive.contains($0.key) }
    let pending = heads.filter { branchPRFetches[$0] == nil }
    guard !pending.isEmpty else { return }
    for head in pending { branchPRFetches[head] = .fetching }
    GitHubCLI.shared.branchPullRequests(cwd: repo.root, heads: pending) { [weak self] head, prs in
      // キャッシュ書き込みは `self` の生存判定より前（issues/PR と同じ理由）。
      if let prs {
        DispatchGitHubCache.shared.setBranchPullRequests(prs, head: head, for: repo.commonDir)
      }
      self?.applyFetchedBranchPRs(head: head, prs)
    }
  }

  /// 分類器へ渡す head ごとの状態（**導出値**。保存しない）。gh が使えないと**確定**した
  /// リポジトリは「確かめて 0 件」——確認対象そのものが無いので、行は git の事実だけで判定される
  /// （従来動作）。今回の取得が未着地／失敗の head は、前回セッションの結果があればそれで確定させる
  /// （stale-while-revalidate。既存の「取得失敗は据え置き」契約を head 単位に保つ）。
  var branchPRStates: [String: BranchPRState] {
    let heads = Self.branchPRHeads(of: worktrees)
    guard let probed = probedGitHubState else {
      return Dictionary(uniqueKeysWithValues: heads.map { ($0, BranchPRState.fetching) })
    }
    guard probed == .ready else {
      return Dictionary(uniqueKeysWithValues: heads.map { ($0, BranchPRState.loaded([])) })
    }
    let cached =
      repo.flatMap { DispatchGitHubCache.shared.entry(for: $0.commonDir)?.branchPullRequests }
      ?? [:]
    return Dictionary(
      uniqueKeysWithValues: heads.map { head in
        switch branchPRFetches[head] {
        case .loaded(let prs): return (head, .loaded(prs))
        case .failed: return (head, cached[head].map(BranchPRState.loaded) ?? .failed)
        case .fetching, nil: return (head, cached[head].map(BranchPRState.loaded) ?? .fetching)
        }
      })
  }

  /// 着地済みの PR を平坦化したもの（`extraContainmentTargets` の入力）。
  var landedBranchPRs: [GitHubBranchPR] {
    branchPRStates.values.flatMap { state -> [GitHubBranchPR] in
      guard case .loaded(let prs) = state else { return [] }
      return prs
    }
  }

  /// ブランチの PR 取得の対象。worktree にあるブランチだけ——main worktree は掃除の対象外、
  /// detached（`branch == nil`）は PR の head になり得ない。
  static func branchPRHeads(of worktrees: [GitWorktree]) -> [String] {
    worktrees.filter { !$0.isMain }.compactMap(\.branch)
  }

  /// 取得失敗（nil）は差し替えず据え置く。等値なら rebuild もしない（ちらつかない）。
  /// gh 着地の規則は以下の 3 メソッドが持つ（テストが直接叩く唯一の入口）。
  /// needsRebuild を代入より先に評価するのが要点——キャッシュ未ヒット時は loading==true なので
  /// 失敗でも必ず rebuild してローディング行を畳む。
  func applyFetchedIssues(_ fetched: [GitHubIssue]?) {
    let needsRebuild = issuesLoading || (fetched != nil && fetched != issues)
    issuesLoading = false
    if let fetched { issues = fetched }
    if needsRebuild { rebuild() }
  }

  /// issues 側（`applyFetchedIssues`）と同じ規則。片方の失敗が他方を巻き込まないよう別々に到着させる。
  func applyFetchedPullRequests(_ fetched: [GitHubPullRequest]?) {
    let needsRebuild = pullRequestsLoading || (fetched != nil && fetched != pullRequests)
    pullRequestsLoading = false
    if let fetched { pullRequests = fetched }
    if needsRebuild { rebuild() }
  }

  /// head 1 本の着地。失敗（nil）もその head に閉じる——1 本の失敗で全体を捨てると、取れた head の
  /// 事実まで一緒に消える。
  ///
  /// gh 着地で merged PR の base が判明したら、**取り込み判定の比較先の顔ぶれが変わった行だけ**
  /// 引き直す（`startCleanProbe` の発行時台帳が差分を判定する）——本再判定の入口はここ 1 点。
  /// **差分プローブを `rebuild()` より先に撃つ**のが要点。描いてから撃つと、比較先が増えた行が
  /// 一瞬「確定」に見え、自動チェックが誤って灯る（しかもその後プローブ着地で分類が変わる）。
  func applyFetchedBranchPRs(head: String, _ fetched: [GitHubBranchPR]?) {
    // 消えた head（削除された worktree）への遅着は捨てる。
    guard branchPRFetches[head] == .fetching else { return }
    branchPRFetches[head] = fetched.map(BranchPRState.loaded) ?? .failed
    if let repo { startCleanProbe(repo, invalidateAll: false) }
    rebuild()
  }
}
