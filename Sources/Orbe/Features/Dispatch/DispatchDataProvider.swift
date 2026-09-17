import Foundation

/// Dispatch の非同期オーケストレータ。git（local・即時）を先に描き、gh（ネット）を追従で差し替える
/// プログレッシブ表示を駆動し、Enter 実行の対象ディレクトリ解決（既存 worktree 再利用／新規作成）も担う。
/// section 組み立ては純粋な `DispatchSectionBuilder`、実データ取得は `GitRepo`/`GitHubCLI` に委ねる。
/// 全メソッドはメインスレッドで呼ばれ、`GitRepo`/`GitHubCLI` の completion もメインで返る（`GitRunner` 契約）。
final class DispatchDataProvider {
  /// 読み手は分冊（`DispatchDataProvider+Create.swift`）。
  let cwd: String
  /// 分冊（`DispatchDataProvider+GitHub.swift`）も読む（gh 状態の反映）。
  private(set) weak var model: DispatchPaletteModel?
  /// 実行失敗メッセージ（palette 表示）を現在言語で出すためのストア（提示元＝WindowController が渡す）。
  /// 分冊（`DispatchDataProvider+Clean.swift`）も読む。
  let localization: LocalizationStore
  /// worktree 新規作成先のテンプレート（実効設定 `worktree-dir`）。パレットは開くたびに生成されるため、
  /// 提示元が開く時点の実効値を注入する＝常に最新値で解決する。
  /// 読み手は分冊（`DispatchDataProvider+Create.swift`）。
  let worktreeTemplate: String
  /// 開いた時点のタブ占有スナップショット（`SessionStore` を Dispatch から見せないための値型）。
  /// 読み手は分冊（`DispatchDataProvider+CleanProbe.swift`）。
  let tabOccupancies: [TabOccupancy]
  private let runner: GitRunner
  /// 提示時に発行した `fetch --prune` の着地。ベースから新しいブランチを切る作成は、この着地を
  /// 待ってから撃つ（`createWorktree`）。1 回きりのイベントなので台帳ではなく `DispatchGroup` で持つ
  /// ——未着地なら着地後に・着地済み／未発行なら即実行、が `notify` の定義そのもの。
  /// 待つ側は分冊（`DispatchDataProvider+Create.swift`）。
  let remoteFetchLanding = DispatchGroup()

  private(set) var repo: GitRepo?
  /// 本体 worktree のパス。読み手は分冊（`DispatchDataProvider+Create.swift`）。
  private(set) var mainWorktree: String?
  /// 既定ブランチの ref。`git symbolic-ref --short refs/remotes/origin/HEAD` の出力なので
  /// `origin/main` という remote 追跡名で、取り込み判定の比較対象と新規 worktree の base に使う。
  /// 表示名（`origin/` 剥がし）は verdict を受けた分類器が導く。
  /// 読み手は分冊（`DispatchDataProvider+CleanProbe.swift`）。
  private(set) var defaultBranchName = "main"

  /// 分冊（`DispatchDataProvider+Clean.swift` / `+GitHub.swift`）も読む。
  private(set) var worktrees: [GitWorktree] = []
  private var localBranches: [GitBranch] = []
  /// 読み手は分冊（`DispatchDataProvider+CleanProbe.swift`）。
  private(set) var remoteBranches: [GitBranch] = []
  // gh レーンの状態。書き手は分冊（`DispatchDataProvider+GitHub.swift`）、読み手は `rebuild`。
  var issues: [GitHubIssue] = []
  var pullRequests: [GitHubPullRequest] = []
  /// probe の結果。`nil` = probe 未完。可用性を Optional で持つことで「まだ確かめていない」と
  /// 「確かめて取得可」を 1 つの値で区別する（両者を潰すと、確認前の状態が「gh 確認済み」を
  /// 名乗ってしまう）。
  var probedGitHubState: GitHubAvailability?
  /// 画面に出す可用性。probe 未完の間は `.ready` として振る舞う（確定前にセクションを畳まない）。
  var githubState: GitHubAvailability { probedGitHubState ?? .ready }
  /// ブランチの PR を実際に引ける状態か。取得は git レーン（worktree 一覧）と gh レーン（認証確認）の
  /// 両方が要り、probe 前に発火すると gh 不在の環境で worktree 本数ぶんの失敗プロセスを撒く。
  var githubReady: Bool { probedGitHubState == .ready }
  /// head → 今回の取得の状態。**記録は発行の時点で置く**（`issuedProbeTargets` と同じ流儀）——
  /// 着地を待って記録すると、その間に来たもう一方の着地点が同じ head を二重に引く。
  /// 台帳と in-flight を 1 つの値で持つので、二重管理が生まれない。
  /// 書き手は分冊（`DispatchDataProvider+GitHub.swift`）。
  var branchPRFetches: [String: BranchPRState] = [:]
  var issuesLoading = true
  var pullRequestsLoading = true
  /// 分類レーンの実測結果（path → 実測）。nil の間は分類そのものが未着地。
  ///
  /// 非 nil でも**全 path が揃っているとは限らない**——prober は main worktree と占有行を省くので
  /// それらは恒常的に不在で、差分発行が全量発行より先に着地した回は一時的に部分辞書になる。
  /// 書き手は分冊（`DispatchDataProvider+CleanProbe.swift`）。
  var cleanProbes: [String: DispatchCleanProbe]?
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
  /// 書き手は分冊（`DispatchDataProvider+CleanProbe.swift`）。
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

  /// gh 取得の上限件数（issues / open PR の一覧。分冊も読む）。
  let ghLimit = 30

  init(
    cwd: String, model: DispatchPaletteModel, localization: LocalizationStore,
    worktreeTemplate: String, tabOccupancies: [TabOccupancy] = [], runner: GitRunner = .shared
  ) {
    self.cwd = cwd
    self.model = model
    self.localization = localization
    self.worktreeTemplate = worktreeTemplate
    self.tabOccupancies = tabOccupancies
    self.runner = runner
  }

  // MARK: - ロード

  func load() {
    GitRepo.open(cwd: cwd, runner: runner) { [weak self] repo in
      guard let self else { return }
      guard let repo else {
        // 非 git: 全セクション空（Issues/PR も出さない）。
        self.probedGitHubState = .notGitHub
        self.issuesLoading = false
        self.pullRequestsLoading = false
        self.rebuild()
        return
      }
      self.repo = repo
      self.applyCachedGitHub(repo)
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
  /// 新規ブランチを切る worktree 作成（`createWorktree`）もこの fetch の着地を待つので、`enter()` は
  /// **発行の直前**に置く——発行と `enter()` の間に窓を空けると、そこで撃たれた作成が待たずに通る。
  /// `leave()` は completion に 1 つ（成否どちらでも 1 回呼ばれる `GitRunner` 契約）で、group 自体を
  /// 強く捕まえる——provider が先に消えても enter/leave の対は閉じる。
  private func loadRemotePrune(_ repo: GitRepo) {
    let landing = remoteFetchLanding
    landing.enter()
    repo.fetchPrune { [weak self] _ in
      landing.leave()
      self?.loadGit(repo, classifying: true)
    }
  }

  /// git レーンを引き直す。分冊（`DispatchDataProvider+Clean.swift`）が削除の完了時にも撃つ。
  ///
  /// `classifying` が真のときだけ分類プローブも撃つ——分類の到達性判定は prune 済みの
  /// `refs/remotes/origin/*` を前提にする（prune 前の origin には remote で消えた ref が残っており、
  /// そこからの到達性を根拠にすると「消してもコミットは origin に残る」が偽になる）ので、
  /// prune より前の呼びには載せない。
  func loadGit(_ repo: GitRepo, classifying: Bool) {
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
    // 分類（レーン D）は worktree 一覧と既定ブランチが揃ってはじめて叩けるのでここから起動する。
    // ブランチの PR も worktree 一覧が要る（名指しの取得）ので同じ着地点から叩く——削除で
    // worktree の顔ぶれが変われば対象も変わる。顔ぶれが同じ回は入口が畳むので、何度叩いても安い。
    group.notify(queue: .main) {
      self.rebuild()
      // git の事実（ref の中身）が動いた着地なので全行引き直す。
      if classifying { self.startCleanProbe(repo, .all) }
      self.loadBranchPullRequests(repo)
    }
  }

  /// 手元の状態から model を組み直す（描画の唯一の出口）。gh 着地（分冊
  /// `DispatchDataProvider+GitHub.swift`）も同じ出口を通る。
  func rebuild() {
    guard let model else { return }
    let selectedAction = model.selectedItem?.action
    let prStates = branchPRStates
    let rows = cleanProbes.map {
      DispatchWorktreeClassifier.rows(
        DispatchWorktreeClassifier.Input(
          worktrees: worktrees, localBranches: localBranches,
          branchPRStates: prStates, probes: $0, probingPaths: Set(probingPaths.keys),
          tabs: tabOccupancies))
    }
    // 待機表示は行より先に据える（0 行の瞬間にスケルトンを描くかがここで決まる）。
    model.classificationPending = classificationPending(prStates)
    model.classification = rows
    model.hasLoadedOnce = true
    model.sections = DispatchSectionBuilder.build(
      DispatchSectionBuilder.Input(
        worktrees: worktrees, localBranches: localBranches, remoteBranches: remoteBranches,
        issues: issues, pullRequests: pullRequests, githubState: githubState,
        issuesLoading: issuesLoading, pullRequestsLoading: pullRequestsLoading,
        currentWorktree: repo?.root,
        cleanCandidates: rows.map(DispatchWorktreeClassifier.candidateCount)))
    model.restoreSelection(matching: selectedAction)
  }
}
