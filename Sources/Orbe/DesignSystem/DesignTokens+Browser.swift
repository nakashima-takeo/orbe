import AppKit
import SwiftUI

/// 内蔵ブラウザ層（Z=2）のトークン（`DesignTokens+Editor.swift` と同型）。
/// ツールバーと本体の地は常に不透明度 100% の `Theme.Color.bgBase`（`ChromeTranslucency` 非適用）。
extension Theme {
  /// 右シート左端へ落とす影の仕様（CSS box-shadow → `radius = blur / 2`）。
  struct BrowserShadowSpec {
    let color: NSColor
    let opacity: Float
    let offset: CGSize
    let radius: CGFloat
  }
}

extension Theme.Color {
  /// ツールバー下端の 1px 線（dark `borderInk` .08 / light `borderInk` .12）。
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
  /// 右シート左落ち影の基色（不透明。濃さは `BrowserShadowSpec.opacity` へ分離する）。
  static let browserShadowTint = browserDynAB(
    light: (0x463278, 1), dark: (0x000000, 1))
  /// 右端 Peek ライン（`accentPrimary` .65）。
  static let browserPeekRail = accentPrimary.withAlphaComponent(0.65)
  /// 左端ドラッグハンドルの強調線（`accentPrimary` .85）。
  static let browserResizeLine = accentPrimary.withAlphaComponent(0.85)

  /// 影仕様をフォーカス状態と外観から解決する。
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
}

extension ThemeColors {
  var browserBarBorder: Color { Color(nsColor: Theme.Color.browserBarBorder) }
}

extension ThemeFonts {
  var browserURL: Font { Font(Theme.Typography.browserURL as CTFont) }
  var browserPeekPill: Font { Font(Theme.Typography.browserPeekPill as CTFont) }
  var browserSnapBadge: Font { Font(Theme.Typography.browserSnapBadge as CTFont) }
}
