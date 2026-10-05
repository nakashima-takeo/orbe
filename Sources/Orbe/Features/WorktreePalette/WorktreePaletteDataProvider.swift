import Foundation

/// worktree パレットの非同期オーケストレータ。git（local・即時）で一覧を描き、gh（ネット）は clean の
/// 判定材料（ブランチの PR）とタスクの欄の解決として追従させ、Enter 実行の対象ディレクトリ解決
/// （既存 worktree 再利用／新規作成）も担う。
/// section 組み立ては純粋な `WorktreePaletteSectionBuilder`、実データ取得は `GitRepo`/`GitHubCLI` に委ねる。
/// 全メソッドはメインスレッドで呼ばれ、`GitRepo`/`GitHubCLI` の completion もメインで返る（`GitRunner` 契約）。
final class WorktreePaletteDataProvider {
  /// 読み手は分冊（`WorktreePaletteDataProvider+Create.swift`）。
  let cwd: String
  private(set) weak var model: WorktreePaletteModel?
  /// 実行失敗メッセージ（palette 表示）を現在言語で出すためのストア（提示元＝WindowController が渡す）。
  /// 分冊（`WorktreePaletteDataProvider+Clean.swift`）も読む。
  let localization: LocalizationStore
  /// worktree 新規作成先のテンプレート（実効設定 `worktree-dir`）。パレットは開くたびに生成されるため、
  /// 提示元が開く時点の実効値を注入する＝常に最新値で解決する。
  /// 読み手は分冊（`WorktreePaletteDataProvider+Create.swift`）。
  let worktreeTemplate: String
  /// 開いた時点のタブ占有スナップショット（`SessionStore` を worktree パレットから見せないための値型）。
  /// 読み手は分冊（`WorktreePaletteDataProvider+CleanProbe.swift`）。
  let tabOccupancies: [TabOccupancy]
  /// 開いた workspace に保存された前回のベース（読むだけ。書くのはウィンドウ）。
  let previousBase: String?
  private let runner: GitRunner
  /// gh の実行基盤。読み手は分冊（`WorktreePaletteDataProvider+GitHub.swift`）。
  let gitHub: GitHubCLI
  /// 提示時に発行した `fetch --prune` の着地。ベースから新しいブランチを切る作成は、この着地を
  /// 待ってから撃つ（`createWorktree`）。1 回きりのイベントなので台帳ではなく `DispatchGroup` で持つ
  /// ——未着地なら着地後に・着地済み／未発行なら即実行、が `notify` の定義そのもの。
  /// 待つ側は分冊（`WorktreePaletteDataProvider+Create.swift`）。
  ///
  /// **着地は fetch プロセスの完了ではなく、その後の git 列挙の引き直しが揃った時点**——ベース ref の
  /// 中身だけでなく、ベースの名前（`defaultBranchName`）も fetch 後の値になる。fetch は `origin/HEAD`
  /// を作ることがある（git の `followRemoteHEAD` 既定）ので、中身だけ待つと `origin/HEAD` を持たない
  /// repo で既定ブランチからの新規がフォールバックの固定名を指したまま撃たれる。
  let remoteFetchLanding = DispatchGroup()
  /// `remoteFetchLanding` が明けた（列挙が fetch 後の値になった）。着地と同じ点で立てる——fetch の
  /// 完了ハンドラで立てると、引き直しの前に別レーンの着地が `rebuild` を呼び、fetch 前の値で
  /// Local branch 行の同期ピルが描かれる。
  private(set) var remoteFetchLanded = false

  private(set) var repo: GitRepo?
  /// cwd が git リポジトリの外と分かった（一覧は「このディレクトリ」の 1 行になる）。
  private(set) var isOutsideRepository = false
  /// git レーン（worktree・ブランチの列挙）が一度着地した。それまでは描かない——gh レーンが先に着地しても、
  /// 空の一覧を「ロード済み」として出すと、開いた直後の ↵ が空の一覧で決着して空振りする。
  private var hasLandedGit = false
  /// 本体 worktree のパス。読み手は分冊（`WorktreePaletteDataProvider+Create.swift`）。
  private(set) var mainWorktree: String?
  /// 既定ブランチの ref。`git symbolic-ref --short refs/remotes/origin/HEAD` の出力なので
  /// `origin/main` という remote 追跡名で、取り込み判定の比較対象と新規 worktree の base に使う。
  /// 表示名（`origin/` 剥がし）は verdict を受けた分類器が導く。
  /// 読み手は分冊（`WorktreePaletteDataProvider+CleanProbe.swift`）。
  private(set) var defaultBranchName = "main"

  /// 分冊（`WorktreePaletteDataProvider+Clean.swift` / `+GitHub.swift`）も読む。
  private(set) var worktrees: [GitWorktree] = []
  /// 読み手は分冊（`WorktreePaletteDataProvider+Create.swift`。Local branch 行の Enter の判定）。
  private(set) var localBranches: [GitBranch] = []
  /// 読み手は分冊（`WorktreePaletteDataProvider+CleanProbe.swift`）。
  private(set) var remoteBranches: [GitBranch] = []
  /// remote の一覧の読み取り。`nil` = 未着（remote の台帳は未確定）。書き手は `loadGit`、読み手は分冊
  /// （`WorktreePaletteDataProvider+GitHub.swift`。台帳と正式名の問い合わせ）。
  var remoteListing: RemoteListing?
  /// probe の結果。`nil` = probe 未完。可用性を Optional で持つことで「まだ確かめていない」と
  /// 「確かめて取得可」を 1 つの値で区別する（両者を潰すと、確認前の状態が「gh 確認済み」を
  /// 名乗ってしまう）。
  var probedGitHubState: GitHubAvailability?
  /// ブランチの PR を実際に引ける状態か。取得は git レーン（worktree 一覧）と gh レーン（認証確認）の
  /// 両方が要り、probe 前に発火すると gh 不在の環境で worktree 本数ぶんの失敗プロセスを撒く。
  var githubReady: Bool { probedGitHubState == .ready }
  /// 問い合わせたブランチ名 → 今回の取得の状態（中身は絞る前の生の結果）。**記録は発行の時点で置く**
  /// （`issuedProbeTargets` と同じ流儀）——着地を待って記録すると、その間に来たもう一方の着地点が
  /// 同じブランチを二重に引く。台帳と in-flight を 1 つの値で持つので、二重管理が生まれない。
  /// 書き手は分冊（`WorktreePaletteDataProvider+GitHub.swift`）。
  var branchPRFetches: [String: BranchPRState] = [:]
  /// この回に正式名を問い合わせた名前（remote の URL から読んだ名前）。答えはキャッシュが持ち、ここは
  /// 同じ名前を二重に撃たないための記録。記録は発行の時点で置く。
  /// 書き手は分冊（`WorktreePaletteDataProvider+GitHub.swift`）。
  var askedRepositories: Set<GitHubRepoName> = []
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
    guard repo != nil else { return false }
    return cleanProbes == nil || !probingPaths.isEmpty || states.values.contains(.fetching)
  }

  init(
    cwd: String, model: WorktreePaletteModel, localization: LocalizationStore,
    worktreeTemplate: String, tabOccupancies: [TabOccupancy] = [], previousBase: String? = nil,
    runner: GitRunner = .shared, gitHub: GitHubCLI = .shared
  ) {
    self.cwd = cwd
    self.model = model
    self.localization = localization
    self.worktreeTemplate = worktreeTemplate
    self.tabOccupancies = tabOccupancies
    self.previousBase = previousBase
    self.runner = runner
    self.gitHub = gitHub
  }

  /// パレットから切り離す。進行中の読み取りが後から着地しても、もうパレットを書かない（パレットが別の
  /// リポジトリを読み直すとき）。
  func detach() { model = nil }

  // MARK: - ロード

  func load() {
    GitRepo.open(cwd: cwd, runner: runner) { [weak self] repo in
      guard let self else { return }
      guard let repo else {
        // 非 git: 「このディレクトリ」の 1 行だけ。
        self.isOutsideRepository = true
        self.probedGitHubState = .notGitHub
        self.rebuild()
        return
      }
      self.repo = repo
      // prune 前なので分類は撃たない（一覧の worktree / branch 行だけ先に描く）。
      self.loadGit(repo, classifying: false)
      self.loadGitHub(repo)
      self.loadRemotePrune(repo)
    }
  }

  /// 裏で fetch --prune し、**成否を問わず**git レーンを分類ごと引き直す。prune が失敗しても手元の
  /// ref が最良で、ここで撃たないと分類が永遠に始まらない（clean が 1 行も出ないまま固まる）。
  ///
  /// **分類まで取り直すのが要点**——取り込み判定は到達性（`rev-list --not --remotes`）も cherry も
  /// `refs/remotes/*` の鮮度に依存するので、fetch 前の分類は「GitHub でマージした直後」に必ず
  /// 未取り込みと出る（この機能の主用途がそのまま外れる）。`[gone]` の出どころである
  /// `localBranches` も prune で初めて確定する。
  ///
  /// fetch 後の値に依存する経路（新規ブランチを切る作成・Local branch 行の遅れの判定）はこの fetch の
  /// 着地を待つので（`remoteFetchLanding`）、`enter()` は**発行の直前**に置く——発行と `enter()` の間に
  /// 窓を空けると、そこで撃たれた作成が待たずに通る。`leave()` は引き直しの着地に置く（`loadGit` は
  /// 削除の完了でも撃たれるので、対が prune 起点の 1 回にだけ付くよう完了ハンドラで受ける）。
  /// group 自体を強く捕まえるのは、provider が先に消えても対を閉じるため。
  private func loadRemotePrune(_ repo: GitRepo) {
    let landing = remoteFetchLanding
    landing.enter()
    repo.fetchPrune { [weak self] _ in
      guard let self else { return landing.leave() }
      self.loadGit(repo, classifying: true) { [weak self] in
        self?.remoteFetchLanded = true
        landing.leave()
      }
    }
  }

  /// git レーンを引き直す。分冊（`WorktreePaletteDataProvider+Clean.swift`）が削除の完了時にも撃つ。
  ///
  /// `classifying` が真のときだけ分類プローブも撃つ——分類の到達性判定は prune 済みの
  /// `refs/remotes/origin/*` を前提にする（prune 前の origin には remote で消えた ref が残っており、
  /// そこからの到達性を根拠にすると「消してもコミットは origin に残る」が偽になる）ので、
  /// prune より前の呼びには載せない。`landed` は 5 本の read が揃った時点で、**描画（`rebuild`）の前に**
  /// 1 度だけ呼ばれる——着地の定義は「列挙の引き直しまで」で、着地で立つ旗を読んで描く側と揃える。
  func loadGit(_ repo: GitRepo, classifying: Bool, landed: (() -> Void)? = nil) {
    let group = DispatchGroup()
    group.enter()
    repo.worktrees {
      self.worktrees = $0
      self.mainWorktree = $0.first(where: \.isMain)?.path
      group.leave()
    }
    group.enter()
    repo.localBranches {
      self.localBranches = $0
      group.leave()
    }
    group.enter()
    repo.remoteBranches {
      self.remoteBranches = $0
      group.leave()
    }
    group.enter()
    repo.defaultBranch {
      self.defaultBranchName = $0
      group.leave()
    }
    // remote の台帳の材料（clean のブランチの PR を引く前提）。
    group.enter()
    repo.remotes {
      self.remoteListing = $0.map(RemoteListing.read) ?? .unreadable
      group.leave()
    }
    // 分類（レーン D）は worktree 一覧と既定ブランチが揃ってはじめて叩けるのでここから起動する。
    // 正式名の問い合わせは remote の一覧が、ブランチの PR は worktree 一覧が要る（名指しの取得）ので
    // 同じ着地点から叩く——削除で worktree の顔ぶれが変われば対象も変わる。顔ぶれが同じ回は入口が
    // 畳むので、何度叩いても安い。
    group.notify(queue: .main) {
      landed?()
      self.hasLandedGit = true
      self.rebuild()
      // git の事実（ref の中身）が動いた着地なので全行引き直す。
      if classifying { self.startCleanProbe(repo, .all) }
      self.resolveRemoteRepositories(repo)
      self.loadBranchPullRequests(repo)
    }
  }

  /// 打った名前が新しいブランチの名前として有効かを git に問い、答えを model へ返す（古い問いの答えは
  /// model が捨てる）。リポジトリを要さないので、一覧が届く前に打った名前にも答える。
  func checkBranchName(_ name: String) {
    GitRepo.checkBranchName(name, cwd: cwd, runner: runner) { [weak self] isValid in
      self?.model?.applyBranchNameCheck(name, isValid: isValid)
    }
  }

  /// 手元の状態から model を組み直す（描画の唯一の出口）。gh 着地（分冊
  /// `WorktreePaletteDataProvider+GitHub.swift`）と、先頭の欄の入力（モデルの `taskInputs`）の変化も同じ出口を通る。
  func rebuild() {
    guard let model, isOutsideRepository || hasLandedGit else { return }
    let selectedAction = model.selectedItem?.action
    guard !isOutsideRepository else {
      model.taskTargetPending = false
      model.hasLoadedOnce = true
      model.sections = WorktreePaletteSectionBuilder.directorySections(path: cwd)
      model.restoreSelection(matching: selectedAction)
      return
    }
    let prStates = branchPRStates
    let rows = cleanProbes.map {
      WorktreeCleanClassifier.rows(
        WorktreeCleanClassifier.Input(
          worktrees: worktrees, localBranches: localBranches,
          branchPRStates: prStates, probes: $0, probingPaths: Set(probingPaths.keys),
          tabs: tabOccupancies))
    }
    // 待機表示は行より先に据える（0 行の瞬間にスケルトンを描くかがここで決まる）。
    model.classificationPending = classificationPending(prStates)
    model.classification = rows
    model.hasLoadedOnce = true
    model.baseFacts = baseFacts
    model.baseCandidates = baseCandidates
    model.newBranchRules = newBranchRules
    let taskInputs = model.taskInputs
    let taskTarget = taskTarget(taskInputs)
    model.taskTargetPending = taskTarget == .pending
    model.sections = WorktreePaletteSectionBuilder.build(
      WorktreePaletteSectionBuilder.Input(
        worktrees: worktrees, localBranches: localBranches, remoteBranches: remoteBranches,
        repositoryName: (worktreeBase as NSString).lastPathComponent,
        currentWorktree: currentWorktree?.path,
        cleanCandidates: rows.map(WorktreeCleanClassifier.candidateCount),
        remoteFetchLanded: remoteFetchLanded, taskTarget: taskTarget,
        taskNumber: taskInputs.primary?.item.number, newBranchRules: newBranchRules))
    model.restoreSelection(matching: selectedAction)
  }

  /// ベースの選択肢の事実。前回は今の列挙にあるときだけ（消えたブランチを前回として出さない）。
  private var baseFacts: WorktreeBaseFacts {
    let known = Set((localBranches + remoteBranches).map(\.name))
    return WorktreeBaseFacts(
      previous: previousBase.flatMap { known.contains($0) ? $0 : nil },
      defaultBranch: defaultBranchName,
      current: currentWorktree?.branch)
  }

  /// 今の worktree（cwd の属するチェックアウト）。`rev-parse --show-toplevel` は実パスを返すが、
  /// `git worktree list` は登録時のパス（symlink 経由のこともある）をそのまま返すので、文字列ではなく
  /// タブ占有の突き合わせと同じ正準形（`GitWorktreeRoot.normalizedPath`）で比べる。
  private var currentWorktree: GitWorktree? {
    guard let root = repo?.root else { return nil }
    let key = GitWorktreeRoot.normalizedPath(root)
    return worktrees.first { GitWorktreeRoot.normalizedPath($0.path) == key }
  }

  /// ベースを選ぶ画面の候補。ローカルブランチ（checkout 中のものを含む）の後にリモートブランチを、
  /// それぞれ列挙の順（新しい順）で。
  private var baseCandidates: [WorktreeBaseCandidate] {
    localBranches.map { .init(name: $0.name, relativeDate: $0.relativeDate, isRemote: false) }
      + remoteBranches.map { .init(name: $0.name, relativeDate: $0.relativeDate, isRemote: true) }
  }

  /// 作成行の衝突の規則（作成先は作成経路と同じテンプレートと repo の場所で解く）。
  private var newBranchRules: WorktreeNewBranchRules {
    WorktreeNewBranchRules(
      localBranches: localBranches.map(\.name), remoteBranches: remoteBranches.map(\.name),
      remoteBranchesLanded: remoteFetchLanded, worktreePaths: worktrees.map(\.path),
      template: worktreeTemplate, repoPath: worktreeBase)
  }
}
