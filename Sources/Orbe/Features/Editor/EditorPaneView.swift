import AppKit
import OrbeEditorCore
import SwiftUI

/// エディター面の AppKit 側の根。骨の幾何——上のバー、その下に左の列（開いているとき）｜本体——を `layout()` が解き、
/// SwiftUI の root（上のバー・左の列・diff の見出し・本体に文字だけを出す器・一覧の器）と本体（セッションが画面から導いた
/// 中身——文書のテキスト面か diff の面）を frame で置く。上のバーとその地のほかは 1 枚の view（`belowBar`）にまとめ、⌥ の
/// 透かしの濃さはそこへ掛かる。地は chrome と同じ veil を、バーの分とバーより下の分に分けて塗る。
///
/// 本体で編集する文書（文書の本体ならその文書、diff の本体なら新しい側の文書）の「変わった」（viewport・選択・本文）は
/// pane が 1 つずつ受け、検索・出現の強調・diff・プロジェクト検索へ配る——文書側の closure は単一のまま、扇出はここが持つ。
/// 一致の地は、ファイル内検索とプロジェクト検索の 2 つの出どころの和を pane が面へ押す（`pushFindGround`）。
/// 俯瞰（ミニマップ・スクロールバーと印・影）は面が、押された強調の地から自分で描く。
///
/// 骨の状態は写し（`EditorShellModel`）と、観測できる持ち主（ツリー・各パネルの状態・一覧の器・左の列の開閉）に持ち、
/// SwiftUI は `EditorSession` / `EditorDocument` を直接観測しない。
/// セッションの変化は `sessionDidChange` 1 本で受け、左の列の中身 → 面の差し替え → ツリーの追従の順に進める。
/// ツリー・プロジェクト検索・ソース管理パネルは面が画面に見えている間（窓に付き、隠れていない）だけ根のサービスを握る。
///
/// chrome キーは `performKeyEquivalent` で先取りし、window コマンドは連経由で上位へ、⌘S は保存、
/// 端末のキーは消し、両面のキーのうち ⌘F はファイル内検索、残り（⌘↑↓）と通常の打鍵はテキスト面へ流す。
/// 空状態では通常の打鍵を飲む——エディター焦点中に端末へ届けない。
final class EditorPaneView: NSView {
  weak var group: TabGroup?
  /// worktree の今の PR が替わった・その PR の状態が変わった（連が上段の現在地を描き直させる）。
  var onPullRequestChange: () -> Void = {}
  /// 骨の写し（pane が書き SwiftUI が読む値と、骨の操作の閉包）。
  let shell = EditorShellModel()
  /// エクスプローラーのツリー。根が変われば作り直す。
  private(set) var tree: FileTree
  let barHost: EditorBarHost
  /// 上のバーより下の中身をまとめる view（面いっぱいの枠で、中身はバーの下に置く）。
  let belowBar = EditorBelowBar()
  /// 地の veil——上のバーの分と、バーより下の分（`belowBar` の中。透かしの間はバーより下と一緒に見えなくなる）。
  let barGround = NSView()
  let belowGround = NSView()
  /// 器が透かしている（上のバーの「⌥ 端末を表示」を押している間の姿にする）。
  var isPeeking = false {
    didSet { shell.isPeeking = isPeeking }
  }
  let sideHost: NSHostingView<EditorSideRoot>
  let faceHost: NSHostingView<EditorFaceRoot>
  /// 差分のファイルの見出し（本体が diff の間だけ出す）。
  let headerHost: DiffFileHeaderHost
  /// 本体（セッションが画面から導いた中身）。
  private(set) var body = EditorBody.empty
  /// ツリーで最後に選択表示した Files の今の文書（替わったときだけツリーを追従させる）。
  private var revealedDocument: URL?
  /// 見ている（本体に出ていて、面が見えている）diff。
  var watchedDiff: EditorDiff?
  /// 開いた diff の行が左の列の一覧にまだ無い間の、その diff（行ができたら選択表示する）。
  var diffAwaitingRow: EditorDiff.Key?
  /// 焦点を預かっている一覧の画面（Changes・PR。行が出たら一覧へ渡す。→ `holdListFocus`）。
  var heldListFocus: EditorScreen?
  /// ツリーの × を押した後の押し続けの守り（→ `closeFromTree`）。
  var treeMarkPressGuard: RowListPressGuard?
  /// 並列の diff で最後に焦点のあった側（焦点の行き先。既定は右）。
  var diffFocusesLeft = false
  /// 並列の diff の 2 面の境。
  let diffDivider = NSView()
  /// 本体に置いている diff の面の view（左から）。
  var diffViews: [NSView] = []
  /// 知らせを結んでいる文書（本体で編集する文書を結んだもの——`bindEditedDocument`）。
  weak var boundDocument: EditorDocument?
  /// ファイル内検索の状態と、上のバーの欄の持ち主（pane ごと）。欄の状態は出している間だけある。
  let search = EditorSearch()
  let findField = EditorFindField()
  /// 出現の強調の状態（pane ごと）。
  let occurrences = EditorOccurrences()
  /// プロジェクト検索の状態（pane ごと＝連ごと）。
  let projectSearch: ProjectSearch
  /// 検索結果の列。検索パネルが隠れている間も持ち、出し直すたびに作り直さない。
  let searchResults: RowList<SearchResultsSource>
  /// プロジェクト検索が一致を開いて本文に置いた選択。その文書の選択が動けば忘れる（→ `projectSearchSeed`）。
  var searchPlacedSelection: SearchPlacedSelection?
  /// ソース管理パネルの状態（面ごと。根が変われば作り直す）。
  private(set) var scm: ScmPanel
  /// ソース管理の変更の列とグラフの列（検索結果の列と同じく、パネルが隠れている間も持つ）。
  private(set) var scmList: RowList<ScmListSource>
  private(set) var scmGraphList: RowList<ScmGraphSource>
  /// PR のパネルの状態と列と列の頭（面ごと。根が変われば作り直す）。
  private(set) var pullRequest: PrPanel
  private(set) var pullRequestList: RowList<PrListSource>
  private(set) var pullRequestHeader = PrDescriptionHeader(frame: .zero)
  /// 一覧の器（今の項目のボタンに付いて浮く一覧）と、その地と下の案内の host。器の行の列と host は、開いている間だけ
  /// バーより下の最前面に出す。
  let itemList = EditorItemList()
  let itemListHost: EditorItemListHost
  /// Files の一覧を器に載せる側。
  private(set) lazy var openFilesList = OpenFilesList(pane: self)
  /// Changes・PR の変更ファイルの一覧を器に載せる側。
  private(set) lazy var changedFilesList = ChangedFilesList(pane: self)
  /// 上のバーの今の項目のボタンの枠（バーの座標＝面の座標。ボタンが出ていなければ nil）。一覧の矩形の入力。
  var itemButtonFrame: CGRect?
  /// ポップアップの器（上のバーの右端のボタンから、バーの右下に開く）と、ポップアップとその下に並ぶ札を置く host（バーより
  /// 下の層）。
  let popup = EditorPopup()
  private(set) lazy var dockHost = EditorDockHost(rootView: dockRoot())
  /// ポップアップを開く前のフォーカスの場所（閉じたら、きっかけが求めれば戻す）。
  var popupReturn = FocusPlace.body
  /// ポップアップが開いている間の、フォーカスの行き先の見張り。
  var popupFocusWatch: EditorFocusWatch?
  /// 上のバーの右端の主な操作のボタンの枠（ボタンの印ごと。バーの座標＝面の座標。今あるボタンの分だけ）。ポップアップの外の
  /// 押下の判定の入力。
  var actionButtonFrames: [UUID: CGRect] = [:]
  /// F4 / ⇧F4・PR の画面のキー v と、結果の列・一覧の器の外の押下を拾うイベントの監視（窓に付いている間だけ）。
  var eventMonitor: Any?
  /// 左の列の幅と開閉（アプリ全体で 1 つ。`configure` が本物を配る）。変化を観測して置き直す。
  private(set) var sidebar = EditorSidebarState() {
    didSet { observeSidebar() }
  }
  /// Files の画面の左の列の中身（エクスプローラーか検索。保存しない）。
  var filesPanel = EditorShellModel.Panel.files {
    didSet { syncPanel() }
  }
  /// 左の列と本体の境のドラッグの当たり。
  let sidebarHandle = SidebarResizeHandle()
  private(set) var localization = LocalizationStore(language: .systemDefault)
  private(set) var fontResolver = ChromeFontResolver()
  /// 面の workspace の実効設定（使う時点で読む。窓が連を作るときに配る）。
  var settings: () -> EffectiveSettings = { EffectiveSettings(SettingsLayer()) }
  /// 地の veil。設定パレットで不透明度を変えた直後も追従する（観測して再描画）。
  var translucency: ChromeTranslucency? {
    didSet { observeTranslucency() }
  }

  init(root: String) {
    tree = FileTree(root: root)
    let projectSearch = ProjectSearch(root: root)
    self.projectSearch = projectSearch
    let searchResults = RowList(
      source: SearchResultsSource(search: projectSearch), rowHeight: Theme.Layout.editorSearchRow)
    self.searchResults = searchResults
    let scm = ScmPanel(root: root)
    self.scm = scm
    let scmList = Self.scmList(scm)
    self.scmList = scmList
    let scmGraphList = Self.scmGraphList(scm)
    self.scmGraphList = scmGraphList
    let pullRequest = PrPanel(root: root, source: .gh())
    self.pullRequest = pullRequest
    let pullRequestList = Self.pullRequestList(pullRequest)
    self.pullRequestList = pullRequestList
    barHost = EditorBarHost(
      rootView: EditorBarRoot(
        shell: shell, sidebar: sidebar, itemList: itemList, scm: scm,
        pullRequest: pullRequest.pullRequest, findField: findField,
        localization: localization, fontResolver: fontResolver))
    sideHost = NSHostingView(
      rootView: EditorSideRoot(
        shell: shell, tree: tree, search: projectSearch, searchResults: searchResults, scm: scm,
        scmList: scmList, scmGraphList: scmGraphList, pullRequest: pullRequest,
        pullRequestList: pullRequestList, pullRequestHeader: pullRequestHeader, sidebar: sidebar,
        localization: localization, fontResolver: fontResolver))
    faceHost = NSHostingView(
      rootView: EditorFaceRoot(localization: localization, scm: scm, pullRequest: pullRequest))
    headerHost = DiffFileHeaderHost(
      rootView: DiffFileHeaderRoot(localization: localization, scm: scm))
    itemListHost = EditorItemListHost(
      rootView: EditorItemListRoot(
        itemList: itemList, localization: localization, fontResolver: fontResolver,
        translucency: ChromeTranslucency()))
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    assembleViews()
    search.onCountChange = { [weak self] selected, total, limited in
      self?.findField.model?.updateCount(selected: selected, total: total, limited: limited)
    }
    search.onMatchesChange = { [weak self] in self?.pushFindGround() }
    search.onNeedleChange = { [weak self] in self?.syncFindState() }
    sidebarHandle.shownWidth = { [weak self] in self?.shownSidebarWidth ?? 0 }
    sidebarHandle.onDrag = { [weak self] width in self?.resizeSidebar(to: width) }
    sidebarHandle.onRelease = { [weak self] in self?.sidebar.commit() }
    wireShell()
    wireTree()
    wireProjectSearch()
    wireSourceControl()
    wirePullRequest()
    wireItemList()
    wireDock()
    observeSidebar()
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  deinit {
    eventMonitor.map(NSEvent.removeMonitor)
  }

  override var isFlipped: Bool { true }

  /// 窓の環境（透過・言語・フォント割り当て・左の列の状態）を面へ配る。別 root は Environment を継承しないので root を
  /// 作り直す。
  func configure(
    translucency: ChromeTranslucency, localization: LocalizationStore,
    fontResolver: ChromeFontResolver, sidebar: EditorSidebarState
  ) {
    self.translucency = translucency
    self.localization = localization
    self.fontResolver = fontResolver
    self.sidebar = sidebar
    installRoots()
    needsLayout = true
  }

  private static func scmList(_ scm: ScmPanel) -> RowList<ScmListSource> {
    RowList(source: ScmListSource(panel: scm), rowHeight: Theme.Layout.editorScmRow)
  }

  private static func scmGraphList(_ scm: ScmPanel) -> RowList<ScmGraphSource> {
    RowList(source: ScmGraphSource(panel: scm), rowHeight: Theme.Layout.editorScmRow)
  }

  private func installRoots() {
    barHost.rootView = EditorBarRoot(
      shell: shell, sidebar: sidebar, itemList: itemList, scm: scm,
      pullRequest: pullRequest.pullRequest, findField: findField,
      localization: localization, fontResolver: fontResolver)
    sideHost.rootView = EditorSideRoot(
      shell: shell, tree: tree, search: projectSearch, searchResults: searchResults, scm: scm,
      scmList: scmList, scmGraphList: scmGraphList, pullRequest: pullRequest,
      pullRequestList: pullRequestList, pullRequestHeader: pullRequestHeader, sidebar: sidebar,
      localization: localization, fontResolver: fontResolver)
    faceHost.rootView = faceRoot(faceContent)
    headerHost.rootView = headerRoot(headerSubject)
    itemListHost.rootView = EditorItemListRoot(
      itemList: itemList, localization: localization, fontResolver: fontResolver,
      translucency: translucency ?? ChromeTranslucency())
    dockHost.rootView = dockRoot()
    itemList.emoji = fontResolver.emojiFont
  }

  /// 焦点を明け渡した。一覧のための預かりはここで終わる。行内入力を預かっていたなら、行き先が決まった次のターンに、
  /// 入力欄と同じ判定へ通す（戻った行の入力欄なら残り、面の外なら取り消し）。
  override func resignFirstResponder() -> Bool {
    endListFocusHold()
    if let generation = tree.newEntry?.generation {
      DispatchQueue.main.async { [weak self] in self?.inlineInputLostFocus(generation: generation) }
    }
    return super.resignFirstResponder()
  }

  // MARK: - セッション → 骨

  /// セッションが変わった。左の列の中身を画面に合わせ、セッションが画面から導いた本体を見せ、Files の今の文書が替わって
  /// いればツリーの祖先を開いてそのファイルを選択する。本体が空のまま画面が替わったときも、器の中身は画面で決まるので
  /// 置き直す。上のバーの今の項目と、開いている一覧の中身も写し直す。
  func sessionDidChange() {
    guard let group else { return }
    syncPanel()
    show(group.editor.body)
    refreshNotice()
    refreshHeader()
    let active = group.editor.activeURL
    if active != revealedDocument {
      revealedDocument = active
      if let active { tree.reveal(active) }
    }
    reconcileWithLists()
    refreshCurrentItem()
    refreshOpenMarks()
  }

  /// 本体が文書なら、その文書（ファイル内検索・出現の強調・一致の地の相手）。
  var document: EditorDocument? {
    if case .document(let document) = body { return document }
    return nil
  }

  /// 本体で編集する文書——文書の本体ならその文書、diff の本体なら新しい側の文書（無ければ nil）。
  var editedDocument: EditorDocument? { document ?? diff?.document }

  /// 本体が diff なら、その diff。
  var diff: EditorDiff? {
    if case .diff(let diff) = body { return diff }
    return nil
  }

  /// 根が変わった（cd）。ポップアップを閉じ（戻したフォーカスは、パネルが外れる前に本体へ移す決まりを通る）、ツリーと
  /// ソース管理パネルと PR のパネルを作り直し（前の根の PR は見るのをやめる）、握っていたなら
  /// 握り直す（worktree の状態——メッセージ・操作・失敗——は worktree ごとに残るので、戻れば同じものが見える）。プロジェクト
  /// 検索は結果を捨て、この面の検索パネルが画面に見えていれば今の問いで検索し直す（裏の連の cd で見えない根を探さない）。
  func setRoot(_ root: String) {
    guard root != tree.root else { return }
    popup.close(.itemGone)
    tree.cancelNew()
    // エクスプローラーは同じ欄のまま作り直したツリーへ替わり、欄の焦点を新しいツリーへ写さないので、作り直す前に焦点を面の
    // 行き先へ移す。
    if tree.explorerFocus == .filter { reclaimSidebarFocus() }
    tree.isLive = false
    tree = FileTree(root: root)
    wireTree()
    // パネルは作り直されて欄と列が窓から外れるので、外れる前に焦点を面の行き先へ移す。
    if focusIsInSourceControl { reclaimSidebarFocus() }
    scm.isShown = false
    scm.isLive = false
    scm = ScmPanel(root: root)
    scmList = Self.scmList(scm)
    scmGraphList = Self.scmGraphList(scm)
    wireSourceControl()
    if focusIsInPullRequest { reclaimSidebarFocus() }
    pullRequest.isShown = false
    pullRequest.isTracking = false
    pullRequest = PrPanel(root: root, source: .gh())
    pullRequestList = Self.pullRequestList(pullRequest)
    pullRequestHeader = PrDescriptionHeader(frame: .zero)
    wirePullRequest()
    projectSearch.setRoot(root, searchNow: showsSearchPanel && projectSearch.isLive)
    updateLiveness()
    installRoots()
    if let url = group?.editor.activeURL { tree.reveal(url) }
    refreshCurrentItem()
    refreshOpenMarks()
  }

  /// 本体を置き換える 1 か所——前の本体を外し（文書の面は外すだけで文書と一緒に生き続け、diff は見せるのをやめて面の
  /// 見え方をコードへ戻す）、新しい本体を載せる（文書の面にはコードの見え方を、diff には今の見せ方の見え方を載せる）。
  /// 配置を頼み、文書を初めて画面に出すときはその配置で、最初の描画に色が間に合うよう上限つきで待つ（→
  /// `prepareBodyIfVisible`）。検索を新しい文書に結び直し（同じ needle で敷き直すだけ）、文書が無くなれば欄は閉じる。
  /// 文書の知らせは、本体で編集する文書へ結び直す（→ `bindEditedDocument`）。
  /// 前の文書の一致の地は消し、新しい文書に 2 つの出どころの和を敷く。焦点が本体にあれば新しい行き先へ移す——判定は
  /// 前の面を外す前に取る（外した瞬間に AppKit が first responder を窓へ戻すので、外した後では「中にあった」ことが
  /// 分からない）。左の列の焦点（検索結果・行内入力）と一覧の器の焦点は面を外しても残るので動かさない。
  func show(_ next: EditorBody) {
    guard !Self.same(next, body) else { return }
    let hadFocusInside = focusIsInBody
    unbind(body)
    body = next
    switch next {
    case .document(let document):
      SurfaceLook.code.apply(to: document.surface, document: document)
      install(document.surface)
    case .diff(let diff):
      showDiff(diff)
      closeSearch()
    case .empty:
      closeSearch()
    }
    search.bind(document)
    occurrences.bind(document)
    bindEditedDocument()
    pushFindGround()
    refreshNotice()
    refreshHeader()
    needsLayout = true
    if hadFocusInside, window?.firstResponder !== focusTarget {
      window?.makeFirstResponder(focusTarget)
    }
    updateDiffWatching()
  }

  /// 同じ本体か（同じ文書・同じ diff・どちらも空）。
  private static func same(_ a: EditorBody, _ b: EditorBody) -> Bool {
    switch (a, b) {
    case (.document(let x), .document(let y)): x === y
    case (.diff(let x), .diff(let y)): x === y
    case (.empty, .empty): true
    default: false
    }
  }

  /// 見せている本体を、セッションに告げずに手放す——この面の観測・テキスト面の親・一致の強調を外し、diff は見せるのをやめて
  /// 問い合わせを止める。開いている文書を別の連のセッションへ移す前（外さないと、この面の後片付けが移した先の文書や diff を
  /// 壊す）と、連が終わるとき（器が連より長く生きても、diff と文書をセッションより長く生かさない）に呼ぶ。焦点は動かさない。
  func releaseBody() {
    unbind(body)
    body = .empty
    search.bind(nil)
    occurrences.bind(nil)
    bindEditedDocument()
    updateDiffWatching()
  }

  /// 本体を外す——文書の面は外すだけで文書と一緒に生き続け、diff は見せるのをやめて面の見え方をコードへ戻す。
  private func unbind(_ body: EditorBody) {
    switch body {
    case .document(let document):
      document.surface.view.removeFromSuperview()
      document.surface.setHighlights([], for: .findMatch)
      document.surface.setHighlights([], for: .currentFindMatch)
    case .diff(let diff):
      hideDiff(diff)
    case .empty: break
    }
  }
}
