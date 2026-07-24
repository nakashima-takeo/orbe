import Foundation

/// Dispatch の非同期オーケストレータ。git（local・即時）を先に描き、gh（ネット）を追従で差し替える
/// プログレッシブ表示を駆動し、Enter 実行の対象ディレクトリ解決（既存 worktree 再利用／新規作成）も担う。
/// section 組み立ては純粋な `DispatchSectionBuilder`、実データ取得は `GitRepo`/`GitHubCLI` に委ねる。
/// 全メソッドはメインスレッドで呼ばれ、`GitRepo`/`GitHubCLI` の completion もメインで返る（`GitRunner` 契約）。
final class DispatchDataProvider {
  private let cwd: String
  private weak var model: DispatchPaletteModel?
  /// 実行失敗メッセージ（palette 表示）を現在言語で出すためのストア（提示元＝WindowController が渡す）。
  private let localization: LocalizationStore
  /// worktree 作成先の実効パステンプレート（global＋WS 上書きを解決済み）。提示元が注入する。
  private let worktreePathTemplate: String

  private(set) var repo: GitRepo?
  private var mainWorktree: String?
  private var defaultBranchName = "main"

  private var worktrees: [GitWorktree] = []
  private var localBranches: [GitBranch] = []
  private var remoteBranches: [GitBranch] = []
  private var issues: [GitHubIssue] = []
  private var pullRequests: [GitHubPullRequest] = []
  private var githubState: GitHubAvailability = .ready
  private var issuesLoading = true
  private var pullRequestsLoading = true

  /// gh 取得の上限件数。
  private let ghLimit = 30

  init(
    cwd: String, model: DispatchPaletteModel, localization: LocalizationStore,
    worktreePathTemplate: String
  ) {
    self.cwd = cwd
    self.model = model
    self.localization = localization
    self.worktreePathTemplate = worktreePathTemplate
  }

  // MARK: - ロード

  func load() {
    GitRepo.open(cwd: cwd) { [weak self] repo in
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
  }

  /// 裏で fetch --prune し、成功したら Remote branches だけ最新化して差し替える（gh 追従と同じプログレッシブ表示）。
  /// 失敗時（remote 無し・ネットワーク不通・認証拒否等）は何もせず現状キャッシュ据え置き＝劣化なし。
  private func loadRemotePrune(_ repo: GitRepo) {
    repo.fetchPrune { [weak self] success in
      guard let self, success else { return }
      repo.remoteBranches { [weak self] branches in
        guard let self else { return }
        self.remoteBranches = branches
        self.rebuild()
      }
    }
  }

  private func loadGit(_ repo: GitRepo) {
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
    group.notify(queue: .main) { self.rebuild() }
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
      }
    }
  }

  /// 取得失敗（nil）は差し替えず据え置く。等値なら rebuild もしない（ちらつかない）。
  /// gh 着地の規則はこの 2 メソッドが持つ（テストが直接叩く唯一の入口）。
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

  private func rebuild() {
    guard let model else { return }
    let selectedAction = model.selectedItem?.action
    model.hasLoadedOnce = true
    model.sections = DispatchSectionBuilder.build(
      DispatchSectionBuilder.Input(
        worktrees: worktrees, localBranches: localBranches, remoteBranches: remoteBranches,
        issues: issues, pullRequests: pullRequests, githubState: githubState,
        issuesLoading: issuesLoading, pullRequestsLoading: pullRequestsLoading,
        currentWorktree: repo?.root))
    model.restoreSelection(matching: selectedAction)
  }

  // MARK: - 実行（対象ディレクトリの解決）

  /// 解決結果。`ready` は起動先パス、`failed` はエラーメッセージ（palette に表示）。
  enum DirectoryResolution {
    case ready(String)
    case failed(String)
  }

  /// 行種別に応じて対象ディレクトリを解決する（必要なら worktree を新規作成する）。
  /// 作成は追加のみ（現在の作業ツリーは不可侵）。失敗時は stderr をそのまま返す。
  func prepareDirectory(
    for action: DispatchAction, completion: @escaping (DirectoryResolution) -> Void
  ) {
    guard let repo else {
      completion(.failed(localization.string(.dispatchErrNotGitRepo)))
      return
    }
    switch action {
    case .worktree(let path):
      completion(.ready(path))

    case .localBranch(let name, let existing):
      if let existing {
        completion(.ready(existing))
        return
      }
      let path = worktreeDir(forBranch: name)
      repo.addWorktree(path: path, base: name, newBranch: nil, track: false) {
        completion($0 == nil ? .ready(path) : .failed($0!))
      }

    case .remoteBranch(let name, let existing):
      if let existing {
        completion(.ready(existing))
        return
      }
      let local = localName(fromRemote: name)
      let path = worktreeDir(forBranch: local)
      repo.addWorktree(path: path, base: name, newBranch: local, track: true) {
        completion($0 == nil ? .ready(path) : .failed($0!))
      }

    case .issue(let number, let existing, let branchExists):
      if let existing {
        completion(.ready(existing))
        return
      }
      let branch = "issue/\(number)"
      let path = worktreeDir(forBranch: branch)
      if branchExists {
        // 既存ブランチから worktree 追加（-b を外す）＝ git worktree add <path> issue/<n>。
        repo.addWorktree(path: path, base: branch, newBranch: nil, track: false) {
          completion($0 == nil ? .ready(path) : .failed($0!))
        }
      } else {
        // 新規: git worktree add -b issue/<n> <path> <default>。
        repo.addWorktree(path: path, base: defaultBranchName, newBranch: branch, track: false) {
          completion($0 == nil ? .ready(path) : .failed($0!))
        }
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
      let path = worktreeDir(forBranch: headRef)
      repo.addWorktree(path: path, base: "origin/\(headRef)", newBranch: headRef, track: true) {
        completion($0 == nil ? .ready(path) : .failed($0!))
      }
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

  /// 実効テンプレートをブランチ名で展開した worktree 作成先（絶対パス）。相対はリポジトリルート
  /// （`mainWorktree ?? repo.root`）基準で解決する。slug サニタイズは展開器が担う（唯一の真実を共有）。
  private func worktreeDir(forBranch branch: String) -> String {
    let repoRoot = mainWorktree ?? repo?.root ?? cwd
    return WorktreePathTemplate.expand(worktreePathTemplate, repoRoot: repoRoot, branch: branch)
  }

  private func localName(fromRemote name: String) -> String {
    let parts = name.split(separator: "/", maxSplits: 1)
    return parts.count == 2 ? String(parts[1]) : name
  }
}
