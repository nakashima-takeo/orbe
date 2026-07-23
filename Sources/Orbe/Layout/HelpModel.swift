import SwiftUI

/// ヘルプオーバーレイ（⌘H ショートカットチートシート）の描画状態。提示元（WindowController）が立て下げる。
@Observable final class HelpModel {
  /// 検索クエリ（ラベル・キー表記への部分一致）。
  var query = ""
  /// 検索欄へ focus を確定するためのトークン（描画後に `@FocusState` を立て直す）。
  private(set) var focusToken = 0
  /// 閉じ要求（esc / scrim クリック）。WindowController が dismissHelp を配線する。
  var onDismiss: () -> Void = {}

  func focus() { focusToken &+= 1 }
}
