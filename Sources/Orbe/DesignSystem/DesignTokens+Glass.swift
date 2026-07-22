import SwiftUI

/// Orbe の glass / elevation / glow トークン（`DesignTokens.swift` とは独立した自己完結ファイル）。
/// 色値の正典は 確定配色（`OrbePalette` / `StateHue`）。
/// geometry（blur 半径・elevation・radial 位置/サイズ）の正典はこのファイル（`docs/design-system.md` は再定義しない）。
/// 面色・枠・glow は動的 NSColor（dark/light）で持ち、SwiftUI 側で `Color(nsColor:)` 橋渡し。
/// elevation は dark/light で geometry（radius/y）自体が異なるため `@Environment(\.colorScheme)` を読む ViewModifier。
extension Theme {

  /// ガラスパネルの階層。面 opacity と枠濃度が段階で変わる（panel < settings < popup）。
  /// swiftlint の nesting 規約（1 段まで）に合わせ `Glass` の外へ出す。
  enum GlassLevel { case panel, settings, popup }

  // MARK: - Glass（面・枠・角丸・blur・glow）

  enum Glass {
    /// 面色（surface-glass）。dark rgba(30,26,38,α) / light rgba(255,255,255,α)。
    static func surface(_ l: GlassLevel) -> NSColor {
      switch l {
      case .panel: dynA(light: 0xffffff, lightA: 0.72, dark: 0x1e1a26, darkA: 0.72)
      case .settings: dynA(light: 0xffffff, lightA: 0.85, dark: 0x1e1a26, darkA: 0.85)
      case .popup: dynA(light: 0xffffff, lightA: 0.90, dark: 0x1e1a26, darkA: 0.90)
      }
    }

    /// 枠色。dark rgba(199,185,235,α) / light rgba(110,90,170,α)。
    static func border(_ l: GlassLevel) -> NSColor {
      switch l {
      case .panel, .settings: dynA(light: 0x6e5aaa, lightA: 0.12, dark: 0xc7b9eb, darkA: 0.08)
      case .popup: dynA(light: 0x6e5aaa, lightA: 0.14, dark: 0xc7b9eb, darkA: 0.10)
      }
    }

    /// 角丸。panel/settings=radius-panel 16 / popup=radius-control 10。
    static func radius(_ l: GlassLevel) -> CGFloat {
      switch l {
      case .panel, .settings: 16
      case .popup: 10
      }
    }

    /// 目標 blur 半径（`--blur-panel`）。material が近似するのみで厳密一致は原理不可（記録用）。
    static let blurPanel: CGFloat = 24

    /// 背景 glow の一次層（accent）。dark rgba(144,104,240,0.13) / light rgba(109,67,216,0.08)。
    static let glowPrimary = dynA(
      light: OrbePalette.Chrome.accentLight, lightA: 0.08,
      dark: OrbePalette.Chrome.accentDark, darkA: 0.13)
    /// 背景 glow の二次層（working）。dark rgba(133,173,255,0.07) / light rgba(31,102,201,0.05)。
    /// StateHue は別ファイル private のため working の hex を直書きする。
    static let glowSecondary = dynA(light: 0x1f66c9, lightA: 0.05, dark: 0x85adff, darkA: 0.07)
  }

  /// elevation の階層。panel=大型フローティング / popup=端末上の小ポップアップ。
  enum ElevationLevel { case panel, popup }

  // MARK: - 生成ヘルパ（`DesignTokens.swift` の private ヘルパは参照不可なので自前で持つ）

  fileprivate static func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
      green: CGFloat((hex >> 8) & 0xff) / 255,
      blue: CGFloat(hex & 0xff) / 255, alpha: a)
  }

  fileprivate static func dynA(light: Int, lightA: CGFloat, dark: Int, darkA: CGFloat) -> NSColor {
    NSColor(name: nil) { ap in
      ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark, darkA) : rgb(light, lightA)
    }
  }
}

/// elevation を適用する。level×scheme で color/radius/y を選ぶ（popup は dark/light で geometry が異なる）。
extension View {
  func elevation(_ level: Theme.ElevationLevel) -> some View {
    modifier(ElevationModifier(level: level))
  }
}

/// `@Environment(\.colorScheme)` を読み、Orbe の box-shadow（radius = CSS blur / 2）へ換算した影を落とす。
private struct ElevationModifier: ViewModifier {
  /// dark/light で geometry ごと変わる影仕様（`--shadow-panel` / `--shadow-popup`）。
  struct Spec {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
  }

  let level: Theme.ElevationLevel
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    let s = spec
    return content.shadow(color: s.color, radius: s.radius, x: 0, y: s.y)
  }

  private var spec: Spec {
    let shadowTint = Color(.sRGB, red: 90 / 255, green: 70 / 255, blue: 150 / 255, opacity: 1)
    // CSS box-shadow → radius = blur / 2（`--shadow-panel` / `--shadow-popup`）:
    //   panel dark  0 20 60 rgba(0,0,0,.5)     / panel light 0 20 60 rgba(90,70,150,.22)
    //   popup dark  0 16 48 rgba(0,0,0,.55)    / popup light 0 16 48 rgba(90,70,150,.20)
    switch (level, scheme) {
    case (.panel, .dark): return Spec(color: .black.opacity(0.5), radius: 30, y: 20)
    case (.panel, _): return Spec(color: shadowTint.opacity(0.22), radius: 30, y: 20)
    case (.popup, .dark): return Spec(color: .black.opacity(0.55), radius: 24, y: 16)
    case (.popup, _): return Spec(color: shadowTint.opacity(0.20), radius: 24, y: 16)
    }
  }
}
