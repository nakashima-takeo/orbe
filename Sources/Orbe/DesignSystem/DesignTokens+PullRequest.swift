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
  /// 上のバーの印（PR の札のブランチ名の間の →・「レビュー」のボタンの吹き出し）の大きさと、ボタンの印と数の間。
  static let editorPrBarGlyph: CGFloat = 12
  static let editorPrBarCountGap: CGFloat = 3
}

/// PR のコメント（スレッド・コメント追加の印）とレビューのポップアップ。半透明の面はエディター共通の換算
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
  /// 未送信の札の枠（editorCaution の α .4）。
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
  /// semibold）、書いた人（sans 11 semibold）、未送信の札（sans 10）、本文（sans 12）とインラインコード・コードブロック（mono 12）、
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
  /// レビューのポップアップ: 区分の見出し（sans 10.5 semibold）、全体へのコメント欄（sans 12.5。
  /// 1 行の高さ 20）、未送信のコメントの行（sans 12）とその場所の札（mono 11.5）、種類（sans 12。選んだ種類は semibold）。
  static let editorPrPopupHeading = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
  static let editorPrPopupField = NSFont.systemFont(ofSize: 12.5, weight: .regular)
  static let editorPrPopupFieldLine: CGFloat = 20
  static let editorPrPopupRow = NSFont.systemFont(ofSize: 12, weight: .regular)
  static let editorPrPopupRef = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
  static let editorPrPopupEvent = NSFont.systemFont(ofSize: 12, weight: .regular)
  static let editorPrPopupEventSelected = NSFont.systemFont(ofSize: 12, weight: .semibold)
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
  /// レビューのポップアップ: 区分（余白 12 12 0・段の間 6・見出しの左右 2）、全体へのコメント欄（1 行のときの高さ 30——行の
  /// 高さ 20 と上下 5）とその箱（余白 5 12——欄の上下 5 と合わせて 10・角丸 9）、
  /// 未送信のコメントの行（高さ 26・間 10・左右の余白 8・角丸 6・見せる行の数 6）とその場所の札（左右の余白 6・角丸 4）、
  /// 下端（余白 12・上の空き 12・間 10）、種類（高さ 30・左 9 右 11・角丸 8・間 6・印 13）、下端の帯（余白 9 14 10）。
  static let editorPrPopupPad: CGFloat = 12
  static let editorPrPopupSectionGap: CGFloat = 6
  static let editorPrPopupHeadingPadX: CGFloat = 2
  static let editorPrPopupFieldPadX: CGFloat = 12
  static let editorPrPopupFieldPadY: CGFloat = 5
  static let editorPrPopupFieldHeight: CGFloat = 30
  static let editorPrPopupFieldRadius: CGFloat = 9
  static let editorPrPopupRow: CGFloat = 26
  static let editorPrPopupRowGap: CGFloat = 10
  static let editorPrPopupRowPadX: CGFloat = 8
  static let editorPrPopupRowRadius: CGFloat = 6
  static let editorPrPopupRows = 6
  static let editorPrPopupRefPadX: CGFloat = 6
  static let editorPrPopupRefRadius: CGFloat = 4
  static let editorPrPopupFooterGap: CGFloat = 10
  static let editorPrPopupEvent: CGFloat = 30
  static let editorPrPopupEventPadLeading: CGFloat = 9
  static let editorPrPopupEventPadTrailing: CGFloat = 11
  static let editorPrPopupEventRadius: CGFloat = 8
  static let editorPrPopupEventGap: CGFloat = 6
  static let editorPrPopupEventGlyph: CGFloat = 13
  static let editorPrPopupBandPadX: CGFloat = 14
  static let editorPrPopupBandPadTop: CGFloat = 9
  static let editorPrPopupBandPadBottom: CGFloat = 10
}

extension Theme.Opacity {
  /// レビューのポップアップ: 全体へのコメント欄の地（`surfaceInk` の α）と、欄・種類の枠（`surfaceInk` の α）、選んだ種類の
  /// 地と枠（中立は `surfaceInk`、承認は success、変更を依頼は stateWaiting の α）、場所の札の地（accent の α）、下端の帯の地と
  /// 上の線（帯の色の α）。
  static let editorPrPopupField: Double = 0.05
  static let editorPrPopupLine: Double = 0.15
  static let editorPrPopupEventOn: Double = 0.1
  static let editorPrPopupEventOnBorder: Double = 0.3
  static let editorPrPopupApproveOn: Double = 0.16
  static let editorPrPopupApproveOnBorder: Double = 0.65
  static let editorPrPopupChangesOn: Double = 0.14
  static let editorPrPopupChangesOnBorder: Double = 0.6
  static let editorPrPopupRef: Double = 0.2
  static let editorPrPopupBand: Double = 0.1
  static let editorPrPopupBandLine: Double = 0.3
}
