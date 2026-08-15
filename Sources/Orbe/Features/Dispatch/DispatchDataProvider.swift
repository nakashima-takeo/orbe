import Foundation

/// Dispatch の非同期オーケストレータ。git（local・即時）を先に描き、gh（ネット）を追従で差し替える
/// プログレッシブ表示を駆動し、Enter 実行の対象ディレクトリ解決（既存 worktree 再利用／新規作成）も担う。
/// section 組み立ては純粋な `DispatchSectionBuilder`、実データ取得は `GitRepo`/`GitHubCLI` に委ねる。
/// 全メソッドはメインスレッドで呼ばれ、`GitRepo`/`GitHubCLI` の completion もメインで返る（`GitRunner` 契約）。
final class DispatchDataProvider {
  private let cwd: String
  /// 分冊（`DispatchDataProvider+GitHub.swift`）も読む（gh 状態の反映）。
  private(set) weak var model: DispatchPaletteModel?
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
  /// 既定ブランチの ref。`git symbolic-ref --short refs/remotes/origin/HEAD` の出力なので
  /// `origin/main` という remote 追跡名で、取り込み判定の比較対象と新規 worktree の base に使う。
  /// 表示名（`origin/` 剥がし）は verdict を受けた分類器が導く。
  private var defaultBranchName = "main"

  /// 分冊（`DispatchDataProvider+Clean.swift` / `+GitHub.swift`）も読む。
  private(set) var worktrees: [GitWorktree] = []
  private var localBranches: [GitBranch] = []
  private var remoteBranches: [GitBranch] = []
  // gh レーンの状態。書き手は分冊（`DispatchDataProvider+GitHub.swift`）、読み手は `rebuild`。
  var issues: [GitHubIssue] = []
  var pullRequests: [GitHubPullRequest] = []
  var branchPullRequests: [GitHubBranchPR] = []
  /// probe の結果。`nil` = probe 未完。可用性を Optional で持つことで「まだ確かめていない」と
  /// 「確かめて取得可」を 1 つの値で区別する（両者を潰すと、確認前の状態が「gh 確認済み」を
  /// 名乗ってしまう）。
  var probedGitHubState: GitHubAvailability?
  /// 画面に出す可用性。probe 未完の間は `.ready` として振る舞う（確定前にセクションを畳まない）。
  var githubState: GitHubAvailability { probedGitHubState ?? .ready }
  /// ブランチの PR を実際に引ける状態か。取得は git レーン（worktree 一覧）と gh レーン（認証確認）の
  /// 両方が要り、probe 前に発火すると gh 不在の環境で worktree 本数ぶんの失敗プロセスを撒く。
  var githubReady: Bool { probedGitHubState == .ready }
  /// ブランチの PR を既に gh へ問うた対象ブランチ。同じ顔ぶれなら引き直さない——取得の入口は
  /// 複数の着地点から叩かれるので、ここが無いと 1 回開くたびに worktree 本数ぶんの往復が
  /// まるごと重複する。
  var requestedBranchPRHeads: [String]?
  var issuesLoading = true
  var pullRequestsLoading = true
  /// 分類レーンの実測結果（path → 実測）。nil の間は分類そのものが未着地。
  private var cleanProbes: [String: DispatchCleanProbe]?
  /// path → **発行時点**の取り込み判定の比較先リスト。`requestedBranchPRHeads` と同型の
  /// 「発行時点で記録する顔ぶれ dedup」——比較先が同じ行を引き直さず、gh 着地で base が判明した
  /// 行だけを引き直すための台帳。着地の照合（発行時の比較先 == 現台帳）にも使い、独立レーンの
  /// 順序不定で古い発行の遅着が新しい結果を上書きする窓を塞ぐ。
  private var issuedProbeTargets: [String: [String]]?

  /// gh 取得の上限件数（issues / open PR の一覧。分冊も読む）。
  let ghLimit = 30

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
        self.probedGitHubState = .notGitHub
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

  /// 裏で fetch --prune し、成功したら git レーンを丸ごと引き直す（gh 追従と同じプログレッシブ表示）。
  /// 失敗時は何もせず現状据え置き＝劣化なし。
  ///
  /// **分類まで取り直すのが要点**——取り込み判定は到達性（`rev-list --not --remotes`）も cherry も
  /// `refs/remotes/*` の鮮度に依存するので、fetch 前の分類は「GitHub でマージした直後」に必ず
  /// 未取り込みと出る（この機能の主用途がそのまま外れる）。`[gone]` の出どころである
  /// `localBranches` も prune で初めて確定する。clean 画面は
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
    // ブランチの PR も worktree 一覧が要る（名指しの取得）ので同じ着地点から叩く——削除で
    // worktree の顔ぶれが変われば対象も変わる。顔ぶれが同じ回は入口が畳むので、何度叩いても安い。
    group.notify(queue: .main) {
      self.rebuild()
      // git の事実（ref の中身）が動いた着地なので全行引き直す。
      self.startCleanProbe(repo, invalidateAll: true)
      self.loadBranchPullRequests(repo)
    }
  }

  /// 分類レーンを起動する。fetch 着地後にも同じ入口から取り直す（結果が同じなら rebuild しない）。
  ///
  /// `invalidateAll` が false のとき（gh 着地）は、**比較先の顔ぶれが変わった行だけ**を引き直す
  /// （merged PR の base が判明して `origin/<base>` が比較先に加わった行がこれに当たる）。
  /// 台帳（`issuedProbeTargets`)は**発行の時点で**更新する——着地を待って記録すると、その間に来た
  /// もう一方の着地点が同じ顔ぶれを二重に引く（`loadBranchPullRequests` と同じ理由）。
  ///
  /// 着地は path ごとに「発行時の比較先 == 現台帳」のときだけ `cleanProbes` へマージする。
  /// probe は独立レーン（concurrent）で順序保証が無く、全量発行と差分発行の遅着が交錯しうる——
  /// この照合が古い発行の遅着による上書きの窓を塞ぐ。台帳に無い path のエントリは落とす
  /// （削除済み worktree の残骸を持たない）。
  func startCleanProbe(_ repo: GitRepo, invalidateAll: Bool) {
    let extra = DispatchWorktreeClassifier.extraContainmentTargets(
      worktrees: worktrees, branchPullRequests: branchPullRequests,
      remoteBranchNames: Set(remoteBranches.map(\.name)), defaultBranch: defaultBranchName)
    let inputs = Dictionary(
      uniqueKeysWithValues: worktrees.map {
        ($0.path, [defaultBranchName] + (extra[$0.path] ?? []))
      })
    let stale =
      invalidateAll
      ? worktrees : worktrees.filter { inputs[$0.path] != issuedProbeTargets?[$0.path] }
    guard !stale.isEmpty else { return }
    if invalidateAll {
      issuedProbeTargets = inputs
    } else {
      var ledger = issuedProbeTargets ?? [:]
      for worktree in stale { ledger[worktree.path] = inputs[worktree.path] }
      issuedProbeTargets = ledger
    }
    let issued = inputs
    DispatchCleanProber(
      repo: repo, defaultBranch: defaultBranchName, extraContainmentTargets: extra
    )
    .probe(worktrees: stale, panes: paneOccupancies) { [weak self] probes in
      guard let self else { return }
      var merged = (self.cleanProbes ?? [:]).filter { self.issuedProbeTargets?[$0.key] != nil }
      for (path, probe) in probes where issued[path] == self.issuedProbeTargets?[path] {
        merged[path] = probe
      }
      guard self.cleanProbes != merged else { return }
      self.cleanProbes = merged
      self.rebuild()
    }
  }

  /// 手元の状態から model を組み直す（描画の唯一の出口）。gh 着地（分冊
  /// `DispatchDataProvider+GitHub.swift`）も同じ出口を通る。
  func rebuild() {
    guard let model else { return }
    let selectedAction = model.selectedItem?.action
    let rows = cleanProbes.map {
      DispatchWorktreeClassifier.rows(
        DispatchWorktreeClassifier.Input(
          worktrees: worktrees, localBranches: localBranches,
          branchPullRequests: branchPullRequests, probes: $0,
          panes: paneOccupancies))
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
