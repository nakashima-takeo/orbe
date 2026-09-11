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

  /// `DesignTokens.swift` の private ヘルパは参照不可なので自前で持つ。
  private static func editorDyn(light: Int, dark: Int) -> NSColor {
    NSColor(name: nil) { ap in
      let hex = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
  }
}

extension Theme.Typography {
  /// エディター面の空状態の一文（サンセリフ 13）。
  static let editorLead = NSFont.systemFont(ofSize: 13, weight: .regular)
  /// エディター面のショートカット行・kbd（mono 12）。
  static let editorHint = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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
