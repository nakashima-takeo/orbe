import AppKit
import OrbeEditorCore

/// 焦点とキー。焦点の行き先は文書があればそのテキスト面、無ければ面自身。chrome キーは first responder が自分か配下の
/// ときだけ先取りする。
extension EditorPaneView {
  /// first responder が自分か配下にあるか。
  var focusIsInside: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === self || responder.isDescendant(of: self)
  }

  /// 焦点の行き先。文書があればそのテキスト面、無ければ自分。
  var focusTarget: NSView { document?.surface.responder ?? self }

  override var acceptsFirstResponder: Bool { true }

  /// 空状態の中身は静止しているので、本体のどこを押しても面自身が受ける（焦点を取る）。骨の host は
  /// 自分で受ける。
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    guard document == nil, let hit else { return hit }
    return hit.isDescendant(of: emptyHost) ? self : hit
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(focusTarget)
  }

  override func becomeFirstResponder() -> Bool {
    tab?.paneDidFocus(.editor)
    return super.becomeFirstResponder()
  }

  /// chrome キーの解決点。first responder が自分か配下のときだけ効く——隠れたタブの pane も窓に残るので、
  /// 焦点が自分か配下に無いときは素通しする。
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
      guard action == .find else { return super.performKeyEquivalent(with: event) }
      showSearch()
      return true
    }
  }

  /// 空状態で通常の打鍵を飲む（文書があれば打鍵はテキスト面に届き、ここへは来ない）。
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
