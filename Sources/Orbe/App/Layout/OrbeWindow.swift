import AppKit

/// 主窓。焦点の入力欄が日本語入力の変換中なら、届いたキーを欄のキー処理に通さず入力欄（IME）へ直に渡す。
///
/// AppKit は keyDown を、窓の `performKeyEquivalent` とメニューに回してから `sendEvent` へ渡す。⌘ キーの受け手はその段で
/// 決まるので、ここに来るのは受け手の無かったキーだけ。SwiftUI の `.onKeyPress` は `super.sendEvent` の先で（祖先から順に）
/// 配られるため、ここで止めれば変換中のキーはどの handler にも届かない。テストが `canBecomeKey` を上書きできるよう final に
/// しない。
class OrbeWindow: NSWindow {
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, let composing = IMEComposition.composingTextView(in: self) {
      composing.keyDown(with: event)
      return
    }
    super.sendEvent(event)
  }
}
