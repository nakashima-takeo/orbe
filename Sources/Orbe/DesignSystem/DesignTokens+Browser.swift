import AppKit
import SwiftUI

/// 内蔵ブラウザ層（Z=2）のトークン（`DesignTokens+Editor.swift` と同型）。
/// ツールバー・サイドバー・本体の地は常に不透明度 100%（`ChromeTranslucency` 非適用）。
extension Theme {
  /// 右シート左端・狭幅サイドバー右端へ落とす影の仕様（CSS box-shadow → `radius = blur / 2`）。
  struct BrowserShadowSpec {
    let color: NSColor
    let opacity: Float
    let offset: CGSize
    let radius: CGFloat
  }
}

extension Theme.Color {
  /// ツールバー下端・サイドバー右端の 1px 線（dark `borderInk` .08 / light `borderInk` .12）。
  static let browserBarBorder = browserDynAB(
    light: (0x6e5aaa, 0.12), dark: (0xc7b9eb, 0.08))
  /// 右シート左端 1px 線（focus / soft）。全面・Peek 時は非表示。
  static let browserSheetBorderFocus = browserDynAB(
    light: (0x6e5aaa, 0.22), dark: (0xc7b9eb, 0.18))
  static let browserSheetBorderSoft = browserDynAB(
    light: (0x6e5aaa, 0.14), dark: (0xc7b9eb, 0.12))
  /// 右シート＋ブラウザ焦点＋非 Peek 時に左層へ掛ける暗幕ベール（`sunkInk` dark .22 / light .06）。
  static let browserLeftVeil = browserDynAB(
    light: (0x3a3151, 0.06), dark: (0x0a080e, 0.22))
  /// 影の基色（不透明。濃さは `BrowserShadowSpec.opacity` へ分離する）。
  static let browserShadowTint = browserDynAB(
    light: (0x463278, 1), dark: (0x000000, 1))
  /// 右端 Peek ライン（`accentPrimary` .65）。
  static let browserPeekRail = accentPrimary.withAlphaComponent(0.65)
  /// 左端ドラッグハンドルの強調線（`accentPrimary` .85）。
  static let browserResizeLine = accentPrimary.withAlphaComponent(0.85)

  /// サイドバーの不透明地。
  static let browserSidebarBg = browserDynAB(
    light: (0xf3effa, 1), dark: (0x14111b, 1))
  /// 狭幅オーバーレイサイドバー背面の暗幕。
  static let browserSidebarScrim = browserDynAB(
    light: (0x3a3151, 0.14), dark: (0x0a080e, 0.36))
  /// ローカルスペースのティールバッジ地と文字色。
  static let browserLocalBadge = browserDynAB(
    light: (0x178a76, 1), dark: (0x7fd0c3, 1))
  static let browserLocalBadgeInk = browserDynAB(
    light: (0xfcfbfe, 1), dark: (0x14111b, 1))

  /// プロファイル識別色 6 色。
  static let browserProfileGreen = browserDynAB(
    light: (0x279a4d, 1), dark: (0x82d894, 1))
  static let browserProfileBlue = browserDynAB(
    light: (0x2563c9, 1), dark: (0x85adff, 1))
  static let browserProfileAmber = browserDynAB(
    light: (0xbf6a2e, 1), dark: (0xe0a97c, 1))
  static let browserProfilePurple = browserDynAB(
    light: (0x6d43d8, 1), dark: (0xb18aff, 1))
  static let browserProfilePink = browserDynAB(
    light: (0xc8323e, 1), dark: (0xe06c75, 1))
  static let browserProfileTeal = browserDynAB(
    light: (0x178a76, 1), dark: (0x7fd0c3, 1))

  /// 右シート左落ち影仕様をフォーカス状態と外観から解決する。
  static func browserShadow(focused: Bool, dark: Bool) -> Theme.BrowserShadowSpec {
    switch (focused, dark) {
    case (true, true):
      Theme.BrowserShadowSpec(
        color: browserShadowTint, opacity: 0.62, offset: CGSize(width: -28, height: 0), radius: 32)
    case (true, false):
      Theme.BrowserShadowSpec(
        color: browserShadowTint, opacity: 0.22, offset: CGSize(width: -22, height: 0), radius: 27)
    case (false, true):
      Theme.BrowserShadowSpec(
        color: browserShadowTint, opacity: 0.34, offset: CGSize(width: -14, height: 0), radius: 18)
    case (false, false):
      Theme.BrowserShadowSpec(
        color: browserShadowTint, opacity: 0.12, offset: CGSize(width: -10, height: 0), radius: 14)
    }
  }

  /// 狭幅オーバーレイサイドバーの右落ち影仕様を外観から解決する。
  static func browserSidebarShadow(dark: Bool) -> Theme.BrowserShadowSpec {
    if dark {
      return Theme.BrowserShadowSpec(
        color: browserShadowTint, opacity: 0.45, offset: CGSize(width: 14, height: 0), radius: 20)
    }
    return Theme.BrowserShadowSpec(
      color: browserShadowTint, opacity: 0.18, offset: CGSize(width: 10, height: 0), radius: 16)
  }

  /// `DesignTokens.swift` の private ヘルパは参照不可なので自前で持つ。
  private static func browserDynAB(
    light: (Int, CGFloat), dark: (Int, CGFloat)
  ) -> NSColor {
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
  /// ブラウザ URL 欄の表示・入力（等幅 12pt）。
  static let browserURL = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  /// 全面 Peek ピルの文言（等幅 11pt）。
  static let browserPeekPill = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// リサイズ中のスナップバッジ（等幅 11pt）。
  static let browserSnapBadge = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  /// サイドバーヘッダのスペース名。
  static let browserSidebarSpaceTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
  /// サイドバーのローカルタグ・セクション見出し・整理ボタン。
  static let browserSidebarMeta = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
  /// プロファイルピル・ポップオーバー補足・新タブ相対時刻。
  static let browserSidebarProfilePill = NSFont.monospacedSystemFont(
    ofSize: 10.5, weight: .regular)
  /// サイドバータブ行・ポップオーバー項目・新タブ最近閉じたタブ行。
  static let browserSidebarTab = NSFont.systemFont(ofSize: 12.5, weight: .regular)
  /// サイドバー `+ 新しいタブ` 行・ポップオーバーボタン。
  static let browserSidebarAction = NSFont.systemFont(ofSize: 12, weight: .regular)
  /// ポップオーバー見出し・フォーム保存ボタン。
  static let browserPopoverTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
  /// ポップオーバー小セクション見出し。
  static let browserPopoverSection = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
  /// Favorites タイル下の短いラベル。
  static let browserSidebarFavLabel = NSFont.systemFont(ofSize: 9.5, weight: .regular)
  /// モノグラムチップ（17×17 行用 / 20×20 Favorites・24×24 新タブ用）。
  static let browserSidebarChip = NSFont.systemFont(ofSize: 9.5, weight: .bold)
  static let browserSidebarFavChip = NSFont.systemFont(ofSize: 10.5, weight: .bold)
  /// ローカルスペース角丸バッジの文字。
  static let browserLocalBadge = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .bold)
  /// 下端スペース切替バーのローカルスペース名。
  static let browserSwitcherLocal = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
  /// 新タブ中央 URL 入力欄。
  static let browserNewTabInput = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
  /// 新タブクイックアクセスタイルラベル。
  static let browserNewTabTile = NSFont.systemFont(ofSize: 11, weight: .regular)
}

extension Theme.Layout {
  /// ブラウザツールバーの高さ（下端の hairline 1pt を含む）。
  static let browserBar: CGFloat = 36
  static let browserBarLeading: CGFloat = 8
  static let browserBarTrailing: CGFloat = 10
  static let browserBarGap: CGFloat = 4
  static let browserIconButton: CGFloat = 26
  static let browserIconButtonRadius: CGFloat = 7
  static let browserIconSize: CGFloat = 14
  static let browserURLHeight: CGFloat = 26
  /// 全面 Peek ピルを表示し続けるために URL 欄へ確保する最小幅。
  /// これを下回る狭幅ではピルを省略し、URL 欄は `minWidth: 0` で柔軟に縮小する。
  static let browserURLPeekMinWidth: CGFloat = 120
  static let browserURLRadius: CGFloat = 7
  static let browserURLMarginX: CGFloat = 4
  static let browserURLPadLeading: CGFloat = 10
  static let browserURLPadTrailing: CGFloat = 8
  static let browserURLGap: CGFloat = 7
  static let browserURLProgressHeight: CGFloat = 2
  static let browserLockIconSize: CGFloat = 12
  static let browserResizeHandleWidth: CGFloat = 9
  static let browserResizeLineWidth: CGFloat = 2
  static let browserPeekRailWidth: CGFloat = 2
  static let browserSnapBadgeLeading: CGFloat = 14
  static let browserSnapBadgeRadius: CGFloat = 6
  static let browserSnapBadgePadX: CGFloat = 9
  static let browserSnapBadgePadY: CGFloat = 4

  /// サイドバー幾何。
  static let browserSidebarWidth: CGFloat = 256
  static let browserSidebarInlineThreshold: CGFloat = 520
  static let browserSidebarHeader: CGFloat = 40
  static let browserSidebarHeaderLeading: CGFloat = 14
  static let browserSidebarHeaderTrailing: CGFloat = 10
  static let browserSidebarHeaderGap: CGFloat = 7
  static let browserSidebarSwitcher: CGFloat = 42
  static let browserSidebarSectionHeight: CGFloat = 24
  static let browserSidebarRow: CGFloat = 30
  static let browserSidebarRowRadius: CGFloat = 7
  static let browserSidebarFavHeight: CGFloat = 44
  static let browserSidebarFavRadius: CGFloat = 9
  static let browserSidebarProfilePillHeight: CGFloat = 20
  static let browserSidebarProfilePillMaxWidth: CGFloat = 104
  static let browserSidebarDot: CGFloat = 7
  static let browserSidebarPopoverDot: CGFloat = 9
  static let browserSidebarChip: CGFloat = 17
  static let browserSidebarFavChip: CGFloat = 20
  static let browserSidebarChipRadius: CGFloat = 5
  static let browserSidebarLocalBadge: CGFloat = 16
  static let browserSidebarSwitcherLocalBadge: CGFloat = 14
  static let browserSidebarSwitcherIconW: CGFloat = 30
  static let browserSidebarSwitcherIconH: CGFloat = 28
  static let browserSidebarSwitcherAddW: CGFloat = 26
  static let browserSidebarSwitcherDot: CGFloat = 6
  static let browserSidebarSwitcherDividerH: CGFloat = 18
  static let browserSidebarSwitcherLocalMaxW: CGFloat = 112
  static let browserSidebarCloseButton: CGFloat = 18

  /// ビュー内ポップオーバー幾何。
  static let browserPopoverProfileWidth: CGFloat = 296
  static let browserPopoverSpaceWidth: CGFloat = 272
  static let browserPopoverInset: CGFloat = 8
  static let browserPopoverRadius: CGFloat = 12
  static let browserPopoverHeaderY: CGFloat = 42
  static let browserPopoverBottomOffset: CGFloat = 48
  static let browserToggleWidth: CGFloat = 34
  static let browserToggleHeight: CGFloat = 19
  static let browserToggleKnob: CGFloat = 15

  /// 新しいタブ画面幾何。
  static let browserNewTabMaxWidth: CGFloat = 520
  static let browserNewTabInputHeight: CGFloat = 42
  static let browserNewTabInputRadius: CGFloat = 11
  static let browserNewTabMarkSize: CGFloat = 36
  static let browserNewTabTileWidth: CGFloat = 72
  static let browserNewTabTileHeight: CGFloat = 64
  static let browserNewTabTileChip: CGFloat = 24
}

extension Theme.Opacity {
  /// 非フォーカス時のツールバー子要素の不透明度（背景は 100% 不透明のまま）。
  static let browserBarInactive: Double = 0.68
  /// 戻る・進む等の無効ボタン。
  static let browserButtonDisabled: Double = 0.35
  /// アイコンボタンのホバー・ON 背景（`surfaceInk` の α）。
  static let browserButtonHover: Double = 0.07
  static let browserButtonActive: Double = 0.09
  /// URL 欄の背景・枠・フォーカス枠。
  static let browserURLFill: Double = 0.055
  static let browserURLFillHover: Double = 0.08
  static let browserURLBorder: Double = 0.05
  static let browserURLFocusBorder: Double = 0.65
  /// スナップバッジの枠（`accentPrimary` の α）。
  static let browserSnapBadgeBorder: Double = 0.45
  /// サイドバー・ポップオーバー・新タブ面の淡塗り・枠係数。
  static let browserSidebarItemHover: Double = 0.06
  static let browserSidebarPillFill: Double = 0.06
  static let browserSidebarPillHover: Double = 0.12
  static let browserSidebarFavFill: Double = 0.055
  static let browserSidebarFavHover: Double = 0.10
  static let browserSidebarFavBorder: Double = 0.04
  static let browserSidebarFavActiveBorder: Double = 0.55
  static let browserSidebarSwitcherBorder: Double = 0.35
  static let browserSidebarChipFill: Double = 0.16
  static let browserNewTabTileFill: Double = 0.05
  static let browserNewTabTileHover: Double = 0.09
  static let browserToggleOff: Double = 0.16
}

extension ThemeColors {
  var browserBarBorder: Color { Color(nsColor: Theme.Color.browserBarBorder) }
  var browserSidebarBg: Color { Color(nsColor: Theme.Color.browserSidebarBg) }
  var browserLocalBadge: Color { Color(nsColor: Theme.Color.browserLocalBadge) }
  var browserLocalBadgeInk: Color { Color(nsColor: Theme.Color.browserLocalBadgeInk) }
  var browserProfileGreen: Color { Color(nsColor: Theme.Color.browserProfileGreen) }
  var browserProfileBlue: Color { Color(nsColor: Theme.Color.browserProfileBlue) }
  var browserProfileAmber: Color { Color(nsColor: Theme.Color.browserProfileAmber) }
  var browserProfilePurple: Color { Color(nsColor: Theme.Color.browserProfilePurple) }
  var browserProfilePink: Color { Color(nsColor: Theme.Color.browserProfilePink) }
  var browserProfileTeal: Color { Color(nsColor: Theme.Color.browserProfileTeal) }
}

extension ThemeFonts {
  var browserURL: Font { Font(Theme.Typography.browserURL as CTFont) }
  var browserPeekPill: Font { Font(Theme.Typography.browserPeekPill as CTFont) }
  var browserSnapBadge: Font { Font(Theme.Typography.browserSnapBadge as CTFont) }
  var browserSidebarSpaceTitle: Font { Font(Theme.Typography.browserSidebarSpaceTitle as CTFont) }
  var browserSidebarMeta: Font { Font(Theme.Typography.browserSidebarMeta as CTFont) }
  var browserSidebarProfilePill: Font { Font(Theme.Typography.browserSidebarProfilePill as CTFont) }
  var browserSidebarTab: Font { Font(Theme.Typography.browserSidebarTab as CTFont) }
  var browserSidebarAction: Font { Font(Theme.Typography.browserSidebarAction as CTFont) }
  var browserPopoverTitle: Font { Font(Theme.Typography.browserPopoverTitle as CTFont) }
  var browserPopoverSection: Font { Font(Theme.Typography.browserPopoverSection as CTFont) }
  var browserSidebarFavLabel: Font { Font(Theme.Typography.browserSidebarFavLabel as CTFont) }
  var browserSidebarChip: Font { Font(Theme.Typography.browserSidebarChip as CTFont) }
  var browserSidebarFavChip: Font { Font(Theme.Typography.browserSidebarFavChip as CTFont) }
  var browserLocalBadge: Font { Font(Theme.Typography.browserLocalBadge as CTFont) }
  var browserSwitcherLocal: Font { Font(Theme.Typography.browserSwitcherLocal as CTFont) }
  var browserNewTabInput: Font { Font(Theme.Typography.browserNewTabInput as CTFont) }
  var browserNewTabTile: Font { Font(Theme.Typography.browserNewTabTile as CTFont) }
}
