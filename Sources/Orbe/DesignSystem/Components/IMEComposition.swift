import AppKit

/// chrome の入力欄で、日本語入力の変換中（field editor に未確定の文字がある）かどうか。未確定の文字は
/// binding に入らないので、入力欄の文字が空かどうかでは見分けられない。パレットの入力欄がキーを握る前に
/// これを見て、変換中のキーを変換に使わせる。
enum IMEComposition {
  /// キーを受けた時点で、そのキーが届いた窓の first responder を直接確かめる（`imePlaceholder` の監視と同じ
  /// 情報源）。
  static var isActive: Bool {
    (NSApp.currentEvent?.window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
  }
}
