import AppKit

/// 主窓。焦点の入力欄が日本語入力の変換中なら、届いたキーを欄のキー処理に通さず入力欄（IME）へ直に渡す。
///
/// AppKit は keyDown を、窓の `performKeyEquivalent` とメニューに回してから `sendEvent` へ渡す。⌘ キーの受け手はその段で
/// 決まるので、ここに来るのは受け手の無かったキーだけ。SwiftUI の `.onKeyPress` は `super.sendEvent` の先で（祖先から順に）
/// 配られるため、ここで止めれば変換中のキーはどの handler にも届かない。テストが継承して振る舞いを差し替える境界なので
/// final にしない。
class OrbeWindow: NSWindow {
  /// `makeFirstResponder(_:)` 成立後に実 first responder が変化したときの通知。
  /// 再帰を防ぐため、受け手は見た目と復帰記憶の更新のみを行い `makeFirstResponder` を呼ばない。
  var onFirstResponderChange: ((NSResponder?) -> Void)?

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

  @discardableResult
  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    let previous = firstResponder
    let changed = super.makeFirstResponder(responder)
    if changed, firstResponder !== previous {
      onFirstResponderChange?(firstResponder)
    }
    return changed
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, let composing = IMEComposition.composingTextView(in: self) {
      composing.keyDown(with: event)
      return
    }
    super.sendEvent(event)
  }
}
