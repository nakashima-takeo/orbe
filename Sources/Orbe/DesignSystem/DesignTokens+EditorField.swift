import AppKit

/// エディター面の 1 行の入力欄の枠（`EditorFieldFrame`）のトークン。
extension Theme.Layout {
  /// 入力欄の枠——角丸・左右の余白・中の部品の間・虫眼鏡の大きさ・フォーカスの枠の太さ。
  static let editorFieldRadius: CGFloat = 7
  static let editorFieldPadLeading: CGFloat = 8
  static let editorFieldPadTrailing: CGFloat = 4
  static let editorFieldGap: CGFloat = 6
  static let editorFieldGlyph: CGFloat = 14
  static let editorFieldFocusStroke: CGFloat = 1.5
}

extension Theme.Opacity {
  /// 入力欄の枠の地（`surfaceInk` の α）と、フォーカスがある間の枠（`accent.primary` の α）。
  static let editorFieldFill: Double = 0.055
  static let editorFieldFocus: Double = 0.55
}
