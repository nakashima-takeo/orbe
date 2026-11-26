import AppKit

/// エディター面の中の確認（破棄の確認）のトークン。幕の色は `Theme.Color.editorConfirmVeil`。
extension Theme.Typography {
  /// 題（sans 14 semibold・行の高さ 1.45）と本文（sans 12.5・行の高さ 1.6）。
  static let editorConfirmTitle = NSFont.systemFont(ofSize: 14, weight: .semibold)
  static let editorConfirmTitleLineHeight: CGFloat = 1.45
  static let editorConfirmMessage = NSFont.systemFont(ofSize: 12.5, weight: .regular)
  static let editorConfirmMessageLineHeight: CGFloat = 1.6
}

extension Theme.Layout {
  /// ダイアログ——幅・面の上端からの位置・角丸・上と左右と下の余白・題と本文の間・本文とボタン列の間・ボタンの間・面の
  /// 左右に残す空き（面が狭いとき）。
  static let editorConfirmWidth: CGFloat = 430
  static let editorConfirmTop: CGFloat = 150
  static let editorConfirmRadius: CGFloat = 14
  static let editorConfirmPadTop: CGFloat = 18
  static let editorConfirmPadX: CGFloat = 18
  static let editorConfirmPadBottom: CGFloat = 14
  static let editorConfirmMessageGap: CGFloat = 6
  static let editorConfirmButtonsGap: CGFloat = 16
  static let editorConfirmButtonGap: CGFloat = 8
  static let editorConfirmInset: CGFloat = 12
}
