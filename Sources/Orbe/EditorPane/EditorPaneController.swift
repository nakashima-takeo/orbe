import AppKit
import Foundation

/// EditorPane の指揮者。フォーカス中ペインの cwd からチェックアウトを解決して追従し、
/// UI 状態はタブが所有する `EditorPaneUIState` を retarget で束ねる（repo キャッシュとは分離）。
/// git 操作（stage/unstage/commit/discard）と読み取り（snapshot・ls-files・log）の唯一の入口。
final class EditorPaneController: EditorPaneActions {
  let pane: EditorPane

  /// repo-root キーで持つ repo 由来キャッシュ（UI 状態は持たない＝タブが所有する）。
  fileprivate final class RepoContext {
    let repo: GitRepo
    var watcher: RepoWatcher?
    var snapshot: GitRepo.Snapshot?
    var treeNodes: [FileTreeNode] = []
    var commits: [Commit] = []
    var unpushed: Set<String> = []
    var historyExhausted = false
    var loadingHistory = false

    init(repo: GitRepo) {
      self.repo = repo
    }
  }

  private var contexts: [String: RepoContext] = [:]
  /// 表示中リポジトリの root（追従・dev サーバー検出の軸。+Browser も参照する）。
  var currentRoot: String?
  private var lastCwd: String?
  /// 非同期の root 解決が交錯したとき、最後の retarget だけを勝たせる。
  private var retargetGeneration = 0
  /// 履歴の初回ロード件数（追加読み込みは同じ幅で伸ばす）。
  private static let logPage = 50

  // 埋め込みブラウザの状態（操作・検出は EditorPaneController+Browser が触る）。
  /// dev サーバー検出の定期ポーリング（表示中のみ・3 秒間隔）。
  var devServerTimer: Timer?
  /// WKWebView のライブ状態を model へ写す KVO（初回ブラウザ利用時に一度だけ張る）。
  var browserObservers: [NSKeyValueObservation] = []
  /// 現在 WKWebView に load 済みの URL（同一 URL の再 load を避ける）。
  var browserLoadedURL: URL?

  /// ペインを閉じる・Esc でターミナルへフォーカスを返すときに呼ぶ。
  var onFocusTerminal: (() -> Void)?
  /// facade の可視（repo 解決）・本体開閉が変わった通知（AppShell 幅・可視の投影用）。
  var onDisplayStateChange: (() -> Void)?
  /// 永続対象（本体開閉・ツール）が変わった通知（保存スケジュール用）。
  var onPersistChange: (() -> Void)?

  var model: EditorPaneModel { pane.model }

  /// 現在言語（`empty` 空状態・コミット結果バナー等、controller が組む文言用）。
  private let localization: LocalizationStore

  /// facade（レール）を出すか＝repo を解決できたか。非 git・cwd 不明では隠す。
  /// `empty` はロード中（commonLoading）にも非 nil になり投影が過渡状態を掴むため、
  /// root 解決の有無（retarget で notify 前に確定）を真実にする。
  var facadeVisible: Bool { currentRoot != nil }
  /// アクティブタブの本体パネルが開いているか（＝facade 幅が本体分を含むか）。
  var paneOpen: Bool { model.ui.paneOpen }

  init(
    translucency: ChromeTranslucency, fontResolver: ChromeFontResolver,
    localization: LocalizationStore
  ) {
    self.localization = localization
    pane = EditorPane(
      translucency: translucency, fontResolver: fontResolver, localization: localization)
    pane.actions = self
    pane.model.onToolStateChange = { [weak self] in
      self?.onDisplayStateChange?()
      self?.onPersistChange?()
    }
  }

  /// 常駐化に伴い、起動時に一度だけ dev サーバー検出のポーリングを起こす（ブラウザボタンのグレーアウト追従）。
  func start() {
    startDevServerPolling()
  }

  // MARK: - 追従

  /// フォーカス中ペインの cwd（フォーカス移動・cd・タブ/workspace 切替）と、そのタブが所有する
  /// UI 状態を束ね直す。cwd 同一でもタブが変われば（同じ repo を別タブで開く）UI を張り替える。
  func retarget(cwd: String?, ui: EditorPaneUIState?) {
    let uiChanged = ui != nil && ui !== model.ui
    if let ui, uiChanged { model.ui = ui }
    lastCwd = cwd
    retargetGeneration += 1
    let generation = retargetGeneration
    guard let cwd else {
      currentRoot = nil
      model.empty = localization.string(.editorEmptyNoCwd)
      notifyDisplayState()
      return
    }
    GitRepo.open(cwd: cwd) { [weak self] repo in
      guard let self, generation == self.retargetGeneration else { return }
      guard let repo else {
        self.currentRoot = nil
        self.model.empty = self.localization.format(.editorEmptyNotGit, cwd)
        self.notifyDisplayState()
        return
      }
      let sameRepo = repo.root == self.currentRoot
      self.currentRoot = repo.root
      let context = self.context(for: repo)
      if !sameRepo {
        // 切替直後はキャッシュを即描画し、裏で最新へ更新する（チラつき防止）。
        if context.snapshot != nil {
          self.apply(context)
        } else {
          self.model.empty = self.localization.string(.commonLoading)
        }
        self.refresh()
        // プロジェクト切替: 新しい root で dev サーバーを即検出し、同一 URL でも再 load して取り直す。
        self.probeDevServer(rootChanged: true)
      } else if uiChanged, context.snapshot != nil {
        // 同じ repo を別タブで開いた: キャッシュ済みデータを新しいタブ UI で描き直す。
        self.apply(context)
      }
      self.notifyDisplayState()
    }
  }

  /// 本体パネルの開閉トグル（`Cmd+/`）。repo 未解決（empty）なら no-op。閉じたらターミナルへ返す。
  func togglePaneOpen() {
    guard model.empty == nil else { return }
    model.ui.paneOpen.toggle()
    notifyDisplayState()
    onPersistChange?()
    if !model.ui.paneOpen { onFocusTerminal?() }
  }

  /// facade 可視・本体開閉の現状を上位（AppShell 投影）へ知らせる。
  private func notifyDisplayState() {
    onDisplayStateChange?()
  }

  private func context(for repo: GitRepo) -> RepoContext {
    if let existing = contexts[repo.root] { return existing }
    let context = RepoContext(repo: repo)
    context.watcher = RepoWatcher(
      roots: [repo.root, repo.gitDir, repo.commonDir],
      gitDirs: [repo.gitDir, repo.commonDir]
    ) { [weak self] in
      // 変化はどの repo でも起きるが、描画し直すのは表示中の repo のみ。
      guard let self, self.currentRoot == repo.root else { return }
      self.refresh()
    }
    contexts[repo.root] = context
    return context
  }

  /// 表示中リポジトリの状態（status・両 diff・ツリー・履歴・未push）を取り直して描画する。
  func refresh() {
    guard let root = currentRoot, let context = contexts[root] else { return }
    let repo = context.repo
    let group = DispatchGroup()
    var snapshot: GitRepo.Snapshot?
    var paths: [String]?
    var unpushed: Set<String> = []
    var commits: [Commit] = []
    let limit = max(Self.logPage, context.commits.count)

    group.enter()
    repo.snapshot {
      snapshot = $0
      group.leave()
    }
    group.enter()
    repo.lsFiles {
      paths = $0
      group.leave()
    }
    group.enter()
    repo.unpushedOids {
      unpushed = $0
      group.leave()
    }
    group.enter()
    repo.log(limit: limit) {
      commits = $0
      group.leave()
    }

    group.notify(queue: .main) { [weak self] in
      guard let self, self.currentRoot == root else { return }
      guard let snapshot else {
        self.model.empty = self.localization.string(.editorEmptyStatusFailed)
        return
      }
      context.snapshot = snapshot
      context.treeNodes = FileTree.build(paths: paths ?? [])
      context.unpushed = unpushed
      context.commits = commits
      context.historyExhausted = commits.count < limit
      self.apply(context)
    }
  }

  /// context のキャッシュを model へ投影する（表示の唯一の書き込み点）。
  private func apply(_ context: RepoContext) {
    guard let snapshot = context.snapshot else { return }
    let status = snapshot.status
    model.empty = nil
    model.branch =
      status.branch ?? status.oid.map { "detached @ \(String($0.prefix(7)))" } ?? "(no commits)"
    model.upstream = status.upstream
    model.ahead = status.ahead
    model.behind = status.behind
    model.files = status.files
    model.unstagedDiffs = snapshot.unstaged
    model.stagedDiffs = snapshot.staged
    model.treeNodes = context.treeNodes
    model.commits = context.commits
    model.unpushedOids = context.unpushed
    model.historyExhausted = context.historyExhausted
    model.readFile = { [repo = context.repo] path in repo.readWorktreeFile(path: path) }
    model.makeUntrackedDiff = { [repo = context.repo] path in repo.untrackedFileDiff(path: path) }
    model.invalidateContentCache()
    // 選択コミットの詳細が別 repo・別 oid の残骸なら読み直す。
    if case .commit(let oid) = model.resolvedHistorySelection,
      model.commitDetail?.commit.oid != oid
    {
      loadCommitDetail(oid: oid)
    }
  }

  fileprivate var current: (repo: GitRepo, context: RepoContext)? {
    guard let root = currentRoot, let context = contexts[root] else { return nil }
    return (context.repo, context)
  }

  /// 操作完了の共通後処理: エラーは最小表示し、成功なら即リフレッシュ
  /// （watcher にも届くが、操作直後の体感を待たせない）。
  fileprivate func finish(_ error: String?) {
    if let error, !error.isEmpty {
      model.banner = .error(error.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
      model.banner = nil
      refresh()
    }
  }

  // MARK: - EditorPaneActions（履歴・その他）

  func loadMoreHistory() {
    guard let (repo, context) = current,
      !context.historyExhausted, !context.loadingHistory
    else { return }
    context.loadingHistory = true
    let skip = context.commits.count
    repo.log(limit: Self.logPage, skip: skip) { [weak self] commits in
      guard let self else { return }
      context.loadingHistory = false
      context.commits.append(contentsOf: commits)
      context.historyExhausted = commits.count < Self.logPage
      guard self.currentRoot == context.repo.root else { return }
      self.model.commits = context.commits
      self.model.historyExhausted = context.historyExhausted
    }
  }

  func selectHistory(_ selection: HistorySelection) {
    guard current != nil else { return }
    model.ui.selectedCommit = selection
    if case .commit(let oid) = selection, model.commitDetail?.commit.oid != oid {
      loadCommitDetail(oid: oid)
    }
  }

  private func loadCommitDetail(oid: String) {
    guard let (repo, context) = current,
      let commit = context.commits.first(where: { $0.oid == oid })
    else { return }
    repo.commitDiff(oid: oid) { [weak self] diffs in
      guard let self, self.currentRoot == repo.root else { return }
      self.model.commitDetail = CommitDetailData(commit: commit, files: diffs)
    }
  }

  func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  func focusTerminal() {
    onFocusTerminal?()
  }
}

// MARK: - EditorPaneActions（stage / unstage / discard / commit）

extension EditorPaneController {
  func stageFile(_ change: FileChange) {
    guard let (repo, _) = current, !change.isConflicted else { return }
    repo.stageFiles([change.path]) { [weak self] in self?.finish($0) }
  }

  func unstageFile(_ change: FileChange) {
    guard let (repo, _) = current else { return }
    repo.unstageFiles([change.path] + (change.oldPath.map { [$0] } ?? [])) { [weak self] in
      self?.finish($0)
    }
  }

  func stageFiles(_ changes: [FileChange]) {
    guard let (repo, _) = current else { return }
    let paths = changes.filter { !$0.isConflicted }.map { $0.path }
    guard !paths.isEmpty else { return }
    repo.stageFiles(paths) { [weak self] in self?.finish($0) }
  }

  func unstageFiles(_ changes: [FileChange]) {
    guard let (repo, _) = current else { return }
    // rename は現パスと oldPath の両方を index から戻す（unstageFile と同じ挙動）。
    let paths = changes.filter { !$0.isConflicted }
      .flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
    guard !paths.isEmpty else { return }
    repo.unstageFiles(paths) { [weak self] in self?.finish($0) }
  }

  func discardFiles(_ changes: [FileChange]) {
    guard let (repo, _) = current else { return }
    var tracked: [String] = []
    var untracked: [String] = []
    for change in changes where !change.isConflicted {
      if change.unstaged == .untracked {
        untracked.append(change.path)
      } else {
        tracked.append(change.path)
      }
    }
    guard !tracked.isEmpty || !untracked.isEmpty else { return }
    repo.discardFiles(tracked: tracked, untracked: untracked) { [weak self] in self?.finish($0) }
  }

  /// hunk の全変更行を選択した再構成パッチで stage する（既存 PatchBuilder の行機構を hunk 全行として使う）。
  func stageHunk(path: String, diff: FileDiff, hunkIndex: Int, untracked: Bool) {
    guard let (repo, _) = current,
      let patch = PatchBuilder.build(
        diff: diff, selection: Self.hunkSelection(diff, hunkIndex), direction: .stage)
    else { return }
    if untracked {
      // 内容を載せず index に席だけ作ると、新規ファイルのパッチが適用可能になる。
      repo.intentToAdd([path]) { [weak self] error in
        if let error {
          self?.finish(error)
          return
        }
        repo.applyToIndex(patch: patch, reverse: false) { self?.finish($0) }
      }
    } else {
      repo.applyToIndex(patch: patch, reverse: false) { [weak self] in self?.finish($0) }
    }
  }

  func unstageHunk(path: String, diff: FileDiff, hunkIndex: Int) {
    guard let (repo, _) = current,
      let patch = PatchBuilder.build(
        diff: diff, selection: Self.hunkSelection(diff, hunkIndex), direction: .unstage)
    else { return }
    repo.applyToIndex(patch: patch, reverse: true) { [weak self] in self?.finish($0) }
  }

  private static func hunkSelection(_ diff: FileDiff, _ hunkIndex: Int) -> Set<LineRef> {
    guard diff.hunks.indices.contains(hunkIndex) else { return [] }
    return Set(
      diff.hunks[hunkIndex].lines.enumerated()
        .filter { $0.element.kind != .context }
        .map { LineRef(hunkIndex, $0.offset) })
  }

  func commit(message: String) {
    guard let (repo, _) = current else { return }
    model.committing = true
    repo.commit(message: message) { [weak self] success, output in
      guard let self else { return }
      self.model.committing = false
      if success {
        self.model.ui.commitDraft = ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model.banner = .success(
          trimmed.isEmpty ? self.localization.string(.commitSucceeded) : trimmed)
        self.refresh()
      } else {
        self.model.banner = .error(
          output.isEmpty ? self.localization.string(.commitFailed) : output)
      }
    }
  }
}
