import Foundation

/// Dispatch の非同期オーケストレータ。git（local・即時）を先に描き、gh（ネット）を追従で差し替える
/// プログレッシブ表示を駆動し、Enter 実行の対象ディレクトリ解決（既存 worktree 再利用／新規作成）も担う。
/// section 組み立ては純粋な `DispatchSectionBuilder`、実データ取得は `GitRepo`/`GitHubCLI` に委ねる。
/// 全メソッドはメインスレッドで呼ばれ、`GitRepo`/`GitHubCLI` の completion もメインで返る（`GitRunner` 契約）。
final class DispatchDataProvider {
  private let cwd: String
  private weak var model: DispatchPaletteModel?
  /// 実行失敗メッセージ（palette 表示）を現在言語で出すためのストア（提示元＝WindowController が渡す）。
  /// 分冊（`DispatchDataProvider+Clean.swift`）も読む。
  let localization: LocalizationStore
  /// worktree 新規作成先のテンプレート（実効設定 `worktree-dir`）。パレットは開くたびに生成されるため、
  /// 提示元が開く時点の実効値を注入する＝常に最新値で解決する。
  private let worktreeTemplate: String
  /// 開いた時点のペイン占有スナップショット（`SessionStore` を Dispatch から見せないための値型）。
  private let paneOccupancies: [PaneOccupancy]
  private let runner: GitRunner

  private(set) var repo: GitRepo?
  private var mainWorktree: String?
  private var defaultBranchName = "main"

  /// 分冊（`DispatchDataProvider+Clean.swift`）も読む。
  private(set) var worktrees: [GitWorktree] = []
  private var localBranches: [GitBranch] = []
  private var remoteBranches: [GitBranch] = []
  private var issues: [GitHubIssue] = []
  private var pullRequests: [GitHubPullRequest] = []
  private var closedPullRequests: [GitHubClosedPR] = []
  private var githubState: GitHubAvailability = .ready
  private var issuesLoading = true
  private var pullRequestsLoading = true
  /// 分類レーンの実測結果（path → 実測）。nil の間は分類そのものが未着地。
  private var cleanProbes: [String: DispatchCleanProbe]?

  /// gh 取得の上限件数。
  private let ghLimit = 30

  init(
    cwd: String, model: DispatchPaletteModel, localization: LocalizationStore,
    worktreeTemplate: String, paneOccupancies: [PaneOccupancy] = [], runner: GitRunner = .shared
  ) {
    self.cwd = cwd
    self.model = model
    self.localization = localization
    self.worktreeTemplate = worktreeTemplate
    self.paneOccupancies = paneOccupancies
    self.runner = runner
  }

  // MARK: - ロード

  func load() {
    GitRepo.open(cwd: cwd, runner: runner) { [weak self] repo in
      guard let self else { return }
      guard let repo else {
        // 非 git: 全セクション空（Issues/PR も出さない）。
        self.githubState = .notGitHub
        self.issuesLoading = false
        self.pullRequestsLoading = false
        self.rebuild()
        return
      }
      self.repo = repo
      self.applyCachedGitHub(repo)
      self.loadGit(repo)
      self.loadGitHub(repo)
      self.loadRemotePrune(repo)
    }
  }

  /// 前回取得した gh 結果をリポジトリ（commonDir）単位で先に積む。最初の rebuild（git 着地時）に
  /// 既に issue/PR 行が載るので、2 回目以降はローディング行を経由せず前回の行が即出る。
  /// ここで rebuild は打たない（git 未着の中途半端なリストが一瞬描かれ、かえってちらつく）。
  /// 取得済みの側だけ載せる——片方が前回失敗していれば、そちらは loading のまま今回の取得を待つ。
  private func applyCachedGitHub(_ repo: GitRepo) {
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

  /// 裏で fetch --prune し、成功したら git レーンを丸ごと引き直す（gh 追従と同じプログレッシブ表示）。
  /// 失敗時は何もせず現状据え置き＝劣化なし。
  ///
  /// **分類まで取り直すのが要点**——取り込み済み判定は `origin/<default>` に `git cherry` を打つので、
  /// fetch 前の分類は「GitHub でマージした直後」に必ず未取り込みと出る（この機能の主用途がそのまま
  /// 外れる）。`[gone]` の出どころである `localBranches` も prune で初めて確定する。clean 画面は
  /// `enter(rows:)` で凍結済みなので、カーソルの下でリストが組み替わることはない。
  private func loadRemotePrune(_ repo: GitRepo) {
    repo.fetchPrune { [weak self] success in
      guard let self, success else { return }
      self.loadGit(repo)
    }
  }

  /// git レーンを引き直す。分冊（`DispatchDataProvider+Clean.swift`）が削除の完了時にも撃つ。
  func loadGit(_ repo: GitRepo) {
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
    group.notify(queue: .main) {
      self.rebuild()
      self.startCleanProbe(repo)
    }
  }

  /// 分類レーンを起動する。fetch 着地後にも同じ入口から取り直す（結果が同じなら rebuild しない）。
  private func startCleanProbe(_ repo: GitRepo) {
    DispatchCleanProber(repo: repo, defaultBranch: defaultBranchName)
      .probe(worktrees: worktrees, panes: paneOccupancies) { [weak self] probes in
        guard let self, self.cleanProbes != probes else { return }
        self.cleanProbes = probes
        self.rebuild()
      }
  }

  private func loadGitHub(_ repo: GitRepo) {
    repo.originIsGitHub { [weak self] isGitHub in
      guard let self else { return }
      GitHubCLI.shared.probe(cwd: repo.root, isGitHub: isGitHub) { [weak self] state in
        guard let self else { return }
        self.githubState = state
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
        // 閉じた PR（`closed` は MERGED も含む）。掃除の推定にだけ使う。
        GitHubCLI.shared.closedPullRequests(
          cwd: repo.root, limit: self.ghLimit
        ) { [weak self] fetched in
          if let fetched {
            DispatchGitHubCache.shared.setClosedPullRequests(fetched, for: repo.commonDir)
          }
          self?.applyFetchedClosedPullRequests(fetched)
        }
      }
    }
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

  private func rebuild() {
    guard let model else { return }
    let selectedAction = model.selectedItem?.action
    let rows = cleanProbes.map {
      DispatchWorktreeClassifier.rows(
        DispatchWorktreeClassifier.Input(
          worktrees: worktrees, localBranches: localBranches,
          closedPullRequests: closedPullRequests, openPullRequests: pullRequests, probes: $0,
          panes: paneOccupancies, defaultBranch: defaultBranchName))
    }
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

  // MARK: - 実行（対象ディレクトリの解決）

  /// 解決結果。`ready` は起動先パス、`failed` はエラーメッセージ（palette に表示）。
  enum DirectoryResolution {
    case ready(String)
    case failed(String)
  }

  /// 行種別に応じて対象ディレクトリを解決する（必要なら worktree を新規作成する）。
  /// 作成は追加のみ（現在の作業ツリーは不可侵）。失敗は Git 層の `GitFailure` を UI 言語へ写して返す。
  /// 既存ディレクトリを返すだけの経路はリポジトリを要さない——非 git（`repo == nil`）を畳むのは
  /// リポジトリが要る作成経路（`createWorktree`）の責務。
  func prepareDirectory(
    for action: DispatchAction, completion: @escaping (DirectoryResolution) -> Void
  ) {
    switch action {
    case .worktree(let path):
      completion(.ready(path))

    case .localBranch(let name, let existing):
      if let existing {
        completion(.ready(existing))
        return
      }
      createWorktree(
        at: worktreeDir(forSlug: slug(name)), base: name, newBranch: nil, track: false,
        completion: completion)

    case .remoteBranch(let name, let existing):
      if let existing {
        completion(.ready(existing))
        return
      }
      let local = localName(fromRemote: name)
      createWorktree(
        at: worktreeDir(forSlug: slug(local)), base: name, newBranch: local, track: true,
        completion: completion)

    case .issue(let number, let existing, let branchExists):
      if let existing {
        completion(.ready(existing))
        return
      }
      let branch = "issue/\(number)"
      let path = worktreeDir(forSlug: slug(branch))
      if branchExists {
        // 既存ブランチから worktree 追加（-b を外す）＝ git worktree add <path> issue/<n>。
        createWorktree(
          at: path, base: branch, newBranch: nil, track: false, completion: completion)
      } else {
        // 新規: git worktree add -b issue/<n> <path> <default>。
        createWorktree(
          at: path, base: defaultBranchName, newBranch: branch, track: false,
          completion: completion)
      }

    case .pullRequest(let number, let headRef, let isCrossRepo, let existing):
      if let existing {
        completion(.ready(existing))
        return
      }
      // fork（cross-repo）PR は head ref がローカルに無く、現 dir を破壊せず隔離 worktree に持ち込む
      // 汎用手段が無い。安全側に倒し、worktree 化はせず「ブラウザで開く」へ誘導する（残った前提の決着）。
      if isCrossRepo {
        completion(.failed(localization.format(.dispatchErrForkPR, number)))
        return
      }
      createWorktree(
        at: worktreeDir(forSlug: slug(headRef)), base: "origin/\(headRef)",
        newBranch: headRef, track: true, completion: completion)

    case .clean:
      // clean 行はディレクトリを持たない。決定は `DispatchPaletteModel.activate` がパレット内で畳むため
      // ここへは届かない——網羅 switch は、行種別が増えたときの分類漏れを検出する役だけを果たす。
      assertionFailure("clean 行は prepareDirectory を通らない")
    }
  }

  /// 解決済みパスへ worktree を作る。作成先が作業ツリー内に落ちるときだけ、**作成できた後で**共有
  /// exclude へ除外を冪等に入れる（プリセット由来かカスタム由来かを問わず、解決済みパスだけで判定する）。
  /// 除外の成否は作成に影響しない。
  private func createWorktree(
    at path: String, base: String, newBranch: String?, track: Bool,
    completion: @escaping (DirectoryResolution) -> Void
  ) {
    guard let repo else {
      completion(.failed(localization.string(.dispatchErrNotGitRepo)))
      return
    }
    // 除外の対象は作成の**前**に決める——作成後は親が実在してしまい、その親を容れ物として Orbe が
    // 作ったのか、ユーザーの既存ディレクトリなのかを判別できなくなる。
    let root = worktreeBase
    let entry = GitWorktreeExclude.entry(
      worktreePath: path, worktreeRoot: root,
      parentIsNew: !FileManager.default.fileExists(
        atPath: (path as NSString).deletingLastPathComponent))
    let localization = self.localization
    repo.addWorktree(path: path, base: base, newBranch: newBranch, track: track) { failure in
      if let failure {
        switch failure {
        case .timedOut: completion(.failed(localization.string(.gitTimedOut)))
        case .reason(let reason): completion(.failed(reason))
        }
        return
      }
      // 書くのは作成できたときだけ（失敗した作成の除外を残さない）。この時点では対象が実在するので
      // `check-ignore` の「既にユーザーが塞いでいるか」判定も正しく効く。
      repo.applyWorktreeExclude(entry, worktreeRoot: root) { completion(.ready(path)) }
    }
  }

  /// issue/PR／PR に紐づく worktree・branch をブラウザで開く（fire-and-forget）。
  /// `linkedPRNumber` を最優先で見ることで「PR に紐づく行は PR を開く」を構造化する。
  func openWeb(for item: DispatchItem) {
    guard let repo else { return }
    if let number = item.linkedPRNumber {
      GitHubCLI.shared.openPRWeb(number: number, cwd: repo.root)
      return
    }
    switch item.action {
    case .issue(let number, _, _):
      GitHubCLI.shared.openIssueWeb(number: number, cwd: repo.root)
    case .pullRequest(let number, _, _, _):
      GitHubCLI.shared.openPRWeb(number: number, cwd: repo.root)
    default:
      break
    }
  }

  // MARK: - パス導出

  /// テンプレート解決の base。`{repo_path}`/`{parent}`/`{repo}` の導出元であり、repo 内解決の判定
  /// （除外の自動化）が使う作業ツリー root でもある。
  private var worktreeBase: String { mainWorktree ?? repo?.root ?? cwd }

  /// 実効テンプレート（設定 `worktree-dir`）から作成先を解決する。置換・`~` 展開・standardize は
  /// `WorktreePathTemplate` に一本化する。
  private func worktreeDir(forSlug slug: String) -> String {
    WorktreePathTemplate.resolve(template: worktreeTemplate, repoPath: worktreeBase, slug: slug)
  }

  private func slug(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "-")
  }

  private func localName(fromRemote name: String) -> String {
    let parts = name.split(separator: "/", maxSplits: 1)
    return parts.count == 2 ? String(parts[1]) : name
  }
}
