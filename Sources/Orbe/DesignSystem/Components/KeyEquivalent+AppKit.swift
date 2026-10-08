import SwiftUI

/// AppKit から実際に届くキーの文字。`.onKeyPress` の照合はこの文字で行う。
extension KeyEquivalent {
  /// ⌫。AppKit から DEL（U+007F）で届き、`KeyEquivalent.delete`（U+0008）とは一致しない。
  static let backspace = KeyEquivalent("\u{7F}")
  /// ⇧⇥。AppKit から backtab（U+0019）で届き、`KeyEquivalent.tab` とは一致しない。
  static let backtab = KeyEquivalent("\u{19}")
}
