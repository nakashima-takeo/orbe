import AppKit
import OrbeEditorCore

/// 骨の操作 → セッション。骨（上のバー・ツリー）の閉包を pane へ結び、pane が連経由でセッションに書く。
extension EditorPaneView {
  func wireShell() {
    shell.open = { [weak self] url, mode in self?.open(url, as: mode) }
    shell.createFile = { [weak self] in self?.beginNew(isDirectory: false) }
    shell.createDirectory = { [weak self] in self?.beginNew(isDirectory: true) }
    shell.collapseAll = { [weak self] in self?.tree.collapseAll() }
    shell.selectScreen = { [weak self] screen in self?.switchScreen(screen) }
    shell.toggleSidebar = { [weak self] in self?.toggleSidebar() }
    shell.inlineInputLostFocus = { [weak self] generation in
      self?.inlineInputLostFocus(generation: generation)
    }
    shell.inlineInputMayTakeFocus = { [weak self] in
      guard let self, let window else { return true }
      return window.firstResponder === window || window.firstResponder === self
    }
  }

  func wireTree() {
    tree.onCreated = { [weak self] url in self?.open(url, as: .pinned) }
    tree.onInputEnded = { [weak self] in self?.inlineInputDidEnd() }
  }

  /// フォーカスの場所——左の列の一覧か、本体。
  enum FocusPlace {
    case list
    case body
  }

  /// 今のフォーカスの場所。ソース管理パネルか PR のパネルに在るか、一覧のために面が預かっていれば一覧、ほかは本体。
  var focusPlace: FocusPlace {
    focusIsInSourceControl || focusIsInPullRequest || heldListFocus != nil ? .list : .body
  }

  /// 上のバーで画面を選ぶ。選んだ後のフォーカスは、その画面の一覧へ（→ `returnFocus`）。
  func switchScreen(_ screen: EditorScreen) {
    guard let group else { return }
    group.editor.selectScreen(screen)
    returnFocus(to: .list)
  }

  /// フォーカスを場所 `place` へ移す。一覧なら、Changes・PR で左の列を開いていて、今の画面の一覧の状態が「無い」でなければ
  /// 面が預かって一覧へ渡し（→ `holdListFocus`）、一覧が既にフォーカスを持っていれば触らない。それ以外（一覧が無い・本体）
  /// は本体の行き先へ。
  func returnFocus(to place: FocusPlace) {
    let screen = group?.editor.screen ?? .files
    if place == .list, sidebar.isOpen, screen != .files {
      if listHasFocus(screen) { return }
      if listState(of: screen) != .none {
        holdListFocus(for: screen)
        return
      }
    }
    layoutSubtreeIfNeeded()
    focusEditor()
  }

  /// 一覧 `screen` のためにフォーカスを預かる——面自身がフォーカスを持ち、行があれば一覧へ求め、行がまだ無ければ出た時点で
  /// 求める（→ `advanceListFocusHold`）。預かっているフォーカスは、左の列のそのパネルのフォーカスとして数える（本体が
  /// 替わっても動かず、パネルが隠れれば本体へ戻る）。預かりは、面がフォーカスを手放したとき（一覧が受け取ったときを含む）と、
  /// 本体へフォーカスを求めたとき（`focusEditor`・`reclaimSidebarFocus`）に終わる。
  private func holdListFocus(for screen: EditorScreen) {
    window?.makeFirstResponder(self)
    heldListFocus = screen
    advanceListFocusHold()
  }

  /// 預かりを一覧の状態に合わせて進める——行があれば一覧へフォーカスを求め、「無い」と決まれば本体の行き先へ移す。
  func advanceListFocusHold() {
    guard let screen = heldListFocus else { return }
    switch listState(of: screen) {
    case .rows:
      switch screen {
      case .changes: scm.requestListFocus()
      case .pullRequest: pullRequest.requestFocus()
      case .files: break
      }
    case .coming:
      break
    case .none:
      layoutSubtreeIfNeeded()
      focusEditor()
    }
  }

  /// 預かりを終える。一覧への要求が残っていれば取り消す——預かりの外で残った要求は、後で現れた一覧が、人の移した
  /// フォーカスを奪う。
  func endListFocusHold() {
    guard let screen = heldListFocus else { return }
    heldListFocus = nil
    switch screen {
    case .changes: scm.cancelListFocusRequest()
    case .pullRequest: pullRequest.cancelFocusRequest()
    case .files: break
    }
  }

  private func listState(of screen: EditorScreen) -> EditorListState {
    switch screen {
    case .changes: scm.listState
    case .pullRequest: pullRequest.listState
    case .files: .none
    }
  }

  /// 画面 `screen` の一覧が、既にフォーカスを持っている。
  private func listHasFocus(_ screen: EditorScreen) -> Bool {
    guard focusIsInSidebar, heldListFocus == nil else { return false }
    switch screen {
    case .changes: return scm.isListFocused
    case .pullRequest: return pullRequest.isListFocused
    case .files: return false
    }
  }

  /// 左の列を開閉する（上のバーの左端）。閉じるとき、左の列のパネルにあったフォーカスは本体へ移る（→ `sidebarDidChange`）。
  func toggleSidebar() {
    sidebar.setOpen(!sidebar.isOpen)
  }

  /// 骨から `mode` で開いて Files の画面を選ぶ。読めないときは beep（`open_file` と同じ理由でエラー面は持たない）し、画面を
  /// 選ばない。開けたらその行を選択して焦点を面へ——既に今の文書ならセッションは変わらないので、選択はここで明示に移す。
  func open(_ url: URL, as mode: EditorSession.OpenMode) {
    guard let group else { return }
    let document: EditorDocument
    do {
      document = try group.editor.open(url, as: mode)
    } catch {
      NSSound.beep()
      return
    }
    group.editor.selectScreen(.files)
    tree.reveal(document.url)
    focusEditor()
  }

  /// 開いている文書 `url` を今の文書にして Files の画面を選び、ツリーでその行を選択して焦点を本文へ移す（開いている文書の
  /// 列に無ければ何もしない）。
  func activate(_ url: URL) {
    guard let group, group.editor.document(at: url) != nil else { return }
    group.editor.activate(url)
    group.editor.selectScreen(.files)
    tree.reveal(url)
    focusEditor()
  }

  /// 文書 `url` を閉じる。文書が未保存なら必ず確認を sheet で出し、保存／保存しないで閉じる（保存が外部変更で失敗すれば閉じない）。
  /// 応答が返るまでにその文書が列から消えていれば何もしない。
  func requestClose(_ url: URL) {
    guard let group, let document = group.editor.document(at: url) else { return }
    guard document.isDirty, let window else {
      group.editor.close(url)
      return
    }
    let alert = UnsavedGate.alert(count: 1, language: localization.language)
    alert.beginSheetModal(for: window) { [weak self, weak document] response in
      guard let self, let group = self.group, let document,
        group.editor.document(at: url) === document,
        UnsavedGate.proceed(response, discarding: [document])
      else { return }
      group.editor.close(url)
    }
  }

  /// 行内入力を出す前に pane 自身を first responder にする——入力欄は焦点を面が持っている（窓か面自身）ときだけ取る
  /// （`inlineInputMayTakeFocus`）。続けて出したときは前の入力欄がここで焦点を手放し、新しい行が「面が持っている」と
  /// 見て取る。
  func beginNew(isDirectory: Bool) {
    window?.makeFirstResponder(self)
    tree.beginNew(isDirectory: isDirectory)
  }

  /// 入力欄が焦点を失った。別の view（端末・テキスト面・面自身）へ移ったなら取り消し＝入力の終わり。窓へ
  /// 落ちたなら人の操作ではない（容器が行を捨てた）ので、入力は生かしたまま焦点を面が預かる——行が戻れば
  /// 入力欄が取り直し、預かっている間に面が焦点を外へ明け渡せば `resignFirstResponder` から同じ判定を通る。
  func inlineInputLostFocus(generation: Int) {
    guard let window else { return }
    let responder = window.firstResponder
    if responder === window {
      window.makeFirstResponder(self)
      return
    }
    guard (responder as? NSView)?.isDescendant(of: sideHost) != true else { return }
    tree.cancelNew(generation)
  }

  /// 行内入力が終わった（状態が落ちた。Enter・Esc・取り消し・すべて折りたたむ・根を畳む・作成先を畳む・
  /// 左の列を閉じる・cd）。
  func inlineInputDidEnd() {
    reclaimSidebarFocus()
  }

  /// 左の列の中の焦点が行き場を失った（行内入力が終わった・検索パネルが隠れた）。焦点がまだ左の列（左の列の host
  /// 配下）か面自身（`beginNew` が停めた・預かっている）か窓に居れば、その場で面の行き先へ移す。別の view へ移って
  /// 終わったなら（端末をクリックして抜けた）そこに居るので触らない。
  func reclaimSidebarFocus() {
    endListFocusHold()
    guard let window else { return }
    let responder = window.firstResponder
    let strayed =
      responder === window || responder === self
      || (responder as? NSView)?.isDescendant(of: sideHost) == true
    if strayed { window.makeFirstResponder(focusTarget) }
  }

  /// 本体の行き先へフォーカスを移す。一覧のための預かりはここで終わる（本体が文字だけの表示なら行き先は面自身で、面は
  /// フォーカスを手放さない）。
  func focusEditor() {
    endListFocusHold()
    window?.makeFirstResponder(focusTarget)
  }
}
