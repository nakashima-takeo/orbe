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

  /// 文字だけの器（空状態・diff の一文）の中身は静止しているので、本体のどこを押しても面自身が受ける（焦点を取る）。骨の
  /// host は自分で受ける。
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    guard !emptyHost.isHidden, let hit else { return hit }
    return hit.isDescendant(of: emptyHost) ? self : hit
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(focusTarget)
  }

  /// chrome キーの解決点。first responder が自分か配下のときだけ効く——隠れたタブの pane も窓に残るので、
  /// 焦点が自分か配下に無いときは素通しする。検索パネルの中のキーは chrome キーより先に見る。chrome キーを走らせる前に焦点の
  /// 文書の変換を確定する（⌘F の種の読み取りや焦点の移動の前に、変換の状態と IME の状態を揃える。未確定の文字は既に本文に
  /// あるので、⌘S は見えている本文を保存する）。
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if focusIsInside, handleProjectSearchKey(event) { return true }
    guard focusIsInside, let action = Keybindings.chromeAction(for: event)
    else { return super.performKeyEquivalent(with: event) }
    document?.surface.commitMarkedText()
    diff.map(diffSurfaces)?.forEach { $0.commitMarkedText() }
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
      guard action == .find else { return super.performKeyEquivalent(with: event) }
      showSearch()
      return true
    }
  }

  /// 面の無い本体で通常の打鍵を飲む（面があれば打鍵はテキスト面に届き、ここへは来ない）。
  override func keyDown(with event: NSEvent) {}

  /// ⌘S。ディスクが変わっていて失敗したら「上書き／キャンセル」を sheet で出し、上書きで force 保存する。
  /// force 保存するのは同意した文書——sheet の間もセッションは動く（エージェントの `open_file` が焦点を
  /// 差し替える）ので、応答時点の焦点ではなく出した時点の文書を束ね、まだ居ることを確かめてから書く
  /// （`requestClose` と同型）。それ以外の失敗は beep（`open` と同じ理由でエラー面は持たない）。
  private func saveActiveDocument() {
    guard let tab else { return }
    do {
      try tab.editor.saveActive()
    } catch EditorDocumentError.diskChanged {
      guard let window, let target = tab.editor.activeDocument else { return }
      let alert = UnsavedGate.overwriteAlert(language: localization.language)
      alert.beginSheetModal(for: window) { [weak self, weak target] response in
        guard let self, let tab = self.tab, let target,
          tab.editor.documents.contains(where: { $0 === target }),
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
