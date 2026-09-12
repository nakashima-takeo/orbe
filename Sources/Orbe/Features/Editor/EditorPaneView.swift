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

/// エディター面の AppKit 側の根。地は chrome と同じ veil で塗り、焦点の文書があればそのテキスト面を
/// 全面に載せ、無ければ空状態（SwiftUI）を見せる。chrome キーは `performKeyEquivalent` で先取りし、
/// window コマンドはタブ経由で上位へ、⌘S は保存、端末のキーは消し、両面のキーと通常の打鍵は
/// テキスト面へ流す。空状態では通常の打鍵を飲む——エディター焦点中に端末へ届けない。
final class EditorPaneView: NSView {
  weak var tab: TerminalTab?
  private let host: NSHostingView<EditorFaceRoot>
  private(set) var document: EditorDocument?
  /// 地の veil。設定パレットで不透明度を変えた直後も追従する（観測して再描画）。
  var translucency: ChromeTranslucency? {
    didSet { observeTranslucency() }
  }

  override init(frame: NSRect) {
    host = NSHostingView(
      rootView: EditorFaceRoot(localization: LocalizationStore(language: .systemDefault)))
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    // SwiftUI 背景の alpha を窓まで通す（透過時に不透明ラスタで塞がない）。
    host.wantsLayer = true
    host.layer?.isOpaque = false
    host.autoresizingMask = [.width, .height]
    host.frame = bounds
    addSubview(host)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  /// 窓の環境（透過・言語）を面へ配る。
  func configure(translucency: ChromeTranslucency, localization: LocalizationStore) {
    self.translucency = translucency
    host.rootView = EditorFaceRoot(localization: localization)
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
      view.autoresizingMask = [.width, .height]
      view.frame = bounds
      addSubview(view)
    }
    host.isHidden = document != nil
    if hadFocusInside, window?.firstResponder !== focusTarget {
      window?.makeFirstResponder(focusTarget)
    }
  }

  /// first responder が自分か配下にあるか。
  private var focusIsInside: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === self || responder.isDescendant(of: self)
  }

  /// 焦点の行き先。文書があればそのテキスト面、無ければ自分。
  var focusTarget: NSView { document?.surface.responder ?? self }

  override var acceptsFirstResponder: Bool { true }

  /// 空状態の中身は静止しているので、面のどこを押しても面自身が受ける（焦点を取る）。
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return document == nil ? hit.map { _ in self } : hit
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
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

  private func saveActiveDocument() {
    guard let tab else { return }
    do {
      try tab.editor.saveActive()
    } catch {
      NSLog("[editor] save failed: \(error)")
    }
  }

  // MARK: - 地

  private func observeTranslucency() {
    guard let translucency else { return }
    withObservationTracking {
      _ = translucency.effectiveOpacity
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        self?.needsDisplay = true
        self?.observeTranslucency()
      }
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    Theme.Color.bgBase.withAlphaComponent(translucency?.effectiveOpacity ?? 1).setFill()
    dirtyRect.fill()
  }
}
