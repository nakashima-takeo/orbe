import AppKit
import SwiftUI

/// エディター面（⌘E）のトークンが所有する自己完結ファイル（`DesignTokens+Glass.swift` と同型）。
/// 面のキー色は「どの面に居るか」を示す識別色で、背の印・分割中の焦点帯・位置ドットが共有する。
extension Theme.Color {
  /// エディター面のキー色（amber）。
  static let faceEditor = editorDyn(light: 0xbf6a2e, dark: 0xe0a97c)
  /// 端末面のキー色。dark / light とも textSecondary と偶然同値だが役割が違うので別トークン。
  static let faceTerminal = editorDyn(light: 0x5f5678, dark: 0xb8afc4)
  /// 空状態の ◐ の沈んだ塗り。
  static let editorGhost = editorDyn(light: 0xd9d3e6, dark: 0x3d3752)
  /// エディター面のアイコン・kbd の文字。dark / light とも kbKeyText と偶然同値だが役割が違うので別トークン。
  static let editorIcon = editorDyn(light: 0x766e8d, dark: 0xa99fb8)
  /// エディター面の 2 段目の文字——コードの素文字・ファイル名・タブ題・パンくずの末尾（見本 text2）。
  /// dark / light とも statusText と偶然同値だが役割が違うので別トークン。
  static let editorText = editorDyn(light: 0x4d4368, dark: 0xcdc7e2)
  /// 三次の文字——レールの非選択・パンくずの区切り。`textTertiary` は `textMuted` の別名なので別値を持つ。
  static let editorTertiary = editorDyn(light: 0xaca4bd, dark: 0x6d667a)
  /// 変更の黄——M バッジ・外部変更で衝突中のドット。dark は conflict と偶然同値だが light が違い、git 競合でもない。
  static let editorModified = editorDyn(light: 0xa07f0c, dark: 0xe2cd6d)
  /// 種別チップの色相（見本 palette.ts の hue）。チップの文字色と、その α .16 の地に使う。
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

  // 構文色。dark は VSCode Dark Modern の実在トークン色（5 色は端末 ANSI と偶然同値だが、端末色は
  // 別レイヤー〔design-system §8〕なので参照しない）。light は見本の値。
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
    NSColor(name: nil) { ap in
      let hex = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
  }
}

extension Theme.Typography {
  /// エディター面の空状態の一文（サンセリフ 13）。
  static let editorLead = NSFont.systemFont(ofSize: 13, weight: .regular)
  /// エディター面のショートカット行・kbd（mono 12）。
  static let editorHint = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  /// コード本体（mono 12）。
  static let editorCode = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  /// 行番号（mono 11）。
  static let editorLineNumber = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// コード本体の行高（pt。`lineBody` 等の倍率とは単位が違う）。
  static let editorLineHeight: CGFloat = 18
  /// パネルヘッダーの題（sans 11・tracking 0.5）。
  static let editorPanelTitle = NSFont.systemFont(ofSize: 11, weight: .regular)
  /// エクスプローラーのルート行（sans 11 bold・tracking 0.8）。
  static let editorRootLabel = NSFont.systemFont(ofSize: 11, weight: .bold)
  /// ツリー行の名前（sans 13）。
  static let editorTreeRow = NSFont.systemFont(ofSize: 13, weight: .regular)
  /// ツリー行の git バッジ（mono 11）。
  static let editorBadge = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// ファイルタブの題（sans 12.5）。
  static let editorFileTab = NSFont.systemFont(ofSize: 12.5, weight: .regular)
  /// パンくず（sans 11.5）。
  static let editorBreadcrumb = NSFont.systemFont(ofSize: 11.5, weight: .regular)
  /// 種別チップのグリフ（mono bold。サイズはチップが決める）。
  static func editorChip(size: CGFloat) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
  }
  /// パネルヘッダーの題の字間。
  static let trackingPanelTitle: CGFloat = 0.5
  /// ルート行の字間。
  static let trackingRootLabel: CGFloat = 0.8
}

extension Theme.Layout {
  /// 骨の寸法（見本 EditorLayer.tsx）。レール｜サイドバー｜列の頭（ファイルタブ行 → パンくず）。
  static let editorRail: CGFloat = 52
  static let editorSidebar: CGFloat = 272
  /// 列幅がこれ未満ならサイドバーを畳む。
  static let editorSidebarMin: CGFloat = 720
  static let editorFileTabs: CGFloat = 34
  static let editorBreadcrumb: CGFloat = 22
  static let editorPanelHeader: CGFloat = 32
  static let editorRow: CGFloat = 22
  static let editorChip: CGFloat = 16
  /// パンくずの末尾のチップ。
  static let editorChipSmall: CGFloat = 13
}

extension Theme.Opacity {
  /// 見本の半透明面の light 換算。`sunkInk` の沈み面は tabRowBg の比に倣い ×0.3、`surfaceInk` の塗りは
  /// tabSegBg の比に倣い ×0.6、`borderInk` の hairline は紙面で濃くする ×1.4。
  static let editorSunkLight: Double = 0.3
  static let editorFillLight: Double = 0.6
  static let editorHairlineLight: Double = 1.4
}

extension Theme.Motion {
  /// 面のスライド（⌘E・背クリック）。
  static let faceSlide: Double = 0.32
  /// faceSlide のイージング cubic-bezier(0.32,0.72,0,1)。
  static let faceSlideCurve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.32, y: 0.72), endControlPoint: UnitPoint(x: 0, y: 1))
  /// 背の地の切替（印 ⇄ グリップ）。
  static let spineLook: Double = 0.20
  /// 位置ドットの幅・色の遷移。
  static let faceDot: Double = 0.24
}
