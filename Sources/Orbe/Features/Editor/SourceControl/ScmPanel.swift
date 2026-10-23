import Foundation

/// ソース管理パネルの面ごとの状態——根のサービスの観測（status・git の状態）・件数・2 区分の行・グラフ・HEAD が push 済みか・
/// 親「ソース管理」・子の区分・グラフの枠の開閉・選択・パネルの中の焦点。worktree の事実（メッセージ・操作・失敗）は
/// `SourceControl` が持ち、ここは見せ方と観測だけ。
///
/// 面が見えている間（`isLive`）は根のサービスを握って status を受け、件数（レールのバッジ）を出す。行の組み立て・グラフ・
/// HEAD の push 済みの読みは、パネルを出している間（`isShown`）だけ行う——レールの件数のためにパネルを開かせず、隠れた
/// パネルのために git を起こさない。変更の列の行の組み立ては裏で 1 本ずつ済ませ、main は結果を差し替えて列に行の版を渡す
/// だけ。グラフの列の行は高々数百行なので main で作る（→ `ScmRows`）。
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
  /// 今の行と件数を作った status のブランチ。
  private(set) var branch: GitStatus.Branch?
  private(set) var changes = ScmChanges.empty
  private(set) var layout = ScmLayout.empty
  /// 変更の列の行の組が変わるたびに進む（列はこれを見て読み直す）。
  private(set) var rowsVersion = 0
  private(set) var graph: GitCommitGraph?
  private(set) var graphLayout = ScmGraphLayout.empty
  /// グラフの列の行の組が変わるたびに進む。
  private(set) var graphRowsVersion = 0
  /// 親「ソース管理」（メッセージ欄・ボタン・失敗の文と 2 つの子の区分）が開いている。変えるのは `setRepositoryOpen` だけ。
  private(set) var isRepositoryOpen = true
  /// グラフの枠が開いている。
  var isGraphOpen = true
  private(set) var collapsed: Set<ScmSection> = []
  private(set) var selection: ScmRowID?
  private(set) var focusedArea: Area?
  /// 焦点を入れる要求。当てた後に残すと、パネルが次に現れたときに古い要求が焦点を奪う。
  private(set) var focusRequest: Area?
  /// HEAD が push 済みか（nil = 分からない——remote 追跡 ref が動きうるきっかけの後で読み直している・読めない・今の HEAD と
  /// 違うコミットを読んだ）。push 済みは HEAD のコミットと remote 追跡 ref だけで決まるので、それ以外（HEAD・ローカルの
  /// ブランチ・index の変化、ステージ等の終わり）の読み直しの間は、同じ HEAD なら前の値を使う。HEAD が動けば、コミットの
  /// 違いで分からないになる。
  var isHeadPushed: Bool? {
    guard !headPushIsStale, let headPush, headPush.commit == branch?.commit else { return nil }
    return headPush.isPushed
  }

  /// 行を開く（diff）。
  @ObservationIgnored var onOpenDiff: (EditorDiff.Key, Opening) -> Void = { _, _ in }
  /// ファイルを普通のタブで開く。
  @ObservationIgnored var onOpenFile: (URL) -> Void = { _ in }
  /// 破棄の確認を出す（確認が要らなければそのまま破棄する）。
  @ObservationIgnored var onDiscard: ([ScmChanges.File]) -> Void = { _ in }
  /// 親を畳む直前（欄と列がまだ窓に居るうち）。焦点がパネルの中にあれば、面の本文へ移す。
  @ObservationIgnored var onRepositoryWillClose: () -> Void = {}
  /// 面の workspace の実効設定で、裏の fetch がオンか（使う時点で読む）。
  @ObservationIgnored var autoFetchEnabled: () -> Bool = { true }
  /// キーで行へ動いたときの開きの間引き。
  @ObservationIgnored let navigation = RowNavigationThrottle()
  /// 握っている根のサービス（面が見えている間だけ）。
  @ObservationIgnored private(set) var liveFiles: RootFiles?
  /// 欲しいと届けている裏の fetch の係。
  @ObservationIgnored private(set) var autoFetch: ScmAutoFetch?
  @ObservationIgnored private var buildJob = Job()
  @ObservationIgnored var ownWrites = ScmOwnWrites()
  /// 手元の 2 区分が今の status から作ったものでない（status が届いてから、行を作る組み立てがまだ始まっていない）。
  @ObservationIgnored private var changesAreStale = true
  @ObservationIgnored private var graphLimit = ScmPanel.graphPage
  @ObservationIgnored private var graphJob = Job()
  @ObservationIgnored private var headJob = Job()
  private var headPush: (commit: String, isPushed: Bool)?
  /// remote 追跡 ref が動きうるきっかけの後、その後に始めた読みが終わるまで（前の値を有効なまま残すと、自分の push の
  /// 直後に amend・取り消しが押せる）。
  private var headPushIsStale = false
  /// パネルを出したときに根のサービスがまだ git 管理下と分かっていなかった（最初の status で読む）。
  @ObservationIgnored private var readsOnResolve = false

  /// 読み・組み立て 1 本の直列化。実行中に来た要求は「終わったらもう 1 回」に畳む。
  private struct Job {
    var isRunning = false
    var again = false
  }

  /// 面が見えている間 true。立てると根のサービスを握って status を受け、下ろすと離す（行と件数は保つ）。裏の fetch を
  /// 欲しがるのも、この間だけ。
  @ObservationIgnored var isLive = false {
    didSet {
      guard isLive != oldValue else { return }
      if isLive {
        let files = RootFiles.shared(for: root)
        liveFiles = files
        files.addObserver(self)
        resolveManaged()
        statusDidChange()
        if isShown { readGraphAndHead(remoteRefsMayHaveMoved: true) }
      } else {
        liveFiles?.removeObserver(self)
        liveFiles = nil
        decideAutoFetch()
      }
    }
  }

  /// パネルを出している間 true。出したら行を組み、グラフと HEAD の push 済みを読む。
  @ObservationIgnored var isShown = false {
    didSet {
      guard isShown != oldValue else { return }
      if isShown {
        resolveManaged()
        requestBuild()
        readGraphAndHead(remoteRefsMayHaveMoved: true)
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

  // MARK: - 観測

  /// 根のサービスが git 管理下かを読む。管理下なら裏の fetch を欲しがるか決め直す——根のサービスから何か届くたびに呼ぶので、
  /// status の取り直しが落ち続けていても、根の git dir が分かった後の知らせで決まる。
  func resolveManaged() {
    guard let files = liveFiles else { return }
    if files.repo != nil {
      isManaged = true
      decideAutoFetch()
    } else if files.isResolved {
      isManaged = false
    }
  }

  /// 裏の fetch を欲しがるか決め直し、そのリポジトリの係へ届ける。欲しがるのは、面が見えていて（ソース管理パネルを出して
  /// いるかに依らない）、根の git dir が分かり、面の workspace の設定がオンの間。
  func decideAutoFetch() {
    let next = liveFiles?.repo.map(ScmAutoFetch.shared(for:))
    if let autoFetch, autoFetch !== next { autoFetch.setWanted(false, by: self) }
    autoFetch = next
    next?.setWanted(autoFetchEnabled(), by: self)
  }

  /// status が届いた（か、握り直した根のサービスの status を読む）。
  func statusDidChange() {
    guard liveFiles?.status != nil else { return }
    ownWrites.statusDidArrive()
    resolveManaged()
    if readsOnResolve {
      readsOnResolve = false
      readGraphAndHead(remoteRefsMayHaveMoved: true)
    }
    changesAreStale = true
    requestBuild()
  }

  /// 件数と、パネルを出していれば変更の列の行の組を、今の入力（status・開閉）から裏で作り直す。組み立ては 1 本ずつで、
  /// 走っている間の要求は「終わったらもう 1 回」に畳む——どの組み立ても始めた時点の最新の入力から作るので、届いた結果は
  /// 捨てずに当てられ、最後に当たるのはいつも最新の入力から作った組になる。2 区分は status が変わったときだけ作り直し、
  /// 開閉だけが変わったら手元の 2 区分を使う（直列なので、手元の 2 区分は前の組み立てが当てた最新のもの）。
  private func requestBuild() {
    if buildJob.isRunning {
      buildJob.again = true
      return
    }
    build()
  }

  private func build() {
    guard let status = liveFiles?.status else { return }
    buildJob.isRunning = true
    let rows = isShown
    let built = rows && !changesAreStale ? changes : nil
    let builtFrom = built == nil ? ownWrites.statusNumber : ownWrites.rowsNumber
    if rows { changesAreStale = false }
    let branch = status.branch
    let collapsed = self.collapsed
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard rows else {
        let count = ScmChanges.count(status)
        return Self.deliver {
          self?.apply(branch: branch, count: count, changes: nil, layout: nil, builtFrom: builtFrom)
        }
      }
      let changes = built ?? ScmChanges.build(status)
      let layout = ScmLayout.build(changes, collapsed: collapsed)
      Self.deliver {
        self?.apply(
          branch: branch, count: changes.count, changes: changes, layout: layout,
          builtFrom: builtFrom)
      }
    }
  }

  /// 裏の結果を main へ返す。
  private nonisolated static func deliver(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
  }

  /// 裏の結果を差し替え、待っている組み立てがあれば始める。選んでいた行が消えたら、同じ区分のその位置の行（無ければ
  /// 前の行）を選ぶ（開かない）。置き換えた 2 区分と行の組は裏で手放す（数万行の解放を main に載せない。列が握る写しは
  /// 列が裏で手放す）。行を組んだ（パネルを出している）なら、ブランチの変化をグラフの列へ写す。
  private func apply(
    branch: GitStatus.Branch?, count: Int, changes: ScmChanges?, layout: ScmLayout?,
    builtFrom: Int
  ) {
    buildJob.isRunning = false
    self.branch = branch
    self.count = count
    if let changes, let layout {
      let replaced = (changes: self.changes, layout: self.layout)
      self.changes = changes
      self.layout = layout
      reselect(from: replaced.layout)
      ownWrites.rowsDidApply(builtFrom: builtFrom)
      rowsVersion &+= 1
      DispatchQueue.global(qos: .utility).async { withExtendedLifetime(replaced) {} }
      updateGraphRows()
    }
    if buildJob.again {
      buildJob.again = false
      build()
    }
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
    self.selection = layout.fileID(in: selection.section, at: old - oldRange.lowerBound)
  }

  // MARK: - グラフと HEAD

  /// グラフと HEAD の push 済みを読み直す（パネルを出している間だけ）。`remoteRefsMayHaveMoved` なら、HEAD の push 済みは読み
  /// 終わるまで分からないとする（パネルを出した・再読込・remote 追跡 ref の変化・自分のネット操作の終わり）。
  func readGraphAndHead(remoteRefsMayHaveMoved: Bool) {
    guard isShown else { return }
    guard liveFiles?.repo != nil else {
      headPush = nil
      readsOnResolve = true
      return
    }
    readGraph()
    readHead(remoteRefsMayHaveMoved: remoteRefsMayHaveMoved)
  }

  /// グラフをいつも先頭から今の件数で読む（続きを継ぎ足さない——読みの間に HEAD が動くと重複・欠落する）。読めなければ
  /// 前の結果を保つ。
  private func readGraph() {
    guard isShown, let repo = liveFiles?.repo else { return }
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
        if isShown { updateGraphRows() }
      }
      if graphJob.again {
        graphJob.again = false
        readGraph()
      }
    }
  }

  /// HEAD 1 件をグラフの口で読み、push 済みか（どれかの remote 追跡ブランチから届くか）を読んだコミットと組で持つ。グラフの
  /// 50 件に HEAD が入る保証は無い（upstream が先に進んでいると上位を upstream が占める）ので、グラフの結果から拾わない。
  ///
  /// 分からないとした後は、その後に始めた読みが終わるまで分からないまま（走っている読みはきっかけより前を読んでいるかも
  /// しれないので、終わったらもう 1 回読む）。
  private func readHead(remoteRefsMayHaveMoved: Bool) {
    guard isShown, let repo = liveFiles?.repo else { return }
    if remoteRefsMayHaveMoved { headPushIsStale = true }
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
        readHead(remoteRefsMayHaveMoved: false)
      } else {
        headPushIsStale = false
      }
    }
  }

  /// グラフの列の行の組を今のブランチとグラフから作り、変わっていれば差し替えて列に読み直させる。
  private func updateGraphRows() {
    let next = ScmGraphLayout.build(branch: ScmBranch(branch), graph: graph)
    guard next != graphLayout else { return }
    graphLayout = next
    graphRowsVersion &+= 1
  }

  /// 「さらに表示」: 件数を増やして頭から読み直す。
  func showMoreCommits() {
    graphLimit += Self.graphPage
    readGraph()
  }

  /// 再読込: status を取り直し、グラフと HEAD の push 済みを読み直す。
  func refresh() {
    liveFiles?.requestStatusRefresh()
    readGraphAndHead(remoteRefsMayHaveMoved: true)
  }

  // MARK: - 開閉

  /// 親「ソース管理」を開く・畳む。畳むときは、欄と列が窓から外れる前に焦点を本文へ移させる（外れてからでは AppKit が焦点を
  /// 窓へ落とし、キーがどこにも届かない）。選択は残す。
  func setRepositoryOpen(_ open: Bool) {
    guard open != isRepositoryOpen else { return }
    if !open { onRepositoryWillClose() }
    isRepositoryOpen = open
  }

  func isOpen(_ section: ScmSection) -> Bool { !collapsed.contains(section) }

  func toggle(_ section: ScmSection) {
    if collapsed.remove(section) == nil { collapsed.insert(section) }
    if isShown { requestBuild() }
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
