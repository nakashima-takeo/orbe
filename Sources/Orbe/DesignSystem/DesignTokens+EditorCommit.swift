import AppKit

/// Changes の画面の上のバーの部品（ブランチ名の札・同期）と、コミットのポップアップ（メッセージ欄・分割ボタン・赤い行・
/// ▾ のメニュー）のトークン。
extension Theme.Typography {
  /// 同期の先行・遅れの数（mono 11.5）。
  static let editorSyncCount = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
  /// 行の先頭の記号「❯」（mono 13 semibold）とメッセージ欄（sans 12.5）。
  static let editorCommitPrompt = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
  static let editorCommitMessage = NSFont.systemFont(ofSize: 12.5, weight: .regular)
}

extension Theme.Layout {
  /// ブランチ名の札と同期の印の大きさ・同期の矢印と数の間。
  static let editorBranchGlyph: CGFloat = 12
  static let editorSyncArrowGap: CGFloat = 1
  /// ポップアップの行——上下と右の余白・左の余白・部品の間。メッセージ欄の 1 行のときの高さ（記号と分割ボタンも同じ高さ）と、
  /// 複数行のときの字の 1 行あたりの高さ。
  static let editorCommitRowPad: CGFloat = 8
  static let editorCommitRowPadLeading: CGFloat = 14
  static let editorCommitRowGap: CGFloat = 9
  static let editorCommitMessage: CGFloat = 30
  static let editorCommitMessageLine: CGFloat = 20
  /// 分割ボタン——左の「コミット」の左右の余白・右の ▾ の左右の余白。
  static let editorCommitButtonPadLeading: CGFloat = 12
  static let editorCommitButtonPadTrailing: CGFloat = 10
  static let editorCommitCaretPadX: CGFloat = 7
  /// 赤い行——印と文の間・左右の余白・上下の余白・印の上の空き。
  static let editorCommitFailureGap: CGFloat = 8
  static let editorCommitFailurePadX: CGFloat = 14
  static let editorCommitFailurePadTop: CGFloat = 9
  static let editorCommitFailurePadBottom: CGFloat = 10
  static let editorCommitFailureGlyphTop: CGFloat = 2
  /// ▾ のメニュー——ポップアップの地との間・幅・角丸。
  static let editorCommitMenuGap: CGFloat = 6
  static let editorCommitMenuWidth: CGFloat = 250
  static let editorCommitMenuRadius: CGFloat = 10
}

extension Theme.Opacity {
  /// 分割ボタンの区切り（押せる姿は黒の α、押せない姿は `surfaceInk` の α）と、押せない姿の地（`surfaceInk` の α）。
  static let editorCommitDivider: Double = 0.22
  static let editorCommitNeutralDivider: Double = 0.12
  static let editorCommitNeutral: Double = 0.09
  /// 赤い行の地と上の線（danger の α）。
  static let editorCommitFailureGround: Double = 0.1
  static let editorCommitFailureLine: Double = 0.3
}
