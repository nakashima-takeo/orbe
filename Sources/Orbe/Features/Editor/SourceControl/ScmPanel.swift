import Foundation

/// ソース管理パネルの面ごとの状態——根のサービスの観測（status・git の状態）・件数・2 区分の行・グラフ・HEAD が push 済みか・
/// ステージ済みの行数・親「ソース管理」・子の区分・グラフの枠の開閉・選択・変更の列の焦点。worktree の事実（メッセージ・操作・失敗）は
/// `SourceControl` が持ち、ここは見せ方と観測だけ。
///
/// 面が見えている間（`isLive`）は根のサービスを握って status を受け、件数（上のバーの Changes の添え字）を出す。行の組み立て・グラフ・
/// HEAD の push 済み・ステージ済みの行数の読み（→ `ScmPanel+Reads`）は、Changes の画面を出している間（`isShown`。左の列を閉じていても）だけ行う——件数のために
/// 行を組ませず、ほかの画面のために git を起こさない。変更の列の行の組み立ては裏で 1 本ずつ済ませ、main は結果を差し替えて列に行の版を渡す
/// だけ。グラフの列の行は高々数百行なので main で作る（→ `ScmRows`）。
@MainActor @Observable
final class ScmPanel {
  /// グラフを読む件数の刻み。
  static let graphPage = 50

  /// 根（正準形）。
  let root: String
  /// worktree の状態（メッセージ・操作・失敗）。
  let control: SourceControl
  /// 件数（ステージ済み＋変更の行。git 管理外・未取得は 0）。
  private(set) var count = 0
  /// git 管理下か（nil = まだ分からない）。
  private(set) var isManaged: Bool?
  /// 今の行と件数を作った status のブランチ。
  private(set) var branch: GitStatus.Branch?
  private(set) var changes = ScmChanges.empty
  private(set) var layout = ScmLayout.empty
  /// 変更の列の行の組が変わるたびに進む（列はこれを見て読み直す）。
  private(set) var rowsVersion = 0
  /// グラフと、その列の行の組と、行の組が変わるたびに進む版。変えるのは `ScmPanel+Reads` の読みだけ。
  var graph: GitCommitGraph?
  var graphLayout = ScmGraphLayout.empty
  var graphRowsVersion = 0
  /// ステージ済みの行数と、それを読んだ時点のステージ済みの中身の鍵（`ScmChanges.stagedKey`）。ステージ済みが空なら nil。
  /// 変えるのは `ScmPanel+Reads` の読みだけ。
  var stagedLines: (key: Int, counts: GitLineCounts)?
  /// 親「ソース管理」（2 つの子の区分か「変更なし」の一言）が開いている。変えるのは `setRepositoryOpen` だけ。
  private(set) var isRepositoryOpen = true
  /// グラフの枠が開いている。
  var isGraphOpen = true
  private(set) var collapsed: Set<ScmSection> = []
  private(set) var selection: ScmRowID?
  /// 変更の列に焦点がある。
  private(set) var isListFocused = false
  /// 変更の列へ焦点を入れる要求。当てた後に残すと、列が次に現れたときに古い要求が焦点を奪う。当てずに隠れた要求も捨てる。
  private(set) var wantsListFocus = false
  /// コミットのメッセージ欄に見えている変換中の字（変換中でなければ空）。欄の見せ方なので、worktree のメッセージには確定する
  /// まで入れない。
  var composition = ""
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
  /// 件数と、行を組んでいれば変更の列の行の組を差し替えた（`emptied` は件数が 1 以上から 0 になったか）。
  @ObservationIgnored var onChangesDidApply: (_ emptied: Bool) -> Void = { _ in }
  /// ファイルを普通の文書として開く（Files の画面で）。
  @ObservationIgnored var onOpenFile: (URL) -> Void = { _ in }
  /// 破棄の確認を出す（確認が要らなければそのまま破棄する）。
  @ObservationIgnored var onDiscard: ([ScmChanges.File]) -> Void = { _ in }
  /// 欄の変換を確定する（載っている欄が登録する。欄が無い・変換中でなければ何もしない）。確定した字は、返る前に worktree
  /// のメッセージに入る。
  @ObservationIgnored var confirmComposition: () -> Void = {}
  /// 親を畳む直前（列がまだ窓に居るうち）。焦点が列にあれば、面の本文へ移す。
  @ObservationIgnored var onRepositoryWillClose: () -> Void = {}
  /// 変更の列の状態（`listState`）が変わった（変わった後の main の回で知らせる）。
  @ObservationIgnored var onListStateChange: () -> Void = {}
  /// 面の workspace の実効設定で、裏の fetch がオンか（使う時点で読む）。
  @ObservationIgnored var autoFetchEnabled: () -> Bool = { true }
  /// キーで行へ動いたときの開きの間引き。
  @ObservationIgnored let navigation = RowNavigationThrottle()
  /// 握っている根のサービス（面が見えている間だけ）。
  @ObservationIgnored private(set) var liveFiles: RootFiles?
  /// 欲しいと届けている裏の fetch の係。
  @ObservationIgnored private(set) var autoFetch: ScmAutoFetch?
  private var buildJob = Job()
  @ObservationIgnored var ownWrites = ScmOwnWrites()
  /// 手元の 2 区分が今の status から作ったものでない（status が届いてから、行を作る組み立てがまだ始まっていない）。
  private var changesAreStale = true
  @ObservationIgnored var graphLimit = ScmPanel.graphPage
  @ObservationIgnored var graphJob = Job()
  @ObservationIgnored var headJob = Job()
  @ObservationIgnored var isReadingStagedLines = false
  var headPush: (commit: String, isPushed: Bool)?
  /// remote 追跡 ref が動きうるきっかけの後、その後に始めた読みが終わるまで（前の値を有効なまま残すと、自分の push の
  /// 直後に amend・取り消しが押せる）。
  var headPushIsStale = false

  /// 読み・組み立て 1 本の直列化。実行中に来た要求は「終わったらもう 1 回」に畳む。
  struct Job {
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

  /// Changes の画面を出している間 true。出したら行を組み、グラフと HEAD の push 済みを読む。
  @ObservationIgnored var isShown = false {
    didSet {
      guard isShown != oldValue else { return }
      if isShown {
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
    observeListState(listState)
  }

  // MARK: - 観測

  /// 根のサービスが git 管理下かを読む。握った時点で判定が済んでいればそこで、まだなら判定が済んだ知らせで決まる（判定は
  /// 根のサービスごとに 1 度だけ決まる）。管理下なら裏の fetch を欲しがるか決め直す。
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

  /// 変更の列の行が、今の status からまだ出来ていない（status を受け取る前・組み立てを始める前・組み立ての最中）。
  var rowsArePending: Bool { changesAreStale || buildJob.isRunning || liveFiles?.status == nil }

  /// status が届いた（か、握り直した根のサービスの status を読む）。
  func statusDidChange() {
    guard liveFiles?.status != nil else { return }
    ownWrites.statusDidArrive()
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
  /// 前の行）を選ぶ（開かない）。その区分が畳まれていれば見出しを選ぶ（畳んでから組が差し替わるまでの間に、古い組で
  /// その区分のファイル行を選んだとき）。置き換えた 2 区分と行の組は裏で手放す（数万行の解放を main に載せない。列が
  /// 握る写しは列が裏で手放す）。行を組んだ（パネルを出している）なら、ブランチの変化をグラフの列へ写し、ステージ済みの
  /// 中身が変わっていれば行数を読み直す。
  private func apply(
    branch: GitStatus.Branch?, count: Int, changes: ScmChanges?, layout: ScmLayout?,
    builtFrom: Int
  ) {
    buildJob.isRunning = false
    let emptied = self.count > 0 && count == 0
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
      stagedDidChange()
    }
    onChangesDidApply(emptied)
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

  // MARK: - 開閉

  /// 親「ソース管理」を開く・畳む。畳むときは、列が窓から外れる前に焦点を本文へ移させる（外れてからでは AppKit が焦点を
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

  func requestListFocus() {
    wantsListFocus = true
  }

  func listFocusRequestDidApply() {
    wantsListFocus = false
  }

  /// 列へ焦点を入れる要求が残っていれば取り消す。
  func cancelListFocusRequest() {
    if wantsListFocus { wantsListFocus = false }
  }

  /// 列の焦点が入った・抜けた。抜けたら待っている開きを捨てる。
  func listFocusDidChange(_ focused: Bool) {
    if !focused { navigation.drop() }
    isListFocused = focused
  }

  /// パネルが隠れた（隠れた view は焦点が抜けたことを知らせない）。
  func panelDidHide() {
    navigation.drop()
    isListFocused = false
    wantsListFocus = false
  }
}
