import Foundation

/// clean の判定材料のうち gh から引くもの（worktree のブランチの PR）の取得と着地。gh の可用性と remote の台帳は
/// 事実の層（`WorktreeRepoFacts`）が持ち、ここはその知らせを受けて引き、着地の規則（失敗は据え置き）までを持つ。
/// 描画は本体の `rebuild()` へ流す。
extension WorktreePaletteDataProvider {
  /// 正式名の答えが変わった着地。行の同一性が変わるので、ブランチの PR を引き、比較先の変わった行の
  /// 分類を引き直してから描く（`applyFetchedBranchPRs` と同じ順序の理由）。
  func applyResolvedRepository() {
    if let repo = facts.repo {
      loadBranchPullRequests(repo)
      startCleanProbe(repo, .changedTargets)
    }
    rebuild()
  }

  /// ブランチの PR（`--state all` で open / closed の両方。掃除の安全確認・推定にだけ使う）を、
  /// **worktree にあるブランチの名指し**で引く。直近 N 件の一覧窓では、窓落ちした PR のぶんだけ
  /// 「マージ済みなのに merged チップが出ない」「レビュー中なのに安全確認を素通りする」が起きる——
  /// 対象を worktree のブランチに絞れば件数は worktree 本数で抑えられ、窓の概念そのものが消える。
  /// 名指しするのは、同一性が GitHub のブランチ（`.ref`）になる worktree のローカル名だけ。
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
    guard facts.githubReady, case .settled(let resolved) = facts.remoteLedger else { return }
    let identities = GitHubBranchIdentities(resolved: resolved, localBranches: facts.localBranches)
    let heads = Self.worktreeBranches(of: facts.worktrees).filter { branch in
      if case .ref = identities.local(branch) { return true }
      return false
    }
    let seen = Set(heads)
    // 削除で消えた worktree の残骸を持たない。
    branchPRFetches = branchPRFetches.filter { seen.contains($0.key) }
    let pending = heads.filter { branchPRFetches[$0] == nil }
    guard !pending.isEmpty else { return }
    for head in pending { branchPRFetches[head] = .fetching }
    gitHub.branchPullRequests(cwd: repo.root, heads: pending) { [weak self] head, prs in
      // キャッシュ書き込みは `self` の生存判定より前——provider はパレットと同じ寿命で、gh の応答前に
      // 閉じられるのが常用経路。self が消えたら捨てる作りだと次回の先描きが永遠に温まらない。
      if let prs {
        GitHubCache.shared.setBranchPullRequests(prs, head: head, for: repo.commonDir)
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
  /// 3. 台帳が未確定 → 取得中（安全群に入らない）
  /// 4. 行を確かめられない → 取得失敗（安全群に入らない）
  /// 5. GitHub の行でない → 確かめて 0 件
  /// 6. 今回の取得の結果。未着地／失敗のブランチは、前回セッションの結果があればそれで確定させる
  ///    （stale-while-revalidate。「取得失敗は据え置き」をブランチ単位に保つ）
  var branchPRStates: [String: BranchPRState] {
    let branches = Self.worktreeBranches(of: facts.worktrees)
    func all(_ state: BranchPRState) -> [String: BranchPRState] {
      Dictionary(uniqueKeysWithValues: branches.map { ($0, state) })
    }
    guard let probed = facts.probedGitHubState else { return all(.fetching) }
    guard probed == .ready else { return all(.loaded([])) }
    guard case .settled(let resolved) = facts.remoteLedger else { return all(.fetching) }
    let identities = GitHubBranchIdentities(resolved: resolved, localBranches: facts.localBranches)
    let cached =
      facts.repo.flatMap { GitHubCache.shared.entry(for: $0.commonDir)?.branchPullRequests }
      ?? [:]
    let states = branches.map { branch -> (String, BranchPRState) in
      let ref: GitHubBranchRef
      switch identities.local(branch) {
      case .unverified: return (branch, .failed)
      case .notGitHub: return (branch, .loaded([]))
      case .ref(let identity): ref = identity
      }
      let fetched: BranchPRState
      switch branchPRFetches[ref.branch] {
      case .loaded(let prs): fetched = .loaded(prs)
      case .failed: fetched = cached[ref.branch].map(BranchPRState.loaded) ?? .failed
      case .fetching, nil: fetched = cached[ref.branch].map(BranchPRState.loaded) ?? .fetching
      }
      guard case .loaded(let prs) = fetched else { return (branch, fetched) }
      return (branch, .loaded(GitHubBranchPR.filter(prs, headedBy: ref)))
    }
    return Dictionary(uniqueKeysWithValues: states)
  }

  /// 着地済みの PR（worktree のブランチごと・ref で絞った後。`extraContainmentTargets` の入力）。
  var landedBranchPRs: [String: [GitHubBranchPR]] {
    branchPRStates.compactMapValues { state in
      guard case .loaded(let prs) = state else { return nil }
      return prs
    }
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
    if let repo = facts.repo { startCleanProbe(repo, .changedTargets) }
    rebuild()
  }
}
