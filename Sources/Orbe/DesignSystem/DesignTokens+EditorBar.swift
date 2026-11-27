import AppKit

/// エディター面の上のバーの共通の部品（中ほどの札・アイコンのボタン・右端の主な操作のボタン）と、Files の画面のファイル内
/// 検索の欄のトークン。
extension Theme.Typography {
  /// 中ほどの札（mono 12）と、地つきの変種（同期。sans 12）。右端の主な操作のボタン（sans 12 semibold）。
  static let editorBarChip = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  static let editorBarChipFilled = NSFont.systemFont(ofSize: 12, weight: .regular)
  static let editorBarAction = NSFont.systemFont(ofSize: 12, weight: .semibold)
  /// ファイル内検索の欄の入力（mono 12）と件数（mono 11）。
  static let editorBarFind = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  static let editorBarFindCount = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}

extension Theme.Layout {
  /// 中ほどの札——高さ・角丸・左右の余白と中の間（素の姿）・左右の余白と中の間（地つきの変種）。
  static let editorBarChip: CGFloat = 26
  static let editorBarChipRadius: CGFloat = 7
  static let editorBarChipPadX: CGFloat = 8
  static let editorBarChipGap: CGFloat = 6
  static let editorBarChipFilledPadX: CGFloat = 9
  static let editorBarChipFilledGap: CGFloat = 7
  /// 中ほどの札の名前（ブランチ名）の読める下限の字数（先頭のこの字数と「…」より狭くならない）。
  static let editorBarChipReadablePrefix = 4
  /// アイコンのボタン（26 角）——大きさ・角丸・印の大きさ。
  static let editorBarIconButton: CGFloat = 26
  static let editorBarIconButtonRadius: CGFloat = 7
  static let editorBarIconGlyph: CGFloat = 14
  /// 右端の主な操作のボタン——高さ・角丸・中の間・左右の余白・左の余白（案内との間）。
  static let editorBarAction: CGFloat = 26
  static let editorBarActionRadius: CGFloat = 7
  static let editorBarActionGap: CGFloat = 7
  static let editorBarActionPadLeading: CGFloat = 11
  static let editorBarActionPadTrailing: CGFloat = 6
  static let editorBarActionLead: CGFloat = 12
  /// ファイル内検索の欄——高さ・本来の幅・最小の幅（上のバーが狭いと、本来の幅からここまで縮む）・件数の右の余白。
  static let editorBarFind: CGFloat = 26
  static let editorBarFindWidth: CGFloat = 290
  static let editorBarFindMinWidth: CGFloat = 180
  static let editorBarFindCountTrailing: CGFloat = 6
}

extension Theme.Opacity {
  /// 中ほどの札の地つきの変種の地と、アイコンのボタンの押された姿の地（`surfaceInk` の α）。
  static let editorBarChipFill: Double = 0.08
  static let editorBarIconPressed: Double = 0.08
  /// 右端の主な操作のボタンの地・開いている間の地・枠（accent の α）。
  static let editorBarActionFill: Double = 0.24
  static let editorBarActionOpen: Double = 0.36
  static let editorBarActionBorder: Double = 0.6
}
