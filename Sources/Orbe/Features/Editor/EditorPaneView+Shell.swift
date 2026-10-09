import AppKit
import OrbeEditorCore

/// 骨の操作 → セッション。骨（タブ行・パンくず・ツリー・レール）の閉包を pane へ結び、pane がタブ経由でセッションに書く。
extension EditorPaneView {
  func wireShell() {
    shell.open = { [weak self] url, mode in self?.open(url, as: mode) }
    shell.activate = { [weak self] id in
      guard let self, let tab, let opened = tab.editor.tab(id) else { return }
      tab.editor.activate(id)
      tree.reveal(opened.url)
      focusEditor()
    }
    shell.pin = { [weak self] id in self?.tab?.editor.pin(id) }
    shell.requestClose = { [weak self] id in self?.requestClose(id) }
    shell.selectDiffMode = { [weak self] mode in self?.diffModes.select(mode) }
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

  func wireTree() {
    tree.onCreated = { [weak self] url in self?.open(url, as: .pinned) }
    tree.onInputEnded = { [weak self] in self?.inlineInputDidEnd() }
  }

  /// 骨から `mode` で開く。読めないときは beep（`open_file` と同じ理由でエラー面は持たない）。開けたらその行を
  /// 選択して焦点を面へ——既に焦点の文書ならセッションは変わらないので、選択はここで明示に移す。
  func open(_ url: URL, as mode: EditorSession.OpenMode) {
    guard let tab else { return }
    let document: EditorDocument
    do {
      document = try tab.editor.open(url, as: mode)
    } catch {
      NSSound.beep()
      return
    }
    tree.reveal(document.url)
    focusEditor()
  }

  /// タブの ×。その文書を使う最後のタブで、文書が未保存なら確認を sheet で出し、保存／保存しないで閉じる（保存が外部
  /// 変更で失敗すれば閉じない）。ほかのタブ（同じ文書の diff・ファイルタブ）が使っていれば確認せずに閉じる——未保存の
  /// 文書は残ったタブに出る。応答が返るまでにタブが消えていれば何もしない。
  func requestClose(_ id: EditorTab.Key) {
    guard let tab, tab.editor.tab(id) != nil else { return }
    guard let document = tab.editor.documentClosed(byClosing: id), document.isDirty, let window
    else {
      tab.editor.close(id)
      return
    }
    let alert = UnsavedGate.alert(count: 1, language: localization.language)
    alert.beginSheetModal(for: window) { [weak self, weak document] response in
      guard let self, let tab = self.tab, let document, tab.editor.tab(id) != nil,
        UnsavedGate.proceed(response, discarding: [document])
      else { return }
      tab.editor.close(id)
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
  /// サイドバーを閉じる・cd）。
  func inlineInputDidEnd() {
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

  func focusEditor() {
    window?.makeFirstResponder(focusTarget)
  }
}
