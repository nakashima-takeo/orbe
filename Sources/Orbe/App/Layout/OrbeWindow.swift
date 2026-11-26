import AppKit

/// 主窓。焦点の入力欄が日本語入力の変換中なら、届いたキーを欄のキー処理に通さず入力欄（IME）へ直に渡す。
///
/// AppKit は keyDown を、窓の `performKeyEquivalent` とメニューに回してから `sendEvent` へ渡す。⌘ キーの受け手はその段で
/// 決まるので、ここに来るのは受け手の無かったキーだけ。SwiftUI の `.onKeyPress` は `super.sendEvent` の先で（祖先から順に）
/// 配られるため、ここで止めれば変換中のキーはどの handler にも届かない。テストが継承して振る舞いを差し替える境界なので
/// final にしない。
class OrbeWindow: NSWindow {
  /// 主窓の大きさとスタイルで作る。
  convenience init() {
    self.init(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
  }

  /// Orbe を前面に出す。主窓にキー入力を受けさせるにはアプリごと前面にするしかないので、アプリを前面にしてから窓を key にして最前面へ出す。
  func bringToFront() {
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    let accepted = super.makeFirstResponder(responder)
    let name = responder.map { "\(type(of: $0))@\(ObjectIdentifier($0).hashValue)" } ?? "nil"
    let view = responder as? NSView
    Diag509.log(
      "makeFirstResponder \(name) accepted=\(accepted) accepts=\(responder?.acceptsFirstResponder ?? false)"
        + " inWindow=\(view.map { $0.window === self } ?? false)"
        + " hidden=\(view?.isHiddenOrHasHiddenAncestor ?? false)")
    return accepted
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, let composing = IMEComposition.composingTextView(in: self) {
      composing.keyDown(with: event)
      return
    }
    super.sendEvent(event)
  }
}
