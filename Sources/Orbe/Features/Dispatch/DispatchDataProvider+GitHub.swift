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
    // 掃除の突き合わせ（PR が OPEN / MERGED か）は loading の概念を持たない——未着地は「PR を
    // 知らない」として扱えばよく、その状態で安全群へ入るには gh に依らない推定（`[gone]`・
    // prunable）が別に要る。`[gone]` は head を消した結果なので open PR とは両立せず、prunable は
    // ブランチを消さない行なので、知らないまま失うものが無い。
    if let cached = entry.branchPullRequests { branchPullRequests = cached }
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
  /// **対象の顔ぶれが同じ回は引かない。** 着地点が複数ある以上この入口は何度も叩かれるが、
  /// 引き直しに意味があるのは worktree の顔ぶれが変わったときだけで、同じ顔ぶれの再取得は
  /// worktree 本数ぶんの往復をまるごと二重に払うだけになる（gh の取得列は 1 本で、そこが
  /// 詰まると後ろのユーザー操作まで待つ）。
  ///
  /// 記録は**発行の時点**で置く——取得は往復 N 本ぶんの秒数がかかるので、着地を待って記録すると
  /// その間に来たもう一方の着地点が同じ顔ぶれを二重に引いてしまう。取得できなかったら記録を戻し、
  /// 次の着地点が引き直せるようにする。
  func loadBranchPullRequests(_ repo: GitRepo) {
    guard githubReady else { return }
    let heads = Self.branchPRHeads(of: worktrees)
    guard !heads.isEmpty, heads != requestedBranchPRHeads else { return }
    requestedBranchPRHeads = heads
    GitHubCLI.shared.branchPullRequests(cwd: repo.root, heads: heads) { [weak self] fetched in
      // キャッシュ書き込みは `self` の生存判定より前（issues/PR と同じ理由）。
      if let fetched {
        DispatchGitHubCache.shared.setBranchPullRequests(fetched, for: repo.commonDir)
      } else {
        self?.requestedBranchPRHeads = nil
      }
      self?.applyFetchedBranchPullRequests(fetched)
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

  /// 取得失敗（nil）は差し替えず据え置く。等値なら rebuild もしない（他 2 レーンと同じ規則）。
  func applyFetchedBranchPullRequests(_ fetched: [GitHubBranchPR]?) {
    guard let fetched, fetched != branchPullRequests else { return }
    branchPullRequests = fetched
    rebuild()
  }
}
