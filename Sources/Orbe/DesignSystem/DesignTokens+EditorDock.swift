import AppKit

/// エディター面の上のバーの右下の置き場（ポップアップ・札）のトークン。
extension Theme.Typography {
  /// 札の文（sans 12）と、その行の高さ（倍率）。
  static let editorDockCard = NSFont.systemFont(ofSize: 12, weight: .regular)
  static let editorDockCardLineHeight: CGFloat = 1.55
  /// 実行中の札の進捗の行（mono 11）。
  static let editorRunningProgress = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}

extension Theme.Layout {
  /// 置き場——バーの下端からの空き・面の右端からの空き・並ぶ物の間・幅の上限（失敗の札の最大幅）・面の下端に残す余白。
  static let editorDockTop: CGFloat = 6
  static let editorDockTrailing: CGFloat = 12
  static let editorDockGap: CGFloat = 6
  static let editorDockWidth: CGFloat = 620
  static let editorDockBottom: CGFloat = 12
  /// ポップアップの地——幅・角丸・色の付いた上側の高さ・外の光の広がり（影の radius。CSS の blur 44 の半分）。
  static let editorPopupWidth: CGFloat = 520
  static let editorPopupRadius: CGFloat = 14
  static let editorPopupTintHeight: CGFloat = 132
  static let editorPopupGlow: CGFloat = 22
  /// 札の地——角丸・最小の高さ。札の文の左右と上下の余白、× の枠と印の大きさ・ホバーの地の角丸・枠の周りの余白（1 行の札
  /// の高さの中央に来る）。
  static let editorCardRadius: CGFloat = 10
  static let editorCardMinHeight: CGFloat = 34
  static let editorCardPadX: CGFloat = 14
  static let editorCardPadY: CGFloat = 8
  static let editorCardClose: CGFloat = 20
  static let editorCardCloseGlyph: CGFloat = 10
  static let editorCardCloseRadius: CGFloat = 4
  static let editorCardClosePad: CGFloat = 7
  /// 実行中の札——左右の余白・部品の間・進捗の行の幅の上限。
  static let editorRunningPadLeading: CGFloat = 14
  static let editorRunningPadTrailing: CGFloat = 6
  static let editorRunningGap: CGFloat = 10
  static let editorRunningProgressWidth: CGFloat = 420
}

extension Theme.Opacity {
  /// ポップアップの地に渡す色の、縁の線・上側のグラデーションの始まり・外の光の α。
  static let editorPopupTintBorder: Double = 0.5
  static let editorPopupTintTop: Double = 0.17
  static let editorPopupTintGlow: Double = 0.13
  /// 失敗の札の縁の線（danger の α）と、札の × のホバーの地（`surfaceInk` の α）。
  static let editorFailureBorder: Double = 0.5
  static let editorCardCloseHover: Double = 0.10
}
