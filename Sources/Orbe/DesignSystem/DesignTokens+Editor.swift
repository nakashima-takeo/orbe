import AppKit
import SwiftUI

/// エディター面（⌘E）のトークンが所有する自己完結ファイル（`DesignTokens+Glass.swift` と同型）。
extension Theme.Color {
  /// 沈んだ塗り（アバターの地など）。
  static let editorGhost = editorDyn(light: 0xd9d3e6, dark: 0x3d3752)
  /// エディター面のアイコン・kbd の文字。dark / light とも kbKeyText と偶然同値だが役割が違うので別トークン。
  static let editorIcon = editorDyn(light: 0x766e8d, dark: 0xa99fb8)
  /// エディター面の 2 段目の文字——コードの素文字・ファイル名。
  /// dark / light とも statusText と偶然同値だが役割が違うので別トークン。
  static let editorText = editorDyn(light: 0x4d4368, dark: 0xcdc7e2)
  /// 三次の文字。`textTertiary` は `textMuted` の別名なので別値を持つ。
  static let editorTertiary = editorDyn(light: 0xaca4bd, dark: 0x6d667a)
  /// 説明文の段——PR の説明（editorText と textMuted の間）。
  static let editorProse = editorDyn(light: 0x6d647f, dark: 0xa9a2b5)
  /// 注意の黄——検索の一致の地・PR のパネルの手元とのずれと未送信の印。
  /// dark は conflict と偶然同値だが light が違い、git 競合でもない。
  static let editorCaution = editorDyn(light: 0xa07f0c, dark: 0xe2cd6d)
  /// danger の地の上の字（大きい字のボタンの「破棄」）。
  static let editorOnDanger = editorDyn(light: 0xffffff, dark: 0xffffff)
  /// git の変化の種類の色（追加＝青・削除＝オレンジ・変更＝黄）。赤と緑を見分けにくい人でも区別できるよう、成否の
  /// success / danger（端末の緑・赤）とは別に持つ。diffModified は editorCaution と値だけ同じ独立トークン。
  static let diffAdded = editorDyn(light: 0x0969da, dark: 0x5ea8ff)
  static let diffRemoved = editorDyn(light: 0xbc4c00, dark: 0xf0883e)
  static let diffModified = editorDyn(light: 0xa07f0c, dark: 0xe2cd6d)
  /// diff の追加・削除の行の地（diff.added / diff.removed の α `editorDiffRow`）。
  static let editorDiffAddedRow = diffAdded.withAlphaComponent(Theme.Opacity.editorDiffRow)
  static let editorDiffRemovedRow = diffRemoved.withAlphaComponent(Theme.Opacity.editorDiffRow)
  /// 上のバーの画面の切り替えの溝の地と、溝・選んだ項目に落とす影の色（見本の `--sunk`・`--inset`）。
  static let editorBarGroove = editorDynAB(light: (0x3a3151, 0.05), dark: (0x08060c, 0.32))
  static let editorBarInset = editorDynAB(light: (0x3a3151, 0.14), dark: (0x000000, 0.4))
  /// 面の中の確認の幕（見本の `.veil`）。
  static let editorConfirmVeil = editorDynAB(light: (0x3a3151, 0.2), dark: (0x000000, 0.42))
  /// 種別チップの色相。チップの文字色と、その α .16 の地に使う。
  static let editorHueOrange = editorDyn(light: 0xbf5f2a, dark: 0xd98a5f)
  static let editorHueBlue = editorDyn(light: 0x3f6fd6, dark: 0x85adff)
  static let editorHueYellow = editorDyn(light: 0xa07f0c, dark: 0xe2cd6d)
  static let editorHueSky = editorDyn(light: 0x2a7bbd, dark: 0x9cdcfe)
  static let editorHueViolet = editorDyn(light: 0x645b9c, dark: 0x8a82b8)
  static let editorHueCyan = editorDyn(light: 0x178c94, dark: 0x4bbfc7)
  static let editorHueRed = editorDyn(light: 0xd13d3d, dark: 0xd16969)
  static let editorHueGreen = editorDyn(light: 0x2f9a52, dark: 0x82d894)
  static let editorHueTeal = editorDyn(light: 0x1a8a76, dark: 0x7fd0c3)
  /// 行番号。textMuted の α .55。
  static let editorLineNumber = editorDynA(light: 0x8d85a3, dark: 0x8b8397, alpha: 0.55)
  /// 見せる空白の丸点。textMuted の α .55（editorLineNumber と値だけ同じ独立トークン）。
  static let editorWhitespace = editorDynA(light: 0x8d85a3, dark: 0x8b8397, alpha: 0.55)

  // 選択・俯瞰・強調（VS Code Dark Modern / Light Modern の値。上書きの無いものは VS Code のレジストリの既定）。
  /// 本文の選択の地（editor.selectionBackground）。ミニマップの選択（minimap.selectionHighlight）も同じ色。
  static let editorSelection = editorDyn(light: 0xadd6ff, dark: 0x264f78)
  /// 焦点の無い面の選択の地（editor.inactiveSelectionBackground）。
  static let editorSelectionInactive = editorDyn(light: 0xe5ebf1, dark: 0x3a3d41)
  /// 検索の一致の地（editor.findMatchHighlightBackground）。ミニマップの一致も同じ色。
  static let editorFindMatch = editorDynA(light: 0xea5c00, dark: 0xea5c00, alpha: 0.33)
  /// 現在の一致の地（editor.findMatchBackground）。不透明で選択の地の上に描く。
  static let editorFindMatchCurrent = editorDyn(light: 0xa8ac94, dark: 0x9e6a03)
  /// 現在の一致の行全体の地（editor.rangeHighlightBackground）。
  static let editorFindLine = editorDynAB(light: (0xfdff00, 0.2), dark: (0xffffff, 0.043))
  /// 選択文字列の他の出現の地（editor.selectionHighlightBackground）。面に焦点が無いときは α を半分にする。ミニマップの
  /// 語の出現も同じ色。
  static let editorSelectionOccurrence = editorDynAB(light: (0xadd6ff, 0.5), dark: (0xadd6ff, 0.15))
  /// キャレットの語の出現の地（editor.wordHighlightTextBackground）。
  static let editorWordOccurrence = editorDynAB(light: (0x575757, 0.25), dark: (0x575757, 0.72))
  /// ミニマップの帯（minimapSlider.background / hoverBackground / activeBackground）。
  static let editorMinimapSlider = editorDynAB(light: (0x646464, 0.2), dark: (0x797979, 0.2))
  static let editorMinimapSliderHover = editorDynAB(light: (0x646464, 0.35), dark: (0x646464, 0.35))
  static let editorMinimapSliderActive = editorDynAB(light: (0x000000, 0.3), dark: (0xbfbfbf, 0.2))
  /// スクロールバーのつまみ（scrollbarSlider.background / hoverBackground / activeBackground）。
  static let editorScrollbarSlider = editorDynAB(light: (0x646464, 0.4), dark: (0x797979, 0.4))
  static let editorScrollbarSliderHover = editorDynAB(light: (0x646464, 0.7), dark: (0x646464, 0.7))
  static let editorScrollbarSliderActive = editorDynAB(
    light: (0x000000, 0.6), dark: (0xbfbfbf, 0.4))
  /// スクロールバーの印——検索の一致（editorOverviewRuler.findMatchForeground）と語の出現
  /// （editorOverviewRuler.wordHighlightTextForeground）。
  static let editorRulerFind = editorDynA(light: 0xd18616, dark: 0xd18616, alpha: 0.49)
  static let editorRulerOccurrence = editorDynA(light: 0xa0a0a0, dark: 0xa0a0a0, alpha: 0.8)
  /// 先頭の行が上へ隠れている間の本文の上端の影の色（scrollbar.shadow）。
  static let editorScrollShadow = editorDyn(light: 0xdddddd, dark: 0x000000)
  /// 本文が右に続くときのミニマップ左端の影の色（α 込み。ぼかし 6）。
  static let editorMinimapShadow = editorDynA(light: 0x000000, dark: 0x000000, alpha: 0.08)

  // 構文色。dark は VSCode Dark Modern の実在トークン色（5 色は端末 ANSI と偶然同値だが、端末色は
  // 別レイヤー〔design-system §8〕なので参照しない）。light は紙面に合わせて調整した値。
  static let syntaxKeyword = editorDyn(light: 0x2f63c9, dark: 0x569cd6)
  static let syntaxKeywordControl = editorDyn(light: 0xa03a98, dark: 0xc586c0)
  static let syntaxType = editorDyn(light: 0x178a72, dark: 0x4ec9b0)
  static let syntaxFunction = editorDyn(light: 0x8a7a12, dark: 0xdcdcaa)
  static let syntaxString = editorDyn(light: 0xb0562a, dark: 0xce9178)
  static let syntaxComment = editorDyn(light: 0x8d87a0, dark: 0x7a7387)
  static let syntaxVariable = editorDyn(light: 0x2a7bbd, dark: 0x9cdcfe)
  static let syntaxPunctuation = editorDyn(light: 0x4a4658, dark: 0xd4d4d4)

  /// `DesignTokens.swift` の private ヘルパは参照不可なので自前で持つ。
  private static func editorDyn(light: Int, dark: Int) -> NSColor {
    editorDynA(light: light, dark: dark, alpha: 1)
  }

  private static func editorDynA(light: Int, dark: Int, alpha: CGFloat) -> NSColor {
    editorDynAB(light: (light, alpha), dark: (dark, alpha))
  }

  /// 外観ごとに色と α が違う色。
  private static func editorDynAB(light: (Int, CGFloat), dark: (Int, CGFloat)) -> NSColor {
    NSColor(name: nil) { ap in
      let (hex, alpha) = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
  }
}

extension Theme.Typography {
  /// 表示できない diff の理由の一文・ボードの空状態の一文（サンセリフ 13）。
  static let editorLead = NSFont.systemFont(ofSize: 13, weight: .regular)
  /// 本体の空・使えないときの表示——見出し（sans 14 medium）・案内の一文とショートカットの行（sans 12.5）・ボタン（sans 12.5
  /// semibold）。左の列の一言（sans 12）。
  static let editorEmptyTitle = NSFont.systemFont(ofSize: 14, weight: .medium)
  static let editorEmptyText = NSFont.systemFont(ofSize: 12.5, weight: .regular)
  static let editorEmptyButton = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
  /// キーの札の字（sans 10.5 semibold）。
  static let editorKeyCap = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
  /// 字のボタンの字（sans 11.5）。
  static let editorTextButton = NSFont.systemFont(ofSize: 11.5, weight: .regular)
  /// 差分のファイルの見出しのパス（mono 12。ファイル名は semibold）と状態の字（mono 10.5 semibold）。
  static let editorDiffHeaderPath = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  static let editorDiffHeaderName = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
  static let editorDiffHeaderBadge = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
  /// 上のバーの今の項目のボタン——親のパス（mono 12）と名前（mono 12 semibold）。
  static let editorItemButtonPath = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  static let editorItemButtonName = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
  /// 状態を示す札（「プレビュー」「現在」。sans 10.5）。
  static let editorTag = NSFont.systemFont(ofSize: 10.5, weight: .regular)
  /// 一覧の器——見出しの題（sans 10.5 semibold）と数（mono 10.5 medium）、ファイルの行の名前（sans 12.5 medium）と
  /// ディレクトリ（mono 11）と状態の字（mono 10.5 semibold）、操作の行（sans 12.5）、下の案内（sans 11）。
  static let editorItemListHeading = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
  static let editorItemListCount = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
  static let editorItemListName = NSFont.systemFont(ofSize: 12.5, weight: .medium)
  static let editorItemListDirectory = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  static let editorItemListBadge = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
  static let editorItemListAction = NSFont.systemFont(ofSize: 12.5, weight: .regular)
  static let editorItemListHint = NSFont.systemFont(ofSize: 11, weight: .regular)
  static let editorSidebarNote = NSFont.systemFont(ofSize: 12, weight: .regular)
  /// コード本体（mono 12）。
  static let editorCode = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  /// 行番号（mono 11）。
  static let editorLineNumber = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// コード本体の行高（pt。`lineBody` 等の倍率とは単位が違う）。
  static let editorLineHeight: CGFloat = 18
  /// 上のバーの画面の切り替えの項目（sans 12.5 medium）と添え字の件数・番号（mono 10.5 medium）、「⌥ 端末を表示」（mono 11）。
  static let editorBarSwitch = NSFont.systemFont(ofSize: 12.5, weight: .medium)
  static let editorBarCount = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
  static let editorBarHint = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// パネルヘッダーの題（sans 11・tracking 0.5）。
  static let editorPanelTitle = NSFont.systemFont(ofSize: 11, weight: .regular)
  /// エクスプローラーのルート行（sans 11 bold・tracking 0.8）。
  static let editorRootLabel = NSFont.systemFont(ofSize: 11, weight: .bold)
  /// ツリー行の名前（sans 12.5）。
  static let editorTreeRow = NSFont.systemFont(ofSize: 12.5, weight: .regular)
  /// ツリー行の git バッジ（mono 11）。
  static let editorBadge = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// 種別チップのグリフ（mono bold。サイズはチップが決める）。
  static func editorChip(size: CGFloat) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
  }
  /// 検索パネルの見出しの題（sans 12.5 semibold）。
  static let editorSearchTitle = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
  /// 検索パネルの入力欄（mono 12）。
  static let editorSearchField = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  /// 入力欄の右のオプション（Aa / ab / .*。sans 10）。
  static let editorSearchOption = NSFont.systemFont(ofSize: 10, weight: .regular)
  /// 結果のまとまりの見出しのファイル名（sans 12）とディレクトリ（sans 10.5）。
  static let editorSearchFile = NSFont.systemFont(ofSize: 12, weight: .regular)
  static let editorSearchDirectory = NSFont.systemFont(ofSize: 10.5, weight: .regular)
  /// まとまりの件数バッジ（sans 9.5）。
  static let editorSearchCount = NSFont.systemFont(ofSize: 9.5, weight: .regular)
  /// 一致の行（mono 11）。
  static let editorSearchMatch = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// 件数・打ち切り・0 件・エラーの文（sans 11）。
  static let editorSearchNote = NSFont.systemFont(ofSize: 11, weight: .regular)
  /// ソース管理。親・子の区分・グラフの枠の見出し（sans 11 bold）・件数バッジ（sans 9.5）・ファイル行の名前
  /// （sans 13）とディレクトリ（sans 11）・グラフのコミットの題（sans 12）・ref の札（mono 9）・ブランチの行（mono 11）・
  /// 「さらに表示」（sans 11.5）。
  static let editorScmSection = NSFont.systemFont(ofSize: 11, weight: .bold)
  static let editorScmCount = NSFont.systemFont(ofSize: 9.5, weight: .regular)
  static let editorScmFile = NSFont.systemFont(ofSize: 13, weight: .regular)
  static let editorScmDirectory = NSFont.systemFont(ofSize: 11, weight: .regular)
  static let editorScmCommit = NSFont.systemFont(ofSize: 12, weight: .regular)
  static let editorScmRef = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
  static let editorScmBranch = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  static let editorScmMore = NSFont.systemFont(ofSize: 11.5, weight: .regular)
  /// パネルヘッダーの題の字間。
  static let trackingPanelTitle: CGFloat = 0.5
  /// ルート行の字間。
  static let trackingRootLabel: CGFloat = 0.8
}

extension Theme.Layout {
  /// 上のバーの高さ（下端の hairline を含む）。
  static let editorBar: CGFloat = 36
  /// 左の列の既定の幅（ドラッグで可変・app-state に記憶）。右の hairline 1 はこの外側に足し、合わせて 264。
  static let editorSidebar: CGFloat = 263
  /// 左の列の幅の下限。
  static let editorSidebarMinWidth: CGFloat = 160
  /// 本体（テキスト面）に残す最低幅。左の列の幅の上限と、狭い面で表示幅を切り詰める規則が使う。
  static let editorBodyMinWidth: CGFloat = 160
  /// 左の列と本体の境（hairline）に置くドラッグの当たりの幅。
  static let editorSidebarHandle: CGFloat = 4
  /// キーの札の高さと最小幅・左右の余白・角丸・中の印の大きさ。
  static let editorKeyCap: CGFloat = 18
  static let editorKeyCapPadX: CGFloat = 4
  static let editorKeyCapRadius: CGFloat = 5
  static let editorKeyCapGlyph: CGFloat = 12
  /// 字のボタンの高さ・左右の余白・角丸・印の大きさ・印と字の間・字とキーの札の間。
  static let editorTextButton: CGFloat = 22
  static let editorTextButtonPadX: CGFloat = 7
  static let editorTextButtonRadius: CGFloat = 6
  static let editorTextButtonGlyph: CGFloat = 14
  static let editorTextButtonGap: CGFloat = 5
  static let editorTextButtonKeyGap: CGFloat = 11
  /// 大きい字のボタンの高さ・角丸・左右の余白。
  static let editorLargeButton: CGFloat = 30
  static let editorLargeButtonRadius: CGFloat = 8
  static let editorLargeButtonPadX: CGFloat = 14
  /// 上のバーの今の項目のボタンの高さ・左右の余白・角丸・中の部品の間・末尾の ▾ の大きさ。
  static let editorItemButton: CGFloat = 26
  static let editorItemButtonPadX: CGFloat = 8
  static let editorItemButtonRadius: CGFloat = 7
  static let editorItemButtonGap: CGFloat = 6
  static let editorItemButtonCaret: CGFloat = 14
  /// 未保存・ディスクが変わったの丸。
  static let editorItemDot: CGFloat = 7
  /// 状態を示す札の左右の余白・上下の余白・角丸。
  static let editorTagPadX: CGFloat = 6
  static let editorTagPadY: CGFloat = 1
  static let editorTagRadius: CGFloat = 4
  /// 一覧の器——幅・行の高さ・内側の余白・角丸の選択の地・行の左右の余白と部品の間・操作の行の左右の余白・右の印の枠と × の
  /// 大きさ・状態の字の列の幅・下の案内の高さ（上の空き 5・線 1・上下の余白 7 と 3・キーの札 18）と案内の間・器の下に残す余白。
  static let editorItemListWidth: CGFloat = 420
  static let editorItemListRow: CGFloat = 26
  static let editorItemListPad: CGFloat = 5
  static let editorItemListRowRadius: CGFloat = 6
  static let editorItemListRowPadX: CGFloat = 8
  static let editorItemListRowGap: CGFloat = 8
  static let editorItemListActionPadX: CGFloat = 10
  static let editorItemListMark: CGFloat = 16
  static let editorItemListMarkGlyph: CGFloat = 10
  static let editorItemListBadge: CGFloat = 12
  static let editorItemListFooter: CGFloat = 34
  static let editorItemListHintGap: CGFloat = 14
  static let editorItemListBottom: CGFloat = 12
  static let editorPanelHeader: CGFloat = 28
  static let editorRow: CGFloat = 20
  /// ツリー行の種別チップ。
  static let editorChip: CGFloat = 14
  /// 行番号ガター（右寄せの数字が収まる幅）と、その右の git の印の列。本文は 2 つの右端から始まる。
  static let editorLineNumberGutter: CGFloat = 50
  static let editorMarkGutter: CGFloat = 19
  /// diff の面の番号の列 1 つの最小の幅と、番号の右の余白（インライン・並列）、記号（＋ / −）の列の幅。
  static let editorDiffNumber: CGFloat = 44
  static let editorDiffNumberTrailingInline: CGFloat = 6
  static let editorDiffNumberTrailingSide: CGFloat = 8
  static let editorDiffSign: CGFloat = 18
  /// diff を並列で見せる本体の幅の下限（これ未満はインライン）。
  static let editorDiffSideWidth: CGFloat = 1000
  /// 差分のファイルの見出し。高さ（下端の hairline を含む）・部品の間・左の余白（Changes・PR）・右の余白・未保存の丸・
  /// 状態の字の幅・区切り線の高さとその左右の空き・下の影が帯の下にはみ出す高さ。
  static let editorDiffHeader: CGFloat = 32
  static let editorDiffHeaderGap: CGFloat = 8
  static let editorDiffHeaderLeading: CGFloat = 12
  static let editorDiffHeaderLeadingPullRequest: CGFloat = 18
  static let editorDiffHeaderTrailing: CGFloat = 12
  static let editorDiffHeaderDot: CGFloat = 7
  static let editorDiffHeaderBadge: CGFloat = 12
  static let editorDiffHeaderDivider: CGFloat = 16
  static let editorDiffHeaderDividerInset: CGFloat = 6
  static let editorDiffHeaderShadow: CGFloat = 14
  /// 本体の右端の縦スクロールバー（印を載せる。VS Code の verticalScrollbarSize）。
  static let editorScrollbar: CGFloat = 14
  /// 本文の区画の下端の横スクロールバーの高さ（VS Code の horizontalScrollbarSize）。
  static let editorHorizontalScrollbar: CGFloat = 12
  /// 左の列の一覧（エクスプローラーのツリー・検索結果・ソース管理の列）の縦のつまみの幅（VS Code の一覧の verticalScrollbarSize）。
  static let editorSidebarScrollbar: CGFloat = 10
  /// ミニマップの幅の上限（字の左のガター込み。VS Code の maxColumn 120 × 1 字 1pt）。幅は本文の幅から計算し、
  /// 列が狭ければ細くなる。
  static let editorMinimapMaxWidth: CGFloat = 120
  /// 折りたたみのシェブロン。
  static let editorChevron: CGFloat = 16
  /// 検索パネル。見出しの高さ・左右の余白・部品の間、入力欄の高さ・オプションの角・結果の行の高さ（まとまりの見出しも一致も
  /// 同じ）・一致の行の左の字下げ・件数バッジ（最小幅×高さ）・まとまりの見出しのシェブロンの幅。
  static let editorSearchHeader: CGFloat = 38
  static let editorSearchHeaderLeading: CGFloat = 12
  static let editorSearchHeaderTrailing: CGFloat = 8
  static let editorSearchHeaderGap: CGFloat = 6
  static let editorSearchField: CGFloat = 28
  static let editorSearchOption: CGFloat = 20
  static let editorSearchRow: CGFloat = 20
  static let editorSearchMatchIndent: CGFloat = 40
  static let editorSearchCountWidth: CGFloat = 18
  static let editorSearchCountHeight: CGFloat = 16
  static let editorSearchChevron: CGFloat = 10
  /// 進みの細い線（検索中・ソース管理の実行中）。
  static let editorProgressLine: CGFloat = 2
  /// ソース管理。行（見出し・ファイル・コミット・さらに表示）の高さ・種別チップ・行の中のボタンとその印・見出しの
  /// ツールの角とその間（親の見出しのツールも子の見出しの一括操作も）・ref の札の高さ・コミットの点・点の列の幅。
  static let editorScmRow: CGFloat = 22
  static let editorScmChip: CGFloat = 16
  static let editorScmRowButton: CGFloat = 18
  static let editorScmGlyph: CGFloat = 13
  static let editorScmTool: CGFloat = 20
  static let editorScmToolGap: CGFloat = 1
  static let editorScmRef: CGFloat = 15
  static let editorScmDot: CGFloat = 7
  static let editorScmDotColumn: CGFloat = 16
  /// 子の区分の字下げ。
  static let editorScmIndent: CGFloat = 8
  /// グラフの枠の高さ（見出し 22 を含む）の既定（見出し＋8 行）と下限（見出し＋3 行）。
  static let editorScmGraph: CGFloat = 198
  static let editorScmGraphMin: CGFloat = 88
}

extension Theme.Opacity {
  /// 半透明面の light 換算。`sunkInk` の沈み面は tabRowBg の比に倣い ×0.3、`surfaceInk` の塗りは
  /// tabSegBg の比に倣い ×0.6、`borderInk` の hairline は紙面で濃くする ×1.4。
  static let editorSunkLight: Double = 0.3
  static let editorFillLight: Double = 0.6
  static let editorHairlineLight: Double = 1.4
  /// キーの札の地（`surfaceInk` の α）。
  static let editorKeyCap: Double = 0.07
  /// 字のボタンの地（`surfaceInk` の α）——地つきの変種と素の姿のホバー、地つきの変種のホバー。
  static let editorTextButtonFill: Double = 0.08
  static let editorTextButtonFillHover: Double = 0.12
  /// 色の付いた地の大きい字のボタンの、キーの札の地（黒の α）。
  static let editorLargeButtonKeyCap: Double = 0.16
  /// 今の項目のボタンの地・枠・一覧を開いている間の地（`surfaceInk` の α）。
  static let editorItemButtonFill: Double = 0.06
  static let editorItemButtonBorder: Double = 0.05
  static let editorItemButtonOpen: Double = 0.11
  /// 状態を示す札の枠（`surfaceInk` の α）。
  static let editorTag: Double = 0.2
  /// 一覧の器の行のホバーの地と、右の印の枠のホバーの地（塗りの α）。
  static let editorItemListHover: Double = 0.045
  static let editorItemListMarkHover: Double = 0.10
  /// diff の追加・削除の行の地の不透明度（構文色が地の上で読める濃さ）。
  static let editorDiffRow: CGFloat = 0.12
  /// diff の詰め物の行の地（塗りの α）と、並列の 2 面の境（hairline の α）。
  static let editorDiffPad: Double = 0.02
  static let editorDiffDivider: Double = 0.07
  /// 差分のファイルの見出しの地（`surfaceInk` の α）・下端の線と区切り線（hairline の α）。
  static let editorDiffHeaderGround: Double = 0.035
  static let editorDiffHeaderLine: Double = 0.07
  static let editorDiffHeaderDivider: Double = 0.15
}

extension Theme.Motion {
  /// ミニマップの帯が現れる・消える、スクロールバーのつまみが現れる（VS Code の opacity 100ms linear）。
  static let editorSliderFadeIn: Double = 0.1
  /// スクロールバーのつまみが消える（800ms linear）。スクロールが止まってから `editorScrollbarHideDelay` 後に始まる。
  static let editorScrollbarFadeOut: Double = 0.8
  static let editorScrollbarHideDelay: Double = 0.5
}
