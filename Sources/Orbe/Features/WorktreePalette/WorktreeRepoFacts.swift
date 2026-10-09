import Foundation

/// 1 つのリポジトリの事実を集めて答える処理役。画面を持たない。git の列挙（worktree・ローカル / リモートのブランチ・
/// 既定ブランチ・remote）、提示時の `fetch --prune` とその着地、gh の可用性と remote の正式名（remote の台帳）を持ち、
/// それらからタスクの行き先を決め（`taskTarget`）、worktree を用意する（`prepareDirectory`）。⌘T のデータ供給
/// （`WorktreePaletteDataProvider`）と、タスクから作業を始める口（`TaskWorkStart`）が同じこの層を通る。
/// 事実が動いたら `onChange` で知らせる。
/// 全メソッドはメインスレッドで呼ばれ、`GitRepo`/`GitHubCLI` の completion もメインで返る（`GitRunner` 契約）。
final class WorktreeRepoFacts {
  /// 動いた事実。
  enum Change {
    /// cwd が git リポジトリの外と分かった。
    case outsideRepository
    /// git の列挙が着地した。`classifying` は ref の中身が動いた着地（`fetch --prune` の後・削除の後）。
    case git(classifying: Bool)
    /// gh の可用性が分かった。
    case gitHubProbed
    /// remote の正式名の答えが変わった。
    case repositoryNamesResolved
  }

  var onChange: (Change) -> Void = { _ in }

  let cwd: String
  /// 実行失敗メッセージを現在言語で出すためのストア。
  let localization: LocalizationStore
  /// worktree 新規作成先のテンプレート（実効設定 `worktree-dir`）。読み手は分冊（`+Create`）。
  let worktreeTemplate: String
  let runner: GitRunner
  let gitHub: GitHubCLI
  /// 提示時に発行した `fetch --prune` の着地。ベースから新しいブランチを切る作成は、この着地を
  /// 待ってから撃つ（`createWorktree`）。1 回きりのイベントなので台帳ではなく `DispatchGroup` で持つ
  /// ——未着地なら着地後に・着地済み／未発行なら即実行、が `notify` の定義そのもの。
  ///
  /// **着地は fetch プロセスの完了ではなく、その後の git 列挙の引き直しが揃った時点**——ベース ref の
  /// 中身だけでなく、ベースの名前（`defaultBranchName`）も fetch 後の値になる。fetch は `origin/HEAD`
  /// を作ることがある（git の `followRemoteHEAD` 既定）ので、中身だけ待つと `origin/HEAD` を持たない
  /// repo で既定ブランチからの新規がフォールバックの固定名を指したまま撃たれる。
  let remoteFetchLanding = DispatchGroup()
  /// `remoteFetchLanding` が明けた（列挙が fetch 後の値になった）。着地と同じ点で立てる——fetch の
  /// 完了ハンドラで立てると、引き直しの前に別レーンの着地が描き直しを呼び、fetch 前の値で
  /// Local branch 行の同期ピルが描かれる。
  private(set) var remoteFetchLanded = false

  private(set) var repo: GitRepo?
  /// cwd が git リポジトリの外と分かった。
  private(set) var isOutsideRepository = false
  /// git レーン（worktree・ブランチの列挙）が一度着地した。
  private(set) var hasLandedGit = false
  /// 本体 worktree のパス。
  private(set) var mainWorktree: String?
  /// 既定ブランチの ref。`git symbolic-ref --short refs/remotes/origin/HEAD` の出力なので
  /// `origin/main` という remote 追跡名で、取り込み判定の比較対象と新規 worktree の base に使う。
  private(set) var defaultBranchName = "main"
  private(set) var worktrees: [GitWorktree] = []
  private(set) var localBranches: [GitBranch] = []
  private(set) var remoteBranches: [GitBranch] = []
  /// remote の一覧の読み取り。`nil` = 未着（remote の台帳は未確定）。
  var remoteListing: RemoteListing?
  /// probe の結果。`nil` = probe 未完。可用性を Optional で持つことで「まだ確かめていない」と
  /// 「確かめて取得可」を 1 つの値で区別する（両者を潰すと、確認前の状態が「gh 確認済み」を
  /// 名乗ってしまう）。
  var probedGitHubState: GitHubAvailability?
  /// gh で GitHub を引ける状態か。
  var githubReady: Bool { probedGitHubState == .ready }
  /// この回に正式名を問い合わせた名前（remote の URL から読んだ名前）。答えはキャッシュが持ち、ここは
  /// 同じ名前を二重に撃たないための記録。記録は発行の時点で置く。
  private var askedRepositories: Set<GitHubRepoName> = []

  init(
    cwd: String, localization: LocalizationStore, worktreeTemplate: String,
    runner: GitRunner = .shared, gitHub: GitHubCLI = .shared
  ) {
    self.cwd = cwd
    self.localization = localization
    self.worktreeTemplate = worktreeTemplate
    self.runner = runner
    self.gitHub = gitHub
  }

  // MARK: - ロード

  func load() {
    GitRepo.open(cwd: cwd, runner: runner) { [weak self] repo in
      guard let self else { return }
      guard let repo else {
        self.isOutsideRepository = true
        self.probedGitHubState = .notGitHub
        self.onChange(.outsideRepository)
        return
      }
      self.repo = repo
      // prune 前なので分類は撃たない（一覧の worktree / branch 行だけ先に描く）。
      self.loadGit(repo, classifying: false)
      self.loadGitHub(repo)
      self.loadRemotePrune(repo)
    }
  }

  /// 裏で fetch --prune し、**成否を問わず**git レーンを引き直す（`classifying` の着地として知らせる）。prune が
  /// 失敗しても手元の ref が最良で、ここで知らせないと分類が永遠に始まらない。
  ///
  /// fetch 後の値に依存する経路（新規ブランチを切る作成・Local branch 行の遅れの判定）はこの fetch の
  /// 着地を待つので（`remoteFetchLanding`）、`enter()` は**発行の直前**に置く——発行と `enter()` の間に
  /// 窓を空けると、そこで撃たれた作成が待たずに通る。`leave()` は引き直しの着地に置く（`loadGit` は
  /// 削除の完了でも撃たれるので、対が prune 起点の 1 回にだけ付くよう完了ハンドラで受ける）。
  /// group 自体を強く捕まえるのは、この層が先に消えても対を閉じるため。
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

  /// git レーンを引き直す。`landed` は 5 本の read が揃った時点で、**知らせる前に** 1 度だけ呼ばれる——着地の
  /// 定義は「列挙の引き直しまで」で、着地で立つ旗を読んで描く側と揃える。
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
    group.enter()
    repo.remotes {
      self.remoteListing = $0.map(RemoteListing.read) ?? .unreadable
      group.leave()
    }
    // 正式名の問い合わせは remote の一覧が要るので同じ着地点から叩く。
    group.notify(queue: .main) {
      landed?()
      self.hasLandedGit = true
      self.onChange(.git(classifying: classifying))
      self.resolveRemoteRepositories(repo)
    }
  }

  // MARK: - gh

  private func loadGitHub(_ repo: GitRepo) {
    repo.originIsGitHub { [weak self] isGitHub in
      guard let self else { return }
      gitHub.probe(cwd: repo.root, isGitHub: isGitHub) { [weak self] state in
        guard let self else { return }
        self.probedGitHubState = state
        if state == .ready { self.resolveRemoteRepositories(repo) }
        // 状態を問わず知らせる——clean の PR の事実と待機表示、タスクの行き先の待ちは probe の結果から導かれる
        // ので、`.ready` で着地しても、続く問い合わせが何も撃たない回（GitHub のブランチが無い等）では他に
        // 知らせる契機が無い。
        self.onChange(.gitHubProbed)
      }
    }
  }

  /// remote の一覧の読み取り結果。
  enum RemoteListing: Equatable {
    /// remote 名 → fetch の URL。
    case read([String: String])
    /// 読めなかった。どの remote が GitHub のどのリポジトリか分からないので、どの行も「確かめられない」
    /// になる（空の一覧として確定させると、どの行も「GitHub の行でない」になり、clean が PR の事実を
    /// 「確かめて 0 件」と読む）。
    case unreadable
  }

  /// remote の台帳（**導出値**。保存しない）。remote の一覧が未着なら未確定。答えはキャッシュだけから
  /// 読む——この回に問い直している名前も、前回の答えで先に描く。
  var remoteLedger: GitHubRemoteLedger {
    switch remoteListing {
    case nil: return .pending
    case .unreadable:
      return GitHubRemoteLedger(remotes: nil, answers: cachedRepositoryNames)
    case .read(let remotes):
      return GitHubRemoteLedger(remotes: remotes, answers: cachedRepositoryNames)
    }
  }

  var cachedRepositoryNames: [GitHubRepoName: GitHubRepositoryResolution] {
    repo.flatMap { GitHubCache.shared.entry(for: $0.commonDir)?.repositoryNames } ?? [:]
  }

  /// GitHub の remote の正式名を問い合わせる（改名前の URL でも、行と PR が同じリポジトリと分かる）。
  /// git レーン（remote の一覧）と gh レーン（認証確認）の両方が揃ってはじめて撃てるので、両側の
  /// 着地点から同じこの入口を叩き、先に来た側は素通りする。
  /// キャッシュの答えが正式名でなく、この回まだ撃っていない名前だけを撃ち、記録は発行の時点で置く。
  /// 「確かめられない」答えは、前回の値で先に描いたまま裏で問い直す（`gh auth switch` の後に開き直せば
  /// 直る）。1 つずつ撃つのは、1 つの `NOT_FOUND` で他の remote の答えまで失わないため。
  private func resolveRemoteRepositories(_ repo: GitRepo) {
    guard githubReady, case .read(let remotes) = remoteListing else { return }
    let cached = cachedRepositoryNames
    let pending = Set(remotes.values.compactMap(GitHubRepoName.init(remoteURL:)))
      .filter { name in
        if case .found = cached[name] { return false }
        return !askedRepositories.contains(name)
      }
    for name in pending {
      askedRepositories.insert(name)
      // 比べる相手は、この層が知らせた値（発行時のキャッシュ）。同じリポジトリを開いた別の層が
      // 先に同じ答えを書いていても、この層の知らせた値から変われば知らせる。
      let previous = cached[name]
      gitHub.resolveRepository(cwd: repo.root, name: name) { [weak self] resolution in
        // キャッシュ書き込みは `self` の生存判定より前——この層は画面と同じ寿命で、gh の応答前に
        // 閉じられるのが常用経路。self が消えたら捨てる作りだと次回の先描きが永遠に温まらない。
        GitHubCache.shared.setRepositoryName(resolution, for: name, key: repo.commonDir)
        guard resolution != previous else { return }
        self?.onChange(.repositoryNamesResolved)
      }
    }
  }

  // MARK: - 導出

  /// 今の worktree（cwd の属するチェックアウト）。`rev-parse --show-toplevel` は実パスを返すが、
  /// `git worktree list` は登録時のパス（symlink 経由のこともある）をそのまま返すので、文字列ではなく
  /// タブ占有の突き合わせと同じ正準形（`GitWorktreeRoot.normalizedPath`）で比べる。
  var currentWorktree: GitWorktree? {
    guard let root = repo?.root else { return nil }
    let key = GitWorktreeRoot.normalizedPath(root)
    return worktrees.first { GitWorktreeRoot.normalizedPath($0.path) == key }
  }

  /// 作成行の衝突の規則（作成先は作成経路と同じテンプレートと repo の場所で解く）。
  var newBranchRules: WorktreeNewBranchRules {
    WorktreeNewBranchRules(
      localBranches: localBranches.map(\.name), remoteBranches: remoteBranches.map(\.name),
      remoteBranchesLanded: remoteFetchLanded, worktreePaths: worktrees.map(\.path),
      template: worktreeTemplate, repoPath: worktreeBase)
  }
}
