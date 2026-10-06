import AppKit

/// 日本語入力の変換中（入力欄に未確定の文字がある）かどうか。未確定の文字は binding に入らないので、入力欄の文字が空かどうか
/// では見分けられない。
enum IMEComposition {
  /// 窓の first responder が未確定の文字を持つ `NSTextView`（SwiftUI の field editor・TextEditor の text view）なら、それを返す。
  static func composingTextView(in window: NSWindow?) -> NSTextView? {
    guard let textView = window?.firstResponder as? NSTextView, textView.hasMarkedText() else {
      return nil
    }
    return textView
  }
}
