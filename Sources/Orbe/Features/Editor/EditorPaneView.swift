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
/// 文書のテキスト面とその右の俯瞰、無ければ空状態の root）を frame で置く。地は chrome と同じ veil。
///
/// 文書の「変わった」（viewport・選択・本文・ハンク）は pane が 1 つずつ受け、俯瞰と検索へ配る——文書側の closure は
/// 単一のまま、扇出はここが持つ。
///
/// 骨の状態はセッションの写し（`EditorShellModel`）とツリー（`FileTree`）に持ち、SwiftUI はそれだけを読む。
/// セッションの変化は `sessionDidChange` 1 本で受け、写し → 面の差し替え → ツリーの追従の順に進める。
/// ツリーは面が画面に見えている間（窓に付き、隠れていない）だけ根のサービスを握る。
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
  /// 本体の右の俯瞰（ミニマップ・印の列）。焦点の文書に結ぶ。
  let overview = EditorOverviewView(style: EditorStyle.overview())
  /// ファイル内検索の状態（pane ごと）。バーは開いている間だけある。
  let search = EditorSearch()
  var searchBar: SearchBar?
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
    sideHost = NSHostingView(
      rootView: EditorSideRoot(
        shell: shell, tree: tree, sidebar: sidebar, localization: localization,
        fontResolver: fontResolver))
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
    overview.autoresizingMask = []
    addSubview(overview)
    sidebarHandle.autoresizingMask = []
    addSubview(sidebarHandle)
    search.onCountChange = { [weak self] selected, total in
      self?.searchBar?.updateCount(selected: selected, total: total)
    }
    sidebarHandle.onDrag = { [weak self] width in self?.resizeSidebar(to: width) }
    sidebarHandle.onRelease = { [weak self] in self?.sidebar.commit() }
    wireShell()
    wireTree()
    observeSidebar()
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

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
      shell: shell, tree: tree, sidebar: sidebar, localization: localization,
      fontResolver: fontResolver)
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
    shell.toggleSidebar = { [weak self] in self?.sidebar.toggle() }
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
  private func open(_ url: URL) {
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

  /// 行内入力を出す前に pane 自身を first responder にする——`paneDidFocus(.editor)` が走る経路はテキスト面と
  /// pane の 2 つしか無く、field editor が直接焦点を取ると分割中の焦点帯と位置ドットが端末を指したままになる。
  /// 続けて出したときは前の入力欄がここで焦点を手放し、新しい行が「面が持っている」と見て取る。
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
  /// サイドバーを閉じる・cd）。焦点がまだ入力欄（骨の host 配下）か面自身（`beginNew` が停めた・預かっている）
  /// か窓に居れば、その場で面の行き先へ移す。別の view へ移って終わったなら（端末をクリックして抜けた）
  /// そこに居るので触らない。
  private func inlineInputDidEnd() {
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

  /// 根が変わった（cd）。ツリーを作り直し、握っていたなら握り直す。
  func setRoot(_ root: String) {
    guard root != tree.root else { return }
    tree.cancelNew()
    tree.isLive = false
    tree = FileTree(root: root)
    wireTree()
    updateLiveness()
    installRoots()
    if let tab {
      shell.update(from: tab.editor, root: root)
      if let url = tab.editor.activeDocument?.url { tree.reveal(url) }
    }
  }

  /// 焦点の文書の面を見せる（nil なら空状態）。前の文書の面は外すだけで、面は文書と一緒に生き続ける。
  /// 俯瞰と検索を新しい文書に結び直し（検索は同じ needle で敷き直すだけ）、文書が無くなればバーは閉じる。
  /// 焦点が面の中にあれば新しい行き先へ移す——判定は前の面を外す前に取る（外した瞬間に AppKit が
  /// first responder を窓へ戻すので、外した後では「中にあった」ことが分からない）。
  func show(_ document: EditorDocument?) {
    guard document !== self.document else { return }
    let hadFocusInside = focusIsInside
    if let previous = self.document {
      previous.surface.view.removeFromSuperview()
      observe(previous, false)
    }
    self.document = document
    if let document {
      let view = document.surface.view
      view.autoresizingMask = []
      view.frame = surfaceRect
      // 境の当たり（hairline を跨ぐ 4pt）の右 1pt は本体と重なる。テキスト面の下に置いて当たりを保つ。
      addSubview(view, positioned: .below, relativeTo: sidebarHandle)
      observe(document, true)
    } else {
      closeSearch()
    }
    overview.bind(document)
    search.bind(document)
    emptyHost.isHidden = document != nil
    applyGround()
    needsLayout = true
    if hadFocusInside, window?.firstResponder !== focusTarget {
      window?.makeFirstResponder(focusTarget)
    }
  }

  /// 文書の「変わった」を俯瞰と検索へ配る（見せている文書だけ）。
  private func observe(_ document: EditorDocument, _ on: Bool) {
    document.onViewportChange = on ? { [weak self] in self?.overview.refresh() } : nil
    document.onHunksChange = on ? { [weak self] in self?.overview.refresh() } : nil
    document.onSelectionChange =
      on
      ? { [weak self] in
        self?.overview.refresh()
        self?.search.selectionDidChange()
      } : nil
    document.onTextChange =
      on
      ? { [weak self] change in
        self?.overview.textDidChange(change)
        self?.search.textDidChange()
      } : nil
  }

  // MARK: - 可視性（ツリーが根のサービスを握る寿命）

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateLiveness()
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
    tree.isLive = window != nil && !isHiddenOrHasHiddenAncestor
  }
}
