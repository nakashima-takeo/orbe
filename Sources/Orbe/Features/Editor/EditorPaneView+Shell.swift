import AppKit
import OrbeEditorCore

/// 骨の操作 → セッション。骨（タブ行・パンくず・ツリー・レール）の閉包を pane へ結び、pane が連経由でセッションに書く。
extension EditorPaneView {
  func wireShell() {
    shell.open = { [weak self] url, mode in self?.open(url, as: mode) }
    shell.activate = { [weak self] url in
      guard let self, let group, group.editor.document(at: url) != nil else { return }
      group.editor.activate(url)
      group.editor.selectScreen(.files)
      tree.reveal(url)
      focusEditor()
    }
    shell.pin = { [weak self] url in self?.group?.editor.pin(url) }
    shell.requestClose = { [weak self] url in self?.requestClose(url) }
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

  /// タブの ×。文書が未保存なら必ず確認を sheet で出し、保存／保存しないで閉じる（保存が外部変更で失敗すれば閉じない）。
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
