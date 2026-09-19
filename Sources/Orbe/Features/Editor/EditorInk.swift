import SwiftUI

/// 見本（palette.ts の sunk / fill / hairline）の半透明面を外観で換算する。基色は `sunkInk` /
/// `surfaceInk` / `borderInk` の 3 本で、light の係数は `Theme.Opacity.editor*Light`。
struct EditorInk {
  private let dark: Bool

  init(_ scheme: ColorScheme) { dark = scheme == .dark }

  /// 沈み面（レール・サイドバー・タブ行の地）。
  func sunk(_ alpha: Double) -> Color {
    Color.theme.sunkInk.opacity(dark ? alpha : alpha * Theme.Opacity.editorSunkLight)
  }

  /// 塗り（ホバー・選択項目の地・kbd の地）。
  func fill(_ alpha: Double) -> Color {
    Color.theme.surfaceInk.opacity(Self.fillAlpha(alpha, dark: dark))
  }

  /// 見本の fill(α) の外観換算（light は `editorFillLight` 倍）。SwiftUI の `fill` と NSColor 側が共有する規則。
  static func fillAlpha(_ alpha: Double, dark: Bool) -> Double {
    dark ? alpha : alpha * Theme.Opacity.editorFillLight
  }

  /// 境界線（面の縁・ガイド・kbd の枠）。
  func hairline(_ alpha: Double) -> Color {
    Color.theme.borderInk.opacity(dark ? alpha : alpha * Theme.Opacity.editorHairlineLight)
  }
}
