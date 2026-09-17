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
/// 文書のテキスト面、無ければ空状態の root）を frame で置く。地は chrome と同じ veil。
///
/// 骨の状態はセッションの写し（`EditorShellModel`）とツリー（`FileTree`）に持ち、SwiftUI はそれだけを読む。
/// セッションの変化は `sessionDidChange` 1 本で受け、写し → 面の差し替え → ツリーの追従の順に進める。
/// ツリーは面が画面に見えている間（窓に付き、隠れていない）だけ根のサービスを握る。
///
/// chrome キーは `performKeyEquivalent` で先取りし、window コマンドはタブ経由で上位へ、⌘S は保存、
/// 端末のキーは消し、両面のキーと通常の打鍵はテキスト面へ流す。空状態では通常の打鍵を飲む——
/// エディター焦点中に端末へ届けない。
final class EditorPaneView: NSView {
  weak var tab: TerminalTab?
  /// 骨の写し（ファイルタブ行・パンくず・サイドバーの可否）。
  let shell = EditorShellModel()
  /// エクスプローラーのツリー。根が変われば作り直す。
  private(set) var tree: FileTree
  private let sideHost: NSHostingView<EditorSideRoot>
  private let headerHost: NSHostingView<EditorHeaderRoot>
  private let emptyHost: NSHostingView<EditorFaceRoot>
  private(set) var document: EditorDocument?
  /// サイドバーの幅と開閉（アプリ全体で 1 つ。`configure` が本物を配る）。変化を観測して置き直す。
  private(set) var sidebar = EditorSidebarState() {
    didSet { observeSidebar() }
  }
  /// サイドバーと本体の境のドラッグの当たり。
  private let sidebarHandle = SidebarResizeHandle()
  private var localization = LocalizationStore(language: .systemDefault)
  private var fontResolver = ChromeFontResolver()
  /// 地の veil。設定パレットで不透明度を変えた直後も追従する（観測して再描画）。
  var translucency: ChromeTranslucency? {
    didSet { observeTranslucency() }
  }

  init(root: String) {
    tree = FileTree(root: root)
    sideHost = NSHostingView(
      rootView: EditorSideRoot(
        shell: shell, tree: tree, localization: localization, fontResolver: fontResolver))
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
      shell: shell, tree: tree, localization: localization, fontResolver: fontResolver)
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
      focusEditor()
    }
    shell.requestClose = { [weak self] url in self?.requestClose(url) }
    shell.revealDirectory = { [weak self] url in self?.tree.revealDirectory(url) }
    shell.createFile = { [weak self] in self?.beginNew(isDirectory: false) }
    shell.createDirectory = { [weak self] in self?.beginNew(isDirectory: true) }
    shell.collapseAll = { [weak self] in self?.tree.collapseAll() }
    shell.toggleSidebar = { [weak self] in self?.sidebar.toggle() }
    shell.endInlineInput = { [weak self] in self?.focusEditor() }
  }

  private func wireTree() {
    tree.onCreated = { [weak self] url in self?.open(url) }
  }

  /// 骨から開く。読めないときは beep（`open_file` と同じ理由でエラー面は持たない）。開けたら焦点を面へ。
  private func open(_ url: URL) {
    guard let tab else { return }
    do {
      try tab.editor.open(url)
    } catch {
      NSSound.beep()
      return
    }
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

  /// 行内入力を出す前に pane 自身を first responder にする——`paneDidFocus(.editor)` が走る経路は
  /// テキスト面と pane の 2 つしか無く、field editor が直接焦点を取ると分割中の焦点帯と位置ドットが
  /// 端末を指したままになる。
  private func beginNew(isDirectory: Bool) {
    window?.makeFirstResponder(self)
    tree.beginNew(isDirectory: isDirectory)
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
    let live = tree.isLive
    tree.isLive = false
    tree = FileTree(root: root)
    wireTree()
    tree.isLive = live
    installRoots()
    if let tab {
      shell.update(from: tab.editor, root: root)
      if let url = tab.editor.activeDocument?.url { tree.reveal(url) }
    }
  }

  /// 焦点の文書の面を見せる（nil なら空状態）。前の文書の面は外すだけで、面は文書と一緒に生き続ける。
  /// 焦点が面の中にあれば新しい行き先へ移す——判定は前の面を外す前に取る（外した瞬間に AppKit が
  /// first responder を窓へ戻すので、外した後では「中にあった」ことが分からない）。
  func show(_ document: EditorDocument?) {
    guard document !== self.document else { return }
    let hadFocusInside = focusIsInside
    self.document?.surface.view.removeFromSuperview()
    self.document = document
    if let document {
      let view = document.surface.view
      view.autoresizingMask = []
      view.frame = bodyRect
      addSubview(view)
    }
    emptyHost.isHidden = document != nil
    needsLayout = true
    if hadFocusInside, window?.firstResponder !== focusTarget {
      window?.makeFirstResponder(focusTarget)
    }
  }

  // MARK: - 幾何

  /// 左列の幅（レール ＋ 右の hairline、サイドバーが開いていれば ＋表示幅 ＋ hairline）。
  private var sideWidth: CGFloat {
    Theme.Layout.editorRail + Theme.Stroke.hairline
      + (sidebar.isOpen ? shownSidebarWidth + Theme.Stroke.hairline : 0)
  }

  /// サイドバーの表示幅。記憶の幅を、本体に最低幅が残るところまで切り詰める（記憶は変えない——列が
  /// 広がれば記憶の幅に戻る）。列がそれでも足りなければ残りをそのまま分け、0 まで縮む。
  var shownSidebarWidth: CGFloat { min(sidebar.width, max(0, sidebarCeiling)) }

  /// 本体に最低幅を残したときのサイドバーの幅の上限。
  private var sidebarCeiling: CGFloat {
    bounds.width - Theme.Layout.editorRail - Theme.Stroke.hairline * 2
      - Theme.Layout.editorBodyMinWidth
  }

  /// ドラッグ中の幅。上限は本体に最低幅が残るまで（下限は状態が守る）。列が狭くてサイドバーを下限まで
  /// も出せないときは掴んでも動かせないので、記憶に触れない。境が動かないドラッグ（切り詰め中に上限へ
  /// 押し付ける）も記憶を書き換えない——記憶は「境を動かした」ときだけ変わる。
  private func resizeSidebar(to width: CGFloat) {
    let ceiling = sidebarCeiling
    guard ceiling >= Theme.Layout.editorSidebarMinWidth else { return }
    let target = min(width, ceiling)
    guard target != shownSidebarWidth else { return }
    sidebar.setWidth(target)
    needsLayout = true  // setWidth は立てない（観測は次のターン）。その場で置き直すために明示する。
    layoutSubtreeIfNeeded()
  }

  private func observeSidebar() {
    withObservationTracking {
      _ = sidebar.width
      _ = sidebar.isOpen
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        self?.needsLayout = true
        self?.observeSidebar()
      }
    }
  }

  /// 列の頭の高さ（ファイルタブ行 ＋ 下の hairline、文書があればパンくずも）。
  private var headerHeight: CGFloat {
    Theme.Layout.editorFileTabs + Theme.Stroke.hairline
      + (document != nil ? Theme.Layout.editorBreadcrumb : 0)
  }

  /// 本体（テキスト面か空状態）の矩形。
  var bodyRect: NSRect {
    NSRect(
      x: sideWidth, y: headerHeight, width: max(0, bounds.width - sideWidth),
      height: max(0, bounds.height - headerHeight))
  }

  override func layout() {
    super.layout()
    if shell.sidebarOpen != sidebar.isOpen { shell.sidebarOpen = sidebar.isOpen }
    let sideWidth = self.sideWidth
    sideHost.frame = NSRect(
      x: 0, y: 0, width: min(sideWidth, bounds.width), height: bounds.height)
    headerHost.frame = NSRect(
      x: sideWidth, y: 0, width: max(0, bounds.width - sideWidth), height: headerHeight)
    let body = bodyRect
    emptyHost.frame = body
    document?.surface.view.frame = body
    sidebarHandle.isHidden = !sidebar.isOpen
    sidebarHandle.frame = NSRect(
      x: sideWidth - Theme.Stroke.hairline - Theme.Layout.editorSidebarHandle / 2, y: 0,
      width: Theme.Layout.editorSidebarHandle, height: bounds.height)
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

  // MARK: - 焦点とキー

  /// first responder が自分か配下にあるか。
  private var focusIsInside: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === self || responder.isDescendant(of: self)
  }

  /// 焦点の行き先。文書があればそのテキスト面、無ければ自分。
  var focusTarget: NSView { document?.surface.responder ?? self }

  override var acceptsFirstResponder: Bool { true }

  /// 空状態の中身は静止しているので、本体のどこを押しても面自身が受ける（焦点を取る）。骨の host は
  /// 自分で受ける。
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point), document == nil else { return super.hitTest(point) }
    return hit === emptyHost || hit.isDescendant(of: emptyHost) ? self : hit
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(focusTarget)
  }

  override func becomeFirstResponder() -> Bool {
    tab?.paneDidFocus(.editor)
    return super.becomeFirstResponder()
  }

  /// chrome キーの解決点。first responder が自分か配下のときだけ効く（隠れたタブの pane は subview から
  /// 外れているが、gate は必ず入れる）。
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard focusIsInside, let action = Keybindings.chromeAction(for: event)
    else { return super.performKeyEquivalent(with: event) }
    switch action.owner {
    case .window:
      if let command = action.windowCommand { tab?.requestWindowCommand(command) }
      return true
    case .editor:
      saveActiveDocument()
      return true
    case .terminal:
      return true
    case .eachFace:
      return super.performKeyEquivalent(with: event)
    }
  }

  /// 空状態で通常の打鍵を飲む（文書があれば打鍵はテキスト面に届き、ここへは来ない）。
  override func keyDown(with event: NSEvent) {}

  /// ⌘S。ディスクが変わっていて失敗したら「上書き／キャンセル」を sheet で出し、上書きで force 保存する。
  /// それ以外の失敗はログだけ。
  private func saveActiveDocument() {
    guard let tab else { return }
    do {
      try tab.editor.saveActive()
    } catch EditorDocumentError.diskChanged {
      guard let window else { return }
      let alert = UnsavedGate.overwriteAlert(language: localization.language)
      alert.beginSheetModal(for: window) { [weak self] response in
        guard let self, let tab = self.tab, UnsavedGate.shouldOverwrite(response) else { return }
        do {
          try tab.editor.saveActive(force: true)
        } catch {
          NSLog("[editor] forced save failed: \(error)")
        }
      }
    } catch {
      NSLog("[editor] save failed: \(error)")
    }
  }
}
