import AppKit

extension Theme.Typography {
  /// PR のパネル（見本 PrReviewPanel の値）。頭の題（sans 13）・作者とブランチの段（mono 10.5）・帯（sans 11）・説明の本文
  /// （sans 11.5）・コミットの短い sha とフォルダの「済/全」と「N/M 確認済み」（mono 10.5）。作成の入口の下の 1 行（mono 11）は
  /// 見本 PrListPanel の値。行の見出し・ファイル名・ディレクトリ・コミットの題・バッジは、ソース管理と同じ字を使う。
  static let editorPrTitle = NSFont.systemFont(ofSize: 13, weight: .regular)
  static let editorPrMeta = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
  static let editorPrBand = NSFont.systemFont(ofSize: 11, weight: .regular)
  static let editorPrDescription = NSFont.systemFont(ofSize: 11.5, weight: .regular)
  static let editorPrCount = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
  static let editorPrCreateMeta = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// タブ行の「確認済みにする」（sans 11.5。見本 DiffTabs）。
  static let editorPrMarkViewed = NSFont.systemFont(ofSize: 11.5, weight: .regular)
  /// 頭の題の行の高さ（倍率）と、説明の本文の行の高さ（倍率）。
  static let editorPrTitleLineHeight: CGFloat = 1.4
  static let editorPrDescriptionLineHeight: CGFloat = 1.6
}

extension Theme.Layout {
  /// PR のパネル（見本 PrReviewPanel の値）。確認済みのチェック・字下げの線の幅とその後の空き・「ツリー表示」「リスト表示」の
  /// 印の枠・帯の 1 行のときの高さ（折り返せば伸びる）・説明の本文の行の数。
  static let editorPrCheckbox: CGFloat = 14
  static let editorPrGuide: CGFloat = 8
  static let editorPrGuideGap: CGFloat = 6
  static let editorPrViewToggle: CGFloat = 18
  static let editorPrBand: CGFloat = 24
  static let editorPrDescriptionLines = 3
}
