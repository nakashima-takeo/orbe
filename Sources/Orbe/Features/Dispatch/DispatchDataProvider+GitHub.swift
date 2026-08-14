import Foundation

/// gh レーンの取得と着地。probe（可否判定）→ 取得（issues / open PR / 閉じた PR）→ 着地の規則
/// （失敗は据え置き・等値は再描画しない）までを持ち、描画は本体の `rebuild()` へ流す。
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
    // 掃除の推定（PR が MERGED か）は行の出し分けに関わらないので loading の概念を持たない。
    if let cached = entry.closedPullRequests { closedPullRequests = cached }
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
        self.loadClosedPullRequests(repo)
      }
    }
  }

  /// 閉じた PR（`closed` は MERGED も含む。掃除の推定と merged チップにだけ使う）を、
  /// **worktree にあるブランチの名指し**で引く。直近 N 件の一覧窓では、古くにマージされた PR が
  /// 窓から溢れて「PR でマージしたブランチに merged チップが出ない」取りこぼしになる——
  /// 対象を worktree のブランチに絞れば件数は worktree 本数で抑えられ、窓の概念そのものが消える。
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
  func loadClosedPullRequests(_ repo: GitRepo) {
    guard githubReady else { return }
    let heads = Self.closedPRHeads(of: worktrees)
    guard !heads.isEmpty, heads != requestedClosedPRHeads else { return }
    requestedClosedPRHeads = heads
    GitHubCLI.shared.closedPullRequests(cwd: repo.root, heads: heads) { [weak self] fetched in
      // キャッシュ書き込みは `self` の生存判定より前（issues/PR と同じ理由）。
      if let fetched {
        DispatchGitHubCache.shared.setClosedPullRequests(fetched, for: repo.commonDir)
      } else {
        self?.requestedClosedPRHeads = nil
      }
      self?.applyFetchedClosedPullRequests(fetched)
    }
  }

  /// 閉じた PR 取得の対象ブランチ。worktree にあるブランチだけ——main worktree は掃除の対象外、
  /// detached（`branch == nil`）は PR の head になり得ない。
  static func closedPRHeads(of worktrees: [GitWorktree]) -> [String] {
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
  func applyFetchedClosedPullRequests(_ fetched: [GitHubClosedPR]?) {
    guard let fetched, fetched != closedPullRequests else { return }
    closedPullRequests = fetched
    rebuild()
  }
}
