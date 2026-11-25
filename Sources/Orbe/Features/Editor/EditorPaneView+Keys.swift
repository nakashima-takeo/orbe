import AppKit
import OrbeEditorCore

/// 焦点とキー。焦点の行き先は本体の面（文書の面・diff の面——並列なら最後に焦点のあった側）、面が無ければ pane 自身。
/// chrome キーは first responder が自分か配下のときだけ先取りする。
extension EditorPaneView {
  /// first responder が自分か配下にあるか。
  var focusIsInside: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === self || responder.isDescendant(of: self)
  }

  /// フォーカスが本体にあるか——面の中にあって、左の列にも一覧の器にも無い。本体の面を置き換えるとき、この間だけ新しい
  /// 行き先へフォーカスを移す。
  var focusIsInBody: Bool { focusIsInside && !focusIsInSidebar && !focusIsInItemList }

  /// 焦点の行き先。文書の本体ならそのテキスト面、diff の本体なら見せている面（並列なら最後に焦点のあった側、既定は右）、
  /// 面が無ければ自分。
  var focusTarget: NSView {
    switch body {
    case .document(let document): return document.surface.responder
    case .diff(let diff):
      let surfaces = diffSurfaces(diff)
      let surface = diffFocusesLeft ? surfaces.first : surfaces.last
      return surface?.responder ?? self
    case .empty: return self
    }
  }

  override var acceptsFirstResponder: Bool { true }

  /// 文字だけの器の中身は静止しているので、本体のどこを押しても面自身が受ける（焦点を取る）。ボタンを出しうる表示（PR の
  /// 画面の空・使えないときの表示）だけは器が受け、ボタンの外の押下で面が焦点を取る。骨の host は自分で受ける。
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    guard !faceHost.isHidden, let hit, hit.isDescendant(of: faceHost) else { return hit }
    return faceHost.rootView.content == .empty(.pullRequest) ? hit : self
  }

  override func mouseDown(with event: NSEvent) {
    focusEditor()
  }

  /// chrome キーの解決点。first responder が自分か配下のときだけ効く——隠れた連の pane も窓に残るので、
  /// 焦点が自分か配下に無いときは素通しする。エディターのキーは ⌘S（保存）・⌘⇧B（左の列の開閉）・⌘P（上のバーの今の項目の
  /// ボタンを押すのと同じ。ボタンが出ていなければ何もしない）。検索パネル・ソース管理パネル・PR のパネルの中のキーは chrome キーより先に見る。
  /// chrome キーを走らせる前に焦点の文書の変換を確定する（⌘F の種の読み取りや焦点の移動の前に、変換の状態と IME の状態を
  /// 揃える。未確定の文字は既に本文にあるので、⌘S は見えている本文を保存する）。
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if focusIsInside,
      handleProjectSearchKey(event) || handleSourceControlKey(event)
        || handlePullRequestKey(event)
    {
      return true
    }
    guard focusIsInside, let action = Keybindings.chromeAction(for: event)
    else { return super.performKeyEquivalent(with: event) }
    document?.surface.commitMarkedText()
    diff.map(diffSurfaces)?.forEach { $0.commitMarkedText() }
    switch action.owner {
    case .window:
      if let command = action.windowCommand { group?.requestWindowCommand(command) }
      return true
    case .editor:
      switch action {
      case .toggleEditorSidebar: toggleSidebar()
      case .toggleEditorItemList: toggleItemList()
      default: saveEdited()
      }
      return true
    case .terminal:
      return true
    case .eachFace:
      guard action == .find else { return super.performKeyEquivalent(with: event) }
      showSearch()
      return true
    }
  }

  /// 面の無い本体で通常の打鍵を飲む（面があれば打鍵はテキスト面に届き、ここへは来ない）。
  override func keyDown(with event: NSEvent) {}

  /// ⌘S。本体で編集している文書を保存する。ディスクが変わっていて失敗したら「上書き／キャンセル」を sheet で出し、上書きで
  /// force 保存する。force 保存するのは同意した文書——sheet の間もセッションは動く（エージェントの `open_file` が本体を
  /// 差し替える）ので、応答時点の本体ではなく出した時点の文書を束ね、まだ居ることを確かめてから書く
  /// （`requestClose` と同型）。それ以外の失敗は beep（`open` と同じ理由でエラー面は持たない）。
  private func saveEdited() {
    guard let group else { return }
    do {
      try group.editor.saveEdited()
    } catch EditorDocumentError.diskChanged {
      guard let window, let target = group.editor.editedDocument else { return }
      let alert = UnsavedGate.overwriteAlert(language: localization.language)
      alert.beginSheetModal(for: window) { [weak self, weak target] response in
        guard let self, let group = self.group, let target,
          group.editor.holds(target),
          UnsavedGate.shouldOverwrite(response)
        else { return }
        do {
          try target.save(force: true)
        } catch {
          NSSound.beep()
          NSLog("[editor] forced save failed: \(error)")
        }
      }
    } catch {
      NSSound.beep()
      NSLog("[editor] save failed: \(error)")
    }
  }
}
