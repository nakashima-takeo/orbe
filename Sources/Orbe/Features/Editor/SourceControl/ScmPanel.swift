import Foundation

/// ソース管理パネルの面ごとの状態——根のサービスの観測（status・git の状態）・件数・2 区分の行・グラフ・HEAD が push 済みか・
/// 区分の開閉・選択・パネルの中の焦点。worktree の事実（メッセージ・操作・失敗）は `SourceControl` が持ち、ここは見せ方と観測だけ。
///
/// 面が見えている間（`isLive`）は根のサービスを握って status を受け、件数（レールのバッジ）を出す。行の組み立て・グラフ・
/// HEAD の push 済みの読みは、パネルを出している間（`isShown`）だけ行う——レールの件数のためにパネルを開かせず、隠れた
/// パネルのために git を起こさない。行の組み立ては裏で（世代つきで）済ませ、main は結果を差し替えて列に行の版を渡すだけ
/// （→ `ScmRows`）。
@MainActor @Observable
final class ScmPanel {
  /// パネルの中の焦点の置き場。
  enum Area: Equatable {
    case message
    case list
  }

  /// 行の開き方。
  struct Opening: Equatable {
    let mode: EditorSession.OpenMode
    let focusesText: Bool

    /// シングルクリック・キーで行へ動いた: 仮で開き、焦点は列のまま。
    static let browse = Opening(mode: .preview, focusesText: false)
    /// ダブルクリック・Enter: 普通に開いて本文へ。
    static let commit = Opening(mode: .pinned, focusesText: true)
  }

  /// グラフを読む件数の刻み。
  static let graphPage = 50

  /// 根（正準形）。
  let root: String
  /// worktree の状態（メッセージ・操作・失敗）。
  let control: SourceControl
  /// レールの件数（ステージ済み＋変更の行。git 管理外・未取得は 0）。
  private(set) var count = 0
  /// git 管理下か（nil = まだ分からない）。
  private(set) var isManaged: Bool?
  /// 最後に受けた status のブランチ。
  private(set) var branch: GitStatus.Branch?
  private(set) var changes = ScmChanges.empty
  private(set) var layout = ScmLayout.empty
  /// 行の組が変わるたびに進む（列はこれを見て読み直す）。
  private(set) var rowsVersion = 0
  private(set) var graph: GitCommitGraph?
  /// 区分「ソース管理」（メッセージ欄・ボタン・失敗の文）が開いている。
  var isControlsOpen = true
  private(set) var collapsed: Set<ScmSection> = []
  private(set) var selection: ScmRowID?
  private(set) var focusedArea: Area?
  /// 焦点を入れる要求。当てた後に残すと、パネルが次に現れたときに古い要求が焦点を奪う。
  private(set) var focusRequest: Area?
  /// HEAD が push 済みか（nil = 分からない——読んでいる・読めない・今の HEAD と違うコミットを読んだ）。
  var isHeadPushed: Bool? {
    guard !headJob.isRunning, let headPush, headPush.commit == branch?.commit else { return nil }
    return headPush.isPushed
  }

  /// 行を開く（diff）。
  @ObservationIgnored var onOpenDiff: (EditorDiff.Key, Opening) -> Void = { _, _ in }
  /// ファイルを普通のタブで開く。
  @ObservationIgnored var onOpenFile: (URL) -> Void = { _ in }
  /// 破棄の確認を出す（確認が要らなければそのまま破棄する）。
  @ObservationIgnored var onDiscard: ([ScmChanges.File]) -> Void = { _ in }
  /// キーで行へ動いたときの開きの間引き。
  @ObservationIgnored let navigation = RowNavigationThrottle()
  @ObservationIgnored private var files: RootFiles?
  @ObservationIgnored private var buildGeneration = 0
  @ObservationIgnored private var graphLimit = ScmPanel.graphPage
  @ObservationIgnored private var graphJob = Job()
  @ObservationIgnored private var headJob = Job()
  @ObservationIgnored private var headPush: (commit: String, isPushed: Bool)?
  /// パネルを出したときに根のサービスがまだ git 管理下と分かっていなかった（最初の status で読む）。
  @ObservationIgnored private var readsOnResolve = false

  /// 読み 1 本の直列化。実行中に来た要求は「終わったらもう 1 回」に畳む。
  private struct Job {
    var isRunning = false
    var again = false
  }

  /// 面が見えている間 true。立てると根のサービスを握って status を受け、下ろすと離す（行と件数は保つ）。
  @ObservationIgnored var isLive = false {
    didSet {
      guard isLive != oldValue else { return }
      if isLive {
        let files = RootFiles.shared(for: root)
        self.files = files
        files.addObserver(self)
        resolveManaged()
        statusDidChange()
        if isShown { readGraphAndHead() }
      } else {
        files?.removeObserver(self)
        files = nil
      }
    }
  }

  /// パネルを出している間 true。出したら行を組み、グラフと HEAD の push 済みを読む。
  @ObservationIgnored var isShown = false {
    didSet {
      guard isShown != oldValue else { return }
      if isShown {
        resolveManaged()
        statusDidChange()
        readGraphAndHead()
      } else {
        panelDidHide()
      }
    }
  }

  init(root: String) {
    self.root = root
    control = SourceControl.shared(for: root)
    control.addObserver(self)
    navigation.open = { [weak self] in self?.openSelection(.browse) }
  }

  /// コミットボタンと ▾ の姿。
  var commitState: ScmCommitState {
    ScmCommitState(
      staged: changes.staged.count, changes: changes.changes.count, branch: branch,
      messageIsBlank: control.message.allSatisfy(\.isWhitespace),
      isNetworking: control.isNetworking, isCommitting: control.isCommitting,
      isHeadPushed: isHeadPushed)
  }

  // MARK: - 観測

  private func resolveManaged() {
    guard let files else { return }
    if files.repo != nil {
      isManaged = true
    } else if files.isResolved {
      isManaged = false
    }
  }

  /// status が変わった（か読み直す）。件数は常に、行はパネルを出している間だけ裏で作る。
  private func statusDidChange() {
    guard let status = files?.status else { return }
    isManaged = true
    branch = status.branch
    if readsOnResolve {
      readsOnResolve = false
      readGraphAndHead()
    }
    buildGeneration += 1
    let generation = buildGeneration
    let rows = isShown
    let branch = ScmBranch(status.branch)
    let graph = self.graph
    let collapsed = self.collapsed
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard rows else {
        let count = ScmChanges.count(status)
        return Self.deliver { self?.apply(generation, count: count, changes: nil, layout: nil) }
      }
      let changes = ScmChanges.build(status)
      let layout = ScmLayout.build(changes, branch: branch, graph: graph, collapsed: collapsed)
      Self.deliver {
        self?.apply(generation, count: changes.count, changes: changes, layout: layout)
      }
    }
  }

  /// グラフ・開閉が変わった。持っている 2 区分から行の組だけを作り直す。
  private func rebuildLayout() {
    guard isShown else { return }
    buildGeneration += 1
    let generation = buildGeneration
    let changes = self.changes
    let branch = ScmBranch(self.branch)
    let graph = self.graph
    let collapsed = self.collapsed
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let layout = ScmLayout.build(changes, branch: branch, graph: graph, collapsed: collapsed)
      Self.deliver {
        self?.apply(generation, count: changes.count, changes: changes, layout: layout)
      }
    }
  }

  /// 裏の結果を main へ返す。
  private nonisolated static func deliver(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
  }

  /// 裏の結果を差し替える（古い世代は捨てる）。選んでいた行が消えたら、同じ区分のその位置の行（無ければ前の行）を選ぶ
  /// （開かない）。置き換えた行の組は裏で手放す（数万行の解放を main に載せない）。
  private func apply(_ generation: Int, count: Int, changes: ScmChanges?, layout: ScmLayout?) {
    guard generation == buildGeneration else { return }
    self.count = count
    guard let changes, let layout else { return }
    let replaced = (self.changes, self.layout)
    let previous = self.layout
    self.changes = changes
    self.layout = layout
    reselect(from: previous)
    rowsVersion &+= 1
    DispatchQueue.global(qos: .utility).async { withExtendedLifetime(replaced) {} }
  }

  private func reselect(from previous: ScmLayout) {
    guard let selection, layout.index[selection] == nil else { return }
    guard selection.path != nil, let old = previous.index[selection],
      let oldRange = previous.fileRanges[selection.section],
      let range = layout.fileRanges[selection.section], !range.isEmpty
    else {
      self.selection =
        layout.index[ScmRowID(section: selection.section, path: nil)] != nil
          && collapsed.contains(selection.section)
        ? ScmRowID(section: selection.section, path: nil) : nil
      return
    }
    let offset = min(old - oldRange.lowerBound, range.count - 1)
    self.selection = layout.id(at: range.lowerBound + offset)
  }

  // MARK: - グラフと HEAD

  /// グラフと HEAD の push 済みを読み直す（パネルを出している間だけ）。
  func readGraphAndHead() {
    guard isShown else { return }
    guard files?.repo != nil else {
      readsOnResolve = true
      return
    }
    readGraph()
    readHead()
  }

  /// グラフをいつも先頭から今の件数で読む（続きを継ぎ足さない——読みの間に HEAD が動くと重複・欠落する）。読めなければ
  /// 前の結果を保つ。
  private func readGraph() {
    guard isShown, let repo = files?.repo else { return }
    if graphJob.isRunning {
      graphJob.again = true
      return
    }
    graphJob.isRunning = true
    repo.commitGraph(limit: graphLimit) { [weak self] graph in
      guard let self else { return }
      graphJob.isRunning = false
      if let graph, graph != self.graph {
        self.graph = graph
        rebuildLayout()
      }
      if graphJob.again {
        graphJob.again = false
        readGraph()
      }
    }
  }

  /// HEAD 1 件をグラフの口で読み、push 済みか（どれかの remote 追跡ブランチから届くか）を読んだコミットと組で持つ。グラフの
  /// 50 件に HEAD が入る保証は無い（upstream が先に進んでいると上位を upstream が占める）ので、グラフの結果から拾わない。
  private func readHead() {
    guard isShown, let repo = files?.repo else { return }
    if headJob.isRunning {
      headJob.again = true
      return
    }
    headJob.isRunning = true
    repo.commitGraph(refs: ["HEAD"], limit: 1) { [weak self] graph in
      guard let self else { return }
      headJob.isRunning = false
      headPush = graph?.commits.first.map { ($0.oid, $0.isPushed) }
      if headJob.again {
        headJob.again = false
        readHead()
      }
    }
  }

  /// 「さらに表示」: 件数を増やして頭から読み直す。
  func showMoreCommits() {
    graphLimit += Self.graphPage
    readGraph()
  }

  /// 再読込: status を取り直し、グラフを読み直す。
  func refresh() {
    files?.requestStatusRefresh()
    readGraphAndHead()
  }

  // MARK: - 開閉

  func isOpen(_ section: ScmSection) -> Bool { !collapsed.contains(section) }

  func toggle(_ section: ScmSection) {
    if collapsed.remove(section) == nil { collapsed.insert(section) }
    rebuildLayout()
  }

  /// 行を選ぶ（nil で外す）。選択は行の同一性（区分・パス）で持ち、status の変化で行がずれても同じ行を指す。
  func select(_ id: ScmRowID?) {
    selection = id
  }

  // MARK: - 焦点

  func requestFocus(_ area: Area) {
    focusRequest = area
  }

  func focusRequestDidApply() {
    focusRequest = nil
  }

  /// 欄か列の焦点が入った・抜けた（抜けたほうが今の置き場のときだけ消す）。列から抜けたら待っている開きを捨てる。
  func focusDidChange(_ area: Area, focused: Bool) {
    if area == .list, !focused { navigation.drop() }
    if focused {
      focusedArea = area
    } else if focusedArea == area {
      focusedArea = nil
    }
  }

  /// パネルが隠れた（隠れた view は焦点が抜けたことを知らせない）。
  func panelDidHide() {
    navigation.drop()
    focusedArea = nil
  }
}

extension ScmPanel: RootFilesObserver {
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    resolveManaged()
  }

  func rootFilesStatusDidChange(_ files: RootFiles) {
    statusDidChange()
  }

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {}

  func rootFilesGitStateDidChange(_ files: RootFiles) {
    readGraphAndHead()
  }
}

extension ScmPanel: SourceControlObserver {
  func sourceControlOperationDidFinish(_ control: SourceControl) {
    readGraphAndHead()
  }
}
