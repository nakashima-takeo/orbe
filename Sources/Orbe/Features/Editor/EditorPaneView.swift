import AppKit
import OrbeEditorCore
import SwiftUI

/// エディター面の空状態の SwiftUI ルート。器の中の別 root なので環境は明示注入する。
struct EditorFaceRoot: View {
  let localization: LocalizationStore

  var body: some View {
    EditorEmptyView().environment(\.localization, localization)
  }
}

/// エディター面の AppKit 側の根。骨の幾何——レール｜サイドバー（開いているとき）｜列の頭
/// （ファイルタブ行 → 文書があればパンくず）｜本体——を `layout()` が解き、SwiftUI の root 2 枚（左列・列の頭）と本体（焦点の
/// 文書のテキスト面。自分で俯瞰を描く面なら本体全体、そうでなければその右に今の面の俯瞰、無ければ空状態の root）を frame
/// で置く。地は chrome と同じ veil。
///
/// 文書の「変わった」（viewport・選択・本文・ハンク・焦点）は pane が 1 つずつ受け、ミニマップ・スクロールバー・影・検索・
/// 出現の強調・プロジェクト検索へ配る——文書側の closure は単一のまま、扇出はここが持つ。一致の地は、ファイル内検索と
/// プロジェクト検索の 2 つの出どころの和を pane が面と今の面の俯瞰へ押す（`pushFindGround`）。語の出現も束ねて
/// （`OverviewDecorations`）今の面の俯瞰へ押す。自分で俯瞰を描く面は、面へ押した強調の地から俯瞰も描く。
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
  private(set) var document: EditorDocument?
  /// 今の面の俯瞰（本体の右のミニマップとスクロールバー、本体に重ねる影）。自分で俯瞰を描く面の文書では結ばない。
  let appKitOverview = EditorAppKitOverview(style: EditorStyle.make())
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
  /// アウトラインの状態（pane ごと）と、その行の列（絞り込みの欄つき。閉じている間も持つ）。
  let outline = EditorOutline()
  let outlineList: OutlineListView
  /// F4 / ⇧F4 を拾うイベントの監視（窓に付いている間だけ）。
  var stepKeyMonitor: Any?
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
    let outlineList = OutlineListView(outline: outline)
    self.outlineList = outlineList
    sideHost = NSHostingView(
      rootView: EditorSideRoot(
        shell: shell, tree: tree, search: projectSearch, searchResults: searchResults,
        outline: outline, outlineList: outlineList, sidebar: sidebar,
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
    appKitOverview.install(in: self)
    sidebarHandle.autoresizingMask = []
    addSubview(sidebarHandle)
    search.onCountChange = { [weak self] selected, total, limited in
      self?.searchBar?.updateCount(selected: selected, total: total, limited: limited)
    }
    search.onMatchesChange = { [weak self] in self?.pushFindGround() }
    search.onNeedleChange = { [weak self] in self?.syncFindState() }
    occurrences.onWordOccurrencesChange = { [weak self] in self?.pushOverviewDecorations() }
    sidebarHandle.onDrag = { [weak self] width in self?.resizeSidebar(to: width) }
    sidebarHandle.onRelease = { [weak self] in self?.sidebar.commit() }
    wireShell()
    wireTree()
    wireProjectSearch()
    wireOutline()
    observeSidebar()
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  deinit {
    stepKeyMonitor.map(NSEvent.removeMonitor)
  }

  override var isFlipped: Bool { true }

  /// 窓の環境（透過・言語・フォント割り当て・サイドバーの状態）を面へ配る。別 root は Environment を継承
  /// しないので root を作り直す。
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

  private func installRoots() {
    sideHost.rootView = EditorSideRoot(
      shell: shell, tree: tree, search: projectSearch, searchResults: searchResults,
      outline: outline, outlineList: outlineList, sidebar: sidebar,
      localization: localization, fontResolver: fontResolver)
    headerHost.rootView = EditorHeaderRoot(
      shell: shell, localization: localization, fontResolver: fontResolver)
    emptyHost.rootView = EditorFaceRoot(localization: localization)
  }

  // MARK: - 骨の操作 → セッション

  private func wireShell() {
    shell.open = { [weak self] url in self?.open(url) }
    shell.activate = { [weak self] url in
      guard let self, let tab, let document = tab.editor.documents.first(where: { $0.url == url })
      else { return }
      tab.editor.activate(document)
      tree.reveal(document.url)
      focusEditor()
    }
    shell.requestClose = { [weak self] url in self?.requestClose(url) }
    shell.revealDirectory = { [weak self] url in self?.tree.revealDirectory(url) }
    shell.createFile = { [weak self] in self?.beginNew(isDirectory: false) }
    shell.createDirectory = { [weak self] in self?.beginNew(isDirectory: true) }
    shell.collapseAll = { [weak self] in self?.tree.collapseAll() }
    shell.selectPanel = { [weak self] panel in self?.selectPanel(panel) }
    shell.inlineInputLostFocus = { [weak self] generation in
      self?.inlineInputLostFocus(generation: generation)
    }
    shell.inlineInputMayTakeFocus = { [weak self] in
      guard let self, let window else { return true }
      return window.firstResponder === window || window.firstResponder === self
    }
  }

  private func wireTree() {
    tree.onCreated = { [weak self] url in self?.open(url) }
    tree.onInputEnded = { [weak self] in self?.inlineInputDidEnd() }
  }

  /// 骨から開く。読めないときは beep（`open_file` と同じ理由でエラー面は持たない）。開けたらその行を
  /// 選択して焦点を面へ——既に焦点の文書ならセッションは変わらないので、選択はここで明示に移す。
  func open(_ url: URL) {
    guard let tab else { return }
    let document: EditorDocument
    do {
      document = try tab.editor.open(url)
    } catch {
      NSSound.beep()
      return
    }
    tree.reveal(document.url)
    focusEditor()
  }

  /// ファイルタブの ×。未保存なら確認を sheet で出し、保存／保存しないで閉じる（保存が外部変更で失敗すれば
  /// 閉じない）。応答が返るまでに文書が消えていれば何もしない。
  private func requestClose(_ url: URL) {
    guard let tab, let document = tab.editor.documents.first(where: { $0.url == url }) else {
      return
    }
    guard document.isDirty, let window else {
      tab.editor.close(document)
      return
    }
    let alert = UnsavedGate.alert(count: 1, language: localization.language)
    alert.beginSheetModal(for: window) { [weak self, weak document] response in
      guard let self, let tab = self.tab, let document,
        tab.editor.documents.contains(where: { $0 === document }),
        UnsavedGate.proceed(response, discarding: [document])
      else { return }
      tab.editor.close(document)
    }
  }

  /// 行内入力を出す前に pane 自身を first responder にする——入力欄は焦点を面が持っている（窓か面自身）ときだけ取る
  /// （`inlineInputMayTakeFocus`）。続けて出したときは前の入力欄がここで焦点を手放し、新しい行が「面が持っている」と
  /// 見て取る。
  private func beginNew(isDirectory: Bool) {
    window?.makeFirstResponder(self)
    tree.beginNew(isDirectory: isDirectory)
  }

  /// 入力欄が焦点を失った。別の view（端末・テキスト面・面自身）へ移ったなら取り消し＝入力の終わり。窓へ
  /// 落ちたなら人の操作ではない（容器が行を捨てた）ので、入力は生かしたまま焦点を面が預かる——行が戻れば
  /// 入力欄が取り直し、預かっている間に面が焦点を外へ明け渡せば `resignFirstResponder` から同じ判定を通る。
  private func inlineInputLostFocus(generation: Int) {
    guard let window else { return }
    let responder = window.firstResponder
    if responder === window {
      window.makeFirstResponder(self)
      return
    }
    guard (responder as? NSView)?.isDescendant(of: sideHost) != true else { return }
    tree.cancelNew(generation)
  }

  /// 行内入力を預かっている間に焦点を明け渡した。行き先が決まった次のターンに、入力欄と同じ判定へ通す
  /// （戻った行の入力欄なら残り、面の外なら取り消し）。
  override func resignFirstResponder() -> Bool {
    if let generation = tree.newEntry?.generation {
      DispatchQueue.main.async { [weak self] in self?.inlineInputLostFocus(generation: generation) }
    }
    return super.resignFirstResponder()
  }

  /// 行内入力が終わった（状態が落ちた。Enter・Esc・取り消し・すべて折りたたむ・根を畳む・作成先を畳む・
  /// サイドバーを閉じる・cd）。
  private func inlineInputDidEnd() {
    reclaimSidebarFocus()
  }

  /// サイドバーの中の焦点が行き場を失った（行内入力が終わった・検索パネルが隠れた）。焦点がまだサイドバー（骨の host
  /// 配下）か面自身（`beginNew` が停めた・預かっている）か窓に居れば、その場で面の行き先へ移す。別の view へ移って
  /// 終わったなら（端末をクリックして抜けた）そこに居るので触らない。
  func reclaimSidebarFocus() {
    guard let window else { return }
    let responder = window.firstResponder
    let strayed =
      responder === window || responder === self
      || (responder as? NSView)?.isDescendant(of: sideHost) == true
    if strayed { window.makeFirstResponder(focusTarget) }
  }

  private func focusEditor() {
    window?.makeFirstResponder(focusTarget)
  }

  // MARK: - セッション → 骨

  /// セッションが変わった。写しを無条件に組み直し、焦点の文書の面を見せ、文書が変わっていればツリーの
  /// 祖先を開いて選択する。写しを `show` に相乗りさせない——同一文書の未保存・衝突の変化は `show` の
  /// guard で止まる。
  func sessionDidChange() {
    guard let tab else { return }
    let active = tab.editor.activeDocument
    let changed = active !== document
    shell.update(from: tab.editor, root: tree.root)
    show(active)
    if changed, let url = active?.url { tree.reveal(url) }
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
      shell.update(from: tab.editor, root: root)
      if let url = tab.editor.activeDocument?.url { tree.reveal(url) }
    }
  }

  /// 焦点の文書の面を見せる（nil なら空状態）。前の文書の面は外すだけで、面は文書と一緒に生き続ける。文書を初めて
  /// 画面に出すときは、最初の描画に色が間に合うよう文書が上限つきで待つ（→ `prepareDocumentIfVisible`）。
  /// 俯瞰と検索を新しい文書に結び直し（検索は同じ needle で敷き直すだけ）、文書が無くなればバーは閉じる。前の文書の
  /// 一致の地は消し、新しい文書に 2 つの出どころの和を敷く。
  /// 焦点が面の中（サイドバーを除く）にあれば新しい行き先へ移す——判定は前の面を外す前に取る（外した瞬間に AppKit が
  /// first responder を窓へ戻すので、外した後では「中にあった」ことが分からない）。サイドバーの焦点（検索結果・行内
  /// 入力）は面を外しても残るので動かさない。
  func show(_ document: EditorDocument?) {
    guard document !== self.document else { return }
    let hadFocusInside = focusIsInside && !focusIsInSidebar
    if let previous = self.document {
      previous.surface.view.removeFromSuperview()
      observe(previous, false)
      previous.wantsOutline = false
      previous.surface.setHighlights([], for: .findMatch)
      previous.surface.setHighlights([], for: .currentFindMatch)
    }
    self.document = document
    if let document {
      document.surface.host = self
      let view = document.surface.view
      view.autoresizingMask = []
      view.frame = surfaceRect
      // 境の当たり（hairline を跨ぐ 4pt）の右 1pt は本体と重なる。テキスト面は影と俯瞰の下。
      addSubview(view, positioned: .below, relativeTo: appKitOverview.minimap)
      observe(document, true)
    } else {
      closeSearch()
    }
    appKitOverview.bind(overviewSurface == nil ? document : nil)
    search.bind(document)
    occurrences.bind(document)
    if let document { projectSearch.documentDidShow(document) }
    outline.bind(document)
    updateOutlineWant()
    pushFindGround()
    emptyHost.isHidden = document != nil
    prepareDocumentIfVisible()
    needsLayout = true
    if hadFocusInside, window?.firstResponder !== focusTarget {
      window?.makeFirstResponder(focusTarget)
    }
  }

  // MARK: - 可視性（ツリーが根のサービスを握る寿命）

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateLiveness()
    updateStepKeyMonitor()
  }

  override func viewDidHide() {
    super.viewDidHide()
    updateLiveness()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    updateLiveness()
  }

  private func updateLiveness() {
    let live = window != nil && !isHiddenOrHasHiddenAncestor
    tree.isLive = live
    projectSearch.isLive = live
    updateOutlineWant()
    prepareDocumentIfVisible()
  }

  /// 面が画面に見えていれば、結んだ文書を初めて見せる前の上限つきの待ちを通す（2 回目以降は文書が何もしない）。畳まれた
  /// 面・窓に無い面では待たず、面が見えたときに待つ——端末だけの配置のタブを復元しても main を止めない。
  private func prepareDocumentIfVisible() {
    guard let document, window != nil, !isHiddenOrHasHiddenAncestor else { return }
    document.prepareToShow()
  }
}
