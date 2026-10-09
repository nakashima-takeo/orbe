import AppKit
import OrbeEditorCore
import SwiftUI

/// エディター面の AppKit 側の根。骨の幾何——レール｜サイドバー（開いているとき）｜列の頭
/// （タブ行 → タブがあればパンくず）｜本体——を `layout()` が解き、SwiftUI の root 2 枚（左列・列の頭）と本体（焦点のタブ
/// の本体——文書のテキスト面か diff の面。無ければ空状態の root）を frame で置く。地は chrome と同じ veil。
///
/// 文書の「変わった」（viewport・選択・本文・焦点）は pane が 1 つずつ受け、検索・出現の強調・プロジェクト検索・
/// アウトラインへ配る——文書側の closure は単一のまま、扇出はここが持つ。一致の地は、ファイル内検索とプロジェクト検索の
/// 2 つの出どころの和を pane が面へ押す（`pushFindGround`）。俯瞰（ミニマップ・スクロールバーと印・影）は面が、押された
/// 強調の地から自分で描く。
///
/// 骨の状態はセッションの写し（`EditorShellModel`）とツリー（`FileTree`）に持ち、SwiftUI はそれだけを読む。
/// セッションの変化は `sessionDidChange` 1 本で受け、写し → 面の差し替え → ツリーの追従の順に進める。
/// ツリーとプロジェクト検索は面が画面に見えている間（窓に付き、隠れていない）だけ根のサービスを握る。
///
/// chrome キーは `performKeyEquivalent` で先取りし、window コマンドはタブ経由で上位へ、⌘S は保存、
/// 端末のキーは消し、両面のキーのうち ⌘F はファイル内検索、残り（⌘↑↓）と通常の打鍵はテキスト面へ流す。
/// 空状態では通常の打鍵を飲む——エディター焦点中に端末へ届けない。
final class EditorPaneView: NSView {
  weak var tab: TerminalTab?
  /// 骨の写し（ファイルタブ行・パンくず）。
  let shell = EditorShellModel()
  /// エクスプローラーのツリー。根が変われば作り直す。
  private(set) var tree: FileTree
  let sideHost: NSHostingView<EditorSideRoot>
  let headerHost: NSHostingView<EditorHeaderRoot>
  let emptyHost: NSHostingView<EditorFaceRoot>
  /// 本体（焦点のタブの中身）。
  private(set) var body = EditorBody.empty
  /// diff の見せ方（アプリ全体で 1 つ。`configure` が本物を配る）。変化を観測して見せ直す。
  private(set) var diffModes = EditorDiffModeState() {
    didSet { observeDiffModes() }
  }
  /// 並列の diff で最後に焦点のあった側（焦点の行き先。既定は右）。
  var diffFocusesLeft = false
  /// 並列の diff の 2 面の境。
  let diffDivider = NSView()
  /// ファイル内検索の状態（pane ごと）。バーは開いている間だけある。
  let search = EditorSearch()
  var searchBar: SearchBar?
  /// 検索バーの右端の制約（右列の幅が本体の幅で変わるので `layout()` が置き直す）。
  var searchBarTrailing: NSLayoutConstraint?
  /// 出現の強調の状態（pane ごと）。
  let occurrences = EditorOccurrences()
  /// プロジェクト検索の状態（pane ごと＝タブごと）。
  let projectSearch: ProjectSearch
  /// 検索結果の列。検索パネルが隠れている間も持ち、出し直すたびに作り直さない。
  let searchResults: RowList<SearchResultsSource>
  /// F4 / ⇧F4 と結果の列の外の押下を拾うイベントの監視（窓に付いている間だけ）。
  var eventMonitor: Any?
  /// サイドバーの幅と開閉（アプリ全体で 1 つ。`configure` が本物を配る）。変化を観測して置き直す。
  private(set) var sidebar = EditorSidebarState() {
    didSet { observeSidebar() }
  }
  /// サイドバーと本体の境のドラッグの当たり。
  let sidebarHandle = SidebarResizeHandle()
  private(set) var localization = LocalizationStore(language: .systemDefault)
  private var fontResolver = ChromeFontResolver()
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
    sideHost = NSHostingView(
      rootView: EditorSideRoot(
        shell: shell, tree: tree, search: projectSearch, searchResults: searchResults,
        sidebar: sidebar,
        localization: localization, fontResolver: fontResolver))
    headerHost = NSHostingView(
      rootView: EditorHeaderRoot(
        shell: shell, localization: localization, fontResolver: fontResolver))
    emptyHost = NSHostingView(rootView: EditorFaceRoot(localization: localization))
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    for host in [sideHost, headerHost, emptyHost] as [NSView] {
      // SwiftUI 背景の alpha を窓まで通す（透過時に不透明ラスタで塞がない）。
      host.wantsLayer = true
      host.layer?.isOpaque = false
      host.autoresizingMask = []
      addSubview(host)
    }
    sidebarHandle.autoresizingMask = []
    addSubview(sidebarHandle)
    diffDivider.wantsLayer = true
    diffDivider.autoresizingMask = []
    search.onCountChange = { [weak self] selected, total, limited in
      self?.searchBar?.updateCount(selected: selected, total: total, limited: limited)
    }
    search.onMatchesChange = { [weak self] in self?.pushFindGround() }
    search.onNeedleChange = { [weak self] in self?.syncFindState() }
    sidebarHandle.onDrag = { [weak self] width in self?.resizeSidebar(to: width) }
    sidebarHandle.onRelease = { [weak self] in self?.sidebar.commit() }
    wireShell()
    wireTree()
    wireProjectSearch()
    observeSidebar()
    observeDiffModes()
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  deinit {
    eventMonitor.map(NSEvent.removeMonitor)
  }

  override var isFlipped: Bool { true }

  /// 窓の環境（透過・言語・フォント割り当て・サイドバーの状態）を面へ配る。別 root は Environment を継承
  /// しないので root を作り直す。
  func configure(
    translucency: ChromeTranslucency, localization: LocalizationStore,
    fontResolver: ChromeFontResolver, sidebar: EditorSidebarState, diffModes: EditorDiffModeState
  ) {
    self.translucency = translucency
    self.localization = localization
    self.fontResolver = fontResolver
    self.sidebar = sidebar
    self.diffModes = diffModes
    installRoots()
    needsLayout = true
  }

  private func installRoots() {
    sideHost.rootView = EditorSideRoot(
      shell: shell, tree: tree, search: projectSearch, searchResults: searchResults,
      sidebar: sidebar,
      localization: localization, fontResolver: fontResolver)
    headerHost.rootView = EditorHeaderRoot(
      shell: shell, localization: localization, fontResolver: fontResolver)
    emptyHost.rootView = EditorFaceRoot(localization: localization, content: faceContent)
  }

  /// 行内入力を預かっている間に焦点を明け渡した。行き先が決まった次のターンに、入力欄と同じ判定へ通す
  /// （戻った行の入力欄なら残り、面の外なら取り消し）。
  override func resignFirstResponder() -> Bool {
    if let generation = tree.newEntry?.generation {
      DispatchQueue.main.async { [weak self] in self?.inlineInputLostFocus(generation: generation) }
    }
    return super.resignFirstResponder()
  }

  // MARK: - セッション → 骨

  /// セッションが変わった。写しを無条件に組み直し、焦点のタブの本体を見せ、タブが変わっていればツリーの
  /// 祖先を開いてそのファイルを選択する。写しを `show` に相乗りさせない——同一タブの未保存・衝突の変化は `show` の
  /// guard で止まる。
  func sessionDidChange() {
    guard let tab else { return }
    let active = tab.editor.activeTab
    let changed = active?.id != shownID
    shell.update(from: tab.editor, root: tree.root, diffMode: diffModes.mode)
    show(Self.body(of: active))
    if changed, let url = active?.url { tree.reveal(url) }
  }

  /// 本体が見せているタブの識別。
  var shownID: EditorTab.Key? {
    switch body {
    case .document(let document): .document(document.url)
    case .diff(let diff): .diff(diff.id)
    case .empty: nil
    }
  }

  private static func body(of tab: EditorTab?) -> EditorBody {
    switch tab {
    case .document(let document)?: .document(document)
    case .diff(let diff)?: .diff(diff)
    case nil: .empty
    }
  }

  /// 本体が文書のタブなら、その文書（検索・出現・プロジェクト検索・⌘S の相手）。
  var document: EditorDocument? {
    if case .document(let document) = body { return document }
    return nil
  }

  /// 本体が diff のタブなら、その diff。
  var diff: EditorDiff? {
    if case .diff(let diff) = body { return diff }
    return nil
  }

  /// 根が変わった（cd）。ツリーを作り直し、握っていたなら握り直す。プロジェクト検索は結果を捨て、この面の検索パネルが
  /// 画面に見えていれば今の問いで検索し直す（裏のタブの cd で見えない根を探さない）。
  func setRoot(_ root: String) {
    guard root != tree.root else { return }
    tree.cancelNew()
    tree.isLive = false
    tree = FileTree(root: root)
    wireTree()
    projectSearch.setRoot(root, searchNow: showsSearchPanel && projectSearch.isLive)
    updateLiveness()
    installRoots()
    if let tab {
      shell.update(from: tab.editor, root: root, diffMode: diffModes.mode)
      if let url = tab.editor.activeTab?.url { tree.reveal(url) }
    }
  }

  /// 本体を置き換える 1 か所——前の本体を外し（文書の面は外すだけで文書と一緒に生き続け、diff は見せるのをやめて面の
  /// 見え方をコードへ戻す）、新しい本体を載せる（文書の面にはコードの見え方を、diff には今の見せ方の見え方を載せる）。
  /// 文書を初めて画面に出すときは、最初の描画に色が間に合うよう上限つきで待つ（→ `prepareBodyIfVisible`）。検索を新しい
  /// 文書に結び直し（同じ needle で敷き直すだけ）、文書が無くなればバーは閉じる。前の文書の一致の地は消し、新しい文書に
  /// 2 つの出どころの和を敷く。焦点が面の中（サイドバーを除く）にあれば新しい行き先へ移す——判定は前の面を外す前に取る
  /// （外した瞬間に AppKit が first responder を窓へ戻すので、外した後では「中にあった」ことが分からない）。サイドバーの
  /// 焦点（検索結果・行内入力）は面を外しても残るので動かさない。
  func show(_ next: EditorBody) {
    guard !Self.same(next, body) else { return }
    let hadFocusInside = focusIsInside && !focusIsInSidebar
    switch body {
    case .document(let previous):
      previous.surface.view.removeFromSuperview()
      observe(previous, false)
      previous.surface.setHighlights([], for: .findMatch)
      previous.surface.setHighlights([], for: .currentFindMatch)
    case .diff(let previous):
      hideDiff(previous)
    case .empty: break
    }
    body = next
    switch next {
    case .document(let document):
      SurfaceLook.code.apply(to: document.surface, document: document)
      install(document.surface)
      observe(document, true)
    case .diff(let diff):
      closeSearch()
      showDiff(diff)
    case .empty:
      closeSearch()
    }
    search.bind(document)
    occurrences.bind(document)
    if let document { projectSearch.documentDidShow(document) }
    pushFindGround()
    refreshNotice()
    prepareBodyIfVisible()
    needsLayout = true
    if hadFocusInside, window?.firstResponder !== focusTarget {
      window?.makeFirstResponder(focusTarget)
    }
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

  /// 面を本体に載せる。境の当たり（hairline を跨ぐ 4pt）の右 1pt は本体と重なるので、テキスト面はその下。検索バーは後から
  /// 足すので面の上。
  func install(_ surface: any TextSurface) {
    surface.host = self
    let view = surface.view
    view.autoresizingMask = []
    view.frame = bodyRect
    addSubview(view, positioned: .below, relativeTo: sidebarHandle)
  }

  // MARK: - 可視性（ツリーとプロジェクト検索が根のサービスを握る寿命）

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateLiveness()
    updateEventMonitor()
  }

  override func viewDidHide() {
    super.viewDidHide()
    updateLiveness()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    updateLiveness()
  }

  /// 面が画面に見えているか（窓に付き、隠れていない）が変わりうる。見えていれば、テキスト面を描く用意も裏で始める（端末
  /// だけを使う間は払わない）。
  private func updateLiveness() {
    let live = window != nil && !isHiddenOrHasHiddenAncestor
    tree.isLive = live
    projectSearch.isLive = live
    if live { tab?.editor.prepareSurfaces() }
    prepareBodyIfVisible()
  }

  /// 面が画面に見えていれば、本体の文書を初めて見せる前の上限つきの待ちを通す（2 回目以降は文書が何もしない）。畳まれた
  /// 面・窓に無い面では待たず、面が見えたときに待つ——端末だけの配置のタブを復元しても main を止めない。
  func prepareBodyIfVisible() {
    guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
    switch body {
    case .document(let document): document.prepareToShow()
    case .diff(let diff): diff.prepareToShow()
    case .empty: break
    }
  }
}
