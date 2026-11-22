import AppKit

extension Theme.Typography {
  /// PR のパネル。頭の題（sans 13）・作者とブランチの段（mono 10.5）・帯（sans 11）・説明の本文（sans 11.5）・
  /// コミットの短い sha とフォルダの「済/全」と「N/M 確認済み」（mono 10.5）・作成の入口の下の 1 行（mono 11）。
  /// 行の見出し・ファイル名・ディレクトリ・コミットの題・バッジは、ソース管理と同じ字を使う。
  static let editorPrTitle = NSFont.systemFont(ofSize: 13, weight: .regular)
  static let editorPrMeta = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
  static let editorPrBand = NSFont.systemFont(ofSize: 11, weight: .regular)
  static let editorPrDescription = NSFont.systemFont(ofSize: 11.5, weight: .regular)
  static let editorPrCount = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
  static let editorPrCreateMeta = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// 頭の題の行の高さ（倍率）と、説明の本文の行の高さ（倍率）。
  static let editorPrTitleLineHeight: CGFloat = 1.4
  static let editorPrDescriptionLineHeight: CGFloat = 1.6
}

extension Theme.Layout {
  /// PR のパネル。確認済みのチェック・字下げの線の幅とその後の空き・「ツリー表示」「リスト表示」の印の枠・帯の
  /// 1 行のときの高さ（折り返せば伸びる）・説明の本文の行の数。
  static let editorPrCheckbox: CGFloat = 14
  static let editorPrGuide: CGFloat = 8
  static let editorPrGuideGap: CGFloat = 6
  static let editorPrViewToggle: CGFloat = 18
  static let editorPrBand: CGFloat = 24
  static let editorPrDescriptionLines = 3
}

/// PR のコメント（スレッド・コメント追加の印・パネル下端のレビュー区画）。半透明の面はエディター共通の換算
/// （`EditorStyle.sunk` / `fill` / `hairline`）に揃える。
extension Theme.Color {
  /// スレッドのある diff の行の地（accent の α .14）。
  static let editorPrThreadRow = accentPrimary.withAlphaComponent(0.14)
  /// スレッドの箱の地（パネル地の α .85。ブラーなしの半透明塗り）・枠（accent の α .35）・影（影色の α .35）。
  static let editorPrThreadGround = prDynAB(light: (0xffffff, 0.85), dark: (0x1e1a26, 0.85))
  static let editorPrThreadBorder = accentPrimary.withAlphaComponent(0.35)
  static let editorPrThreadShadow = prDynAB(light: (0x5a4696, 0.35), dark: (0x000000, 0.35))
  /// スレッドの頭の帯（accent の α .08）。
  static let editorPrThreadHead = accentPrimary.withAlphaComponent(0.08)
  /// インラインコードの地（accent の α .12）と、コメント追加の印のホバーの地（accent の α .16）。
  static let editorPrInlineCode = accentPrimary.withAlphaComponent(0.12)
  static let editorPrMarkHover = accentPrimary.withAlphaComponent(0.16)
  /// 返信欄の焦点のある枠（accent の α .55）と、その中の選択の地。
  static let editorPrFieldFocus = accentPrimary.withAlphaComponent(0.55)
  static let editorPrFieldSelection = accentPrimary.withAlphaComponent(0.35)
  static let editorPrFieldSelectionInactive = accentPrimary.withAlphaComponent(0.18)
  /// 保留中の札の枠（editorCaution の α .4）。
  static let editorPrPendingBorder = editorCaution.withAlphaComponent(0.4)

  /// `DesignTokens.swift` の private ヘルパは参照不可なので自前で持つ。外観ごとに色と α が違う色。
  private static func prDynAB(light: (Int, CGFloat), dark: (Int, CGFloat)) -> NSColor {
    NSColor(name: nil) { ap in
      let (hex, alpha) = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
  }
}

extension Theme.Typography {
  /// スレッドの頭・コメントのメタの行・返信の行の下の失敗の文（sans 11）、頭の状態（mono 10.5）、アバターの頭文字（sans 10
  /// semibold）、書いた人（sans 11 semibold）、保留中の札（sans 10）、本文（sans 12）とインラインコード・コードブロック（mono 12）、
  /// 返信の行のボタン（sans 11.5。「レビューに追加」は semibold）。
  static let editorPrThreadHead = NSFont.systemFont(ofSize: 11, weight: .regular)
  static let editorPrThreadStatus = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
  static let editorPrThreadAvatar = NSFont.systemFont(ofSize: 10, weight: .semibold)
  static let editorPrThreadAuthor = NSFont.systemFont(ofSize: 11, weight: .semibold)
  static let editorPrThreadBadge = NSFont.systemFont(ofSize: 10, weight: .regular)
  static let editorPrThreadBody = NSFont.systemFont(ofSize: 12, weight: .regular)
  static let editorPrThreadBodyStrong = NSFont.systemFont(ofSize: 12, weight: .semibold)
  static let editorPrThreadCode = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  static let editorPrThreadButton = NSFont.systemFont(ofSize: 11.5, weight: .regular)
  static let editorPrThreadPrimaryButton = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
  /// 本文の行の高さ（倍率）。
  static let editorPrThreadBodyLineHeight: CGFloat = 1.6
  /// 返信欄の字（sans 12）と、その 1 行の高さ（pt）。
  static let editorPrReplyField = NSFont.systemFont(ofSize: 12, weight: .regular)
  static let editorPrReplyFieldLine: CGFloat = 16
  /// パネルの下端の区画: 「レビュー」と 3 択（sans 11）、保留中の件数とファイルの行のコメント数（mono 10.5）、送信ボタン
  /// （sans 12 semibold）とその「⌘↵」（mono 10.5）。
  static let editorPrReviewLabel = NSFont.systemFont(ofSize: 11, weight: .regular)
  static let editorPrReviewSelected = NSFont.systemFont(ofSize: 11, weight: .semibold)
  static let editorPrReviewSubmit = NSFont.systemFont(ofSize: 12, weight: .semibold)
}

extension Theme.Layout {
  /// スレッドの箱（外余白 上 4・右 16・下 8・左 0〔左は本文の区画の左端〕・角丸 6・枠 1・影 0 10 30）と頭
  /// （高さ 26・左右の余白 12・間 8）、状態の点 6、コメントの列（余白 10 12・件の間 12）、アバター 20 と中身の間 10、
  /// メタの行の間 6、返信の行（高さ 26・下の余白 10・間 8）、ボタンの左右の余白 10、返信欄の左右の余白 8。
  static let editorPrThreadTop: CGFloat = 4
  static let editorPrThreadRight: CGFloat = 16
  static let editorPrThreadBottom: CGFloat = 8
  static let editorPrThreadRadius: CGFloat = 6
  static let editorPrThreadShadowY: CGFloat = 10
  static let editorPrThreadShadowBlur: CGFloat = 30
  static let editorPrThreadHead: CGFloat = 26
  static let editorPrThreadPadX: CGFloat = 12
  static let editorPrThreadGap: CGFloat = 8
  static let editorPrThreadDot: CGFloat = 6
  static let editorPrThreadListPadY: CGFloat = 10
  static let editorPrThreadCommentGap: CGFloat = 12
  static let editorPrThreadAvatar: CGFloat = 20
  static let editorPrThreadAvatarGap: CGFloat = 10
  static let editorPrThreadMetaGap: CGFloat = 6
  static let editorPrThreadControl: CGFloat = 26
  static let editorPrThreadButtonPadX: CGFloat = 10
  static let editorPrThreadFieldPadX: CGFloat = 8
  /// 本文の段の間・字下げ（箇条書き 16）・引用の線 2 とその後の空き 8・コードブロックの余白 8 と角丸 4・インラインコードの
  /// 左右の余白 4 と角丸 3。
  static let editorPrBodyBlockGap: CGFloat = 6
  static let editorPrBodyListIndent: CGFloat = 16
  /// 番号付きの箇条書きの番号（右揃え）と本文の間。
  static let editorPrBodyListMarkerGap: CGFloat = 6
  static let editorPrBodyQuoteBar: CGFloat = 2
  static let editorPrBodyQuoteGap: CGFloat = 8
  static let editorPrBodyCodePad: CGFloat = 8
  static let editorPrBodyCodeRadius: CGFloat = 4
  static let editorPrInlineCodePad: CGFloat = 4
  static let editorPrInlineCodeRadius: CGFloat = 3
  /// コメント追加の印（18×18・角丸 3・行の右端から 8・中の ＋ 11）。
  static let editorPrMark: CGFloat = 18
  static let editorPrMarkInset: CGFloat = 8
  static let editorPrMarkGlyph: CGFloat = 11
  /// パネルの下端の区画（余白 10 12 12・段の間 8）、3 択（外枠の余白 2・各 22）、送信ボタン 26。
  static let editorPrReviewPadTop: CGFloat = 10
  static let editorPrReviewPadX: CGFloat = 12
  static let editorPrReviewPadBottom: CGFloat = 12
  static let editorPrReviewGap: CGFloat = 8
  static let editorPrReviewSegment: CGFloat = 22
  static let editorPrReviewSegmentPad: CGFloat = 2
  static let editorPrReviewControl: CGFloat = 26
}
