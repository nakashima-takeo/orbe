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

  /// キービュー循環（`Tab` / `Shift+Tab`）を封じ込める境界ビューを返す。
  /// 非 `nil` の間は、その境界の外側へ抜けるキービュー遷移を抑止する。
  var keyViewContainmentBoundary: (() -> NSView?)?

  private var makeFirstResponderDepth = 0
  private weak var outerPreviousResponder: NSResponder?

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
    if makeFirstResponderDepth == 0 {
      outerPreviousResponder = firstResponder
    }
    makeFirstResponderDepth += 1
    let changed = super.makeFirstResponder(responder)
    makeFirstResponderDepth -= 1
    if makeFirstResponderDepth == 0 {
      let previous = outerPreviousResponder
      outerPreviousResponder = nil
      if firstResponder !== previous {
        onFirstResponderChange?(firstResponder)
      }
    }
    return changed
  }

  override func selectKeyView(following view: NSView) {
    guard allowKeyViewTransition(from: view, following: true) else { return }
    super.selectKeyView(following: view)
  }

  override func selectKeyView(preceding view: NSView) {
    guard allowKeyViewTransition(from: view, following: false) else { return }
    super.selectKeyView(preceding: view)
  }

  override func selectNextKeyView(_ sender: Any?) {
    let origin = (sender as? NSView) ?? (firstResponder as? NSView)
    guard allowKeyViewTransition(from: origin, following: true) else { return }
    super.selectNextKeyView(sender)
  }

  override func selectPreviousKeyView(_ sender: Any?) {
    let origin = (sender as? NSView) ?? (firstResponder as? NSView)
    guard allowKeyViewTransition(from: origin, following: false) else { return }
    super.selectPreviousKeyView(sender)
  }

  private func allowKeyViewTransition(from origin: NSView?, following: Bool) -> Bool {
    guard let boundary = keyViewContainmentBoundary?() else { return true }
    guard let origin else { return false }
    let start: NSView
    if let textView = origin as? NSTextView, textView.isFieldEditor,
      let host = textView.delegate as? NSView
    {
      start = host
    } else {
      start = origin
    }
    let candidate = following ? start.nextValidKeyView : start.previousValidKeyView
    guard let candidate else { return false }
    guard candidate === boundary || candidate.isDescendant(of: boundary) else { return false }
    if start !== boundary && candidate === boundary { return false }
    return true
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, let composing = IMEComposition.composingTextView(in: self) {
      composing.keyDown(with: event)
      return
    }
    super.sendEvent(event)
  }
}
