import Foundation

/// worktree パレットのデータ供給。リポジトリの事実の層（`WorktreeRepoFacts`）の上に、パレットだけの関心——タブの
/// 占有・前回のベース・clean の判定材料（ブランチの PR・分類の実測）・打った名前の確認・欄の組み立て・モデルの書き込み
/// ——を重ねる。事実の層が知らせるたびに、欄を組み直し（`rebuild`）、clean の判定材料を追従させる。Enter 実行の
/// 対象ディレクトリの解決（既存 worktree 再利用／新規作成）は事実の層が持つ。
/// section 組み立ては純粋な `WorktreePaletteSectionBuilder` に委ねる。
/// 全メソッドはメインスレッドで呼ばれる（`GitRunner` 契約）。
final class WorktreePaletteDataProvider {
  let facts: WorktreeRepoFacts
  private(set) weak var model: WorktreePaletteModel?
  /// 実行失敗メッセージ（palette 表示）を現在言語で出すためのストア。分冊（`+Clean`）も読む。
  var localization: LocalizationStore { facts.localization }
  /// 開いた時点のタブ占有スナップショット（`SessionStore` を worktree パレットから見せないための値型）。
  /// 読み手は分冊（`WorktreePaletteDataProvider+CleanProbe.swift`）。
  let tabOccupancies: [TabOccupancy]
  /// 開いた workspace に保存された前回のベース（読むだけ。書くのはウィンドウ）。
  let previousBase: String?
  /// gh の実行基盤。読み手は分冊（`WorktreePaletteDataProvider+GitHub.swift`）。
  var gitHub: GitHubCLI { facts.gitHub }

  /// 問い合わせたブランチ名 → 今回の取得の状態（中身は絞る前の生の結果）。**記録は発行の時点で置く**
  /// （`issuedProbeTargets` と同じ流儀）——着地を待って記録すると、その間に来たもう一方の着地点が
  /// 同じブランチを二重に引く。台帳と in-flight を 1 つの値で持つので、二重管理が生まれない。
  /// 書き手は分冊（`WorktreePaletteDataProvider+GitHub.swift`）。
  var branchPRFetches: [String: BranchPRState] = [:]
  /// 分類レーンの実測結果（path → 実測）。nil の間は分類そのものが未着地。
  ///
  /// 非 nil でも**全 path が揃っているとは限らない**——prober は main worktree と占有行を省くので
  /// それらは恒常的に不在で、差分発行が全量発行より先に着地した回は一時的に部分辞書になる。
  /// 書き手は分冊（`WorktreePaletteDataProvider+CleanProbe.swift`）。
  var cleanProbes: [String: WorktreeCleanProbe]?
  /// path → **発行時点**の取り込み判定の比較先リスト。「発行時点で記録する顔ぶれ dedup」——
  /// 比較先が同じ行を引き直さず、gh 着地で base が判明した行だけを引き直すための台帳。
  /// 台帳に無い path のエントリは着地時に落とす（削除済み worktree の残骸を持たない）。
  ///
  /// **nil は「全量発行がまだ一度も走っていない」**＝`fetch --prune` 前を意味し、差分発行
  /// （`CleanProbeScope.changedTargets`）はこの間 1 本も撃たない。空辞書へ丸めてはならない
  /// ——丸めると「台帳に無い＝比較先が変わった」と読んで prune 前に全行が飛ぶ。
  var issuedProbeTargets: [String: [String]]?
  /// 全量発行の世代。独立レーン（concurrent）は順序保証が無いので、**比較先が同じまま**撃たれる
  /// 全量発行どうし（初回・`fetch --prune` 後・削除後）の遅着を、比較先の照合だけでは弾けない。
  /// prune 前の結果が prune 後の結果を上書きすると「マージ直後の行が未取り込みのまま」という
  /// この機能の主用途そのものの失敗になるので、世代で切る。
  var probeGeneration = 0
  /// path → 発行済みで未着地のプローブの本数。**行ごとの準備完了の入力**。
  /// 集合ではなく多重集合で持つ——全量発行と差分発行が同じ path に重なったとき、先に着地した
  /// ほうで「揃った」と読むと、後から来る本命の結果より先に行が選べてしまう。
  /// 書き手は分冊（`WorktreePaletteDataProvider+CleanProbe.swift`）。
  var probingPaths: [String: Int] = [:]

  /// 分類の材料がまだ動いているか（clean 画面の待機表示の唯一の入力）。非 git では立たない
  /// ——分類レーンがそもそも走らないので、待っても何も来ない。
  var classificationPending: Bool { classificationPending(branchPRStates) }

  /// head の状態を渡す版。`rebuild()` は分類器へ渡すぶんと同じ 1 つの `branchPRStates` から
  /// 待機表示も導く——`branchPRStates` は毎回キャッシュを引き直す導出値なので、1 回の描画のうちに
  /// 別々に組むと、同じ 1 フレームが 2 つの時点を混ぜて語りうる。
  func classificationPending(_ states: [String: BranchPRState]) -> Bool {
    guard facts.repo != nil else { return false }
    return cleanProbes == nil || !probingPaths.isEmpty || states.values.contains(.fetching)
  }

  init(
    cwd: String, model: WorktreePaletteModel, localization: LocalizationStore,
    worktreeTemplate: String, tabOccupancies: [TabOccupancy] = [], previousBase: String? = nil,
    runner: GitRunner = .shared, gitHub: GitHubCLI = .shared
  ) {
    facts = WorktreeRepoFacts(
      cwd: cwd, localization: localization, worktreeTemplate: worktreeTemplate, runner: runner,
      gitHub: gitHub)
    self.model = model
    self.tabOccupancies = tabOccupancies
    self.previousBase = previousBase
    facts.onChange = { [weak self] in self?.factsChanged($0) }
  }

  /// パレットから切り離す。進行中の読み取りが後から着地しても、もうパレットを書かない（パレットが別の
  /// リポジトリを読み直すとき）。
  func detach() { model = nil }

  func load() { facts.load() }

  /// 事実の層の知らせ。git の着地は ref の中身が動いた着地（`classifying`）でだけ分類を全行撃つ——分類の到達性
  /// 判定は prune 済みの `refs/remotes/origin/*` を前提にする（prune 前の origin には remote で消えた ref が残って
  /// おり、そこからの到達性を根拠にすると「消してもコミットは origin に残る」が偽になる）。ブランチの PR は
  /// worktree 一覧・gh の確認・remote の台帳の各着地点から同じ入口を叩く（顔ぶれが同じ回は入口が畳む）。
  private func factsChanged(_ change: WorktreeRepoFacts.Change) {
    switch change {
    case .outsideRepository:
      rebuild()
    case .git(let classifying):
      rebuild()
      guard let repo = facts.repo else { return }
      if classifying { startCleanProbe(repo, .all) }
      loadBranchPullRequests(repo)
    case .gitHubProbed:
      if let repo = facts.repo { loadBranchPullRequests(repo) }
      rebuild()
    case .repositoryNamesResolved:
      applyResolvedRepository()
    }
  }

  /// 打った名前が新しいブランチの名前として有効かを git に問い、答えを model へ返す（古い問いの答えは
  /// model が捨てる）。リポジトリを要さないので、一覧が届く前に打った名前にも答える。
  func checkBranchName(_ name: String) {
    GitRepo.checkBranchName(name, cwd: facts.cwd, runner: facts.runner) { [weak self] isValid in
      self?.model?.applyBranchNameCheck(name, isValid: isValid)
    }
  }

  /// 手元の状態から model を組み直す（描画の唯一の出口）。事実の層の知らせ・gh 着地（分冊
  /// `WorktreePaletteDataProvider+GitHub.swift`）と、先頭の欄の入力（モデルの `taskInputs`）の変化も同じ出口を通る。
  /// git の列挙が一度着地するまでは描かない——gh レーンが先に着地しても、空の一覧を「ロード済み」として出すと、
  /// 開いた直後の ↵ が空の一覧で決着して空振りする。
  func rebuild() {
    guard let model, facts.isOutsideRepository || facts.hasLandedGit else { return }
    let selectedAction = model.selectedItem?.action
    guard !facts.isOutsideRepository else {
      // 非 git: 「このディレクトリ」の 1 行だけ。
      model.taskTargetPending = false
      model.hasLoadedOnce = true
      model.sections = WorktreePaletteSectionBuilder.directorySections(path: facts.cwd)
      model.restoreSelection(matching: selectedAction)
      return
    }
    let prStates = branchPRStates
    let rows = cleanProbes.map {
      WorktreeCleanClassifier.rows(
        WorktreeCleanClassifier.Input(
          worktrees: facts.worktrees, localBranches: facts.localBranches,
          branchPRStates: prStates, probes: $0, probingPaths: Set(probingPaths.keys),
          tabs: tabOccupancies))
    }
    // 待機表示は行より先に据える（0 行の瞬間にスケルトンを描くかがここで決まる）。
    model.classificationPending = classificationPending(prStates)
    model.classification = rows
    model.hasLoadedOnce = true
    model.baseFacts = baseFacts
    model.baseCandidates = baseCandidates
    let newBranchRules = facts.newBranchRules
    model.newBranchRules = newBranchRules
    let taskInputs = model.taskInputs
    let taskTarget = facts.taskTarget(taskInputs)
    model.taskTargetPending = taskTarget == .pending
    model.sections = WorktreePaletteSectionBuilder.build(
      WorktreePaletteSectionBuilder.Input(
        worktrees: facts.worktrees, localBranches: facts.localBranches,
        remoteBranches: facts.remoteBranches,
        repositoryName: (facts.worktreeBase as NSString).lastPathComponent,
        currentWorktree: facts.currentWorktree?.path,
        cleanCandidates: rows.map(WorktreeCleanClassifier.candidateCount),
        remoteFetchLanded: facts.remoteFetchLanded, taskTarget: taskTarget,
        taskNumber: taskInputs.primary?.item.number, newBranchRules: newBranchRules))
    model.restoreSelection(matching: selectedAction)
  }

  /// ベースの選択肢の事実。前回は今の列挙にあるときだけ（消えたブランチを前回として出さない）。
  private var baseFacts: WorktreeBaseFacts {
    let known = Set((facts.localBranches + facts.remoteBranches).map(\.name))
    return WorktreeBaseFacts(
      previous: previousBase.flatMap { known.contains($0) ? $0 : nil },
      defaultBranch: facts.defaultBranchName,
      current: facts.currentWorktree?.branch)
  }

  /// ベースを選ぶ画面の候補。ローカルブランチ（checkout 中のものを含む）の後にリモートブランチを、
  /// それぞれ列挙の順（新しい順）で。
  private var baseCandidates: [WorktreeBaseCandidate] {
    facts.localBranches.map {
      .init(name: $0.name, relativeDate: $0.relativeDate, isRemote: false)
    }
      + facts.remoteBranches.map {
        .init(name: $0.name, relativeDate: $0.relativeDate, isRemote: true)
      }
  }
}
