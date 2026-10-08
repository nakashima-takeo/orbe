import AppKit
import OrbeEditorCore

/// 試しのスレッドの見え方——見本の theme・cmdePalette の値（dark / light）と、字の測り。
extension SampleThreadZone {
  static let resolve: AnyHashable = "resolve"
  static let collapse: AnyHashable = "collapse"
  static let add: AnyHashable = "add"
  static let resolveReply: AnyHashable = "resolveReply"

  static func label(of id: AnyHashable) -> String {
    switch id {
    case resolve: "解決"
    case collapse: "折りたたむ"
    case add: "レビューに追加"
    default: "解決して返信"
    }
  }

  static let fieldStyle = ZoneTextField.Style(
    font: .systemFont(ofSize: 12), lineHeight: 16, textColor: chromeText, caretColor: accentBright,
    selectionColor: tint(accent, 0.35), inactiveSelectionColor: tint(accent, 0.18))

  static func dyn(_ dark: Int, _ light: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(name: nil) { appearance in
      let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
  }

  static func rgba(dark: Int, darkA: CGFloat, light: Int, lightA: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let hex = isDark ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: isDark ? darkA : lightA)
    }
  }

  static let accent = dyn(0x9068f0, 0x6d43d8)
  static let accentBright = dyn(0xb18aff, 0x6d43d8)
  static let muted = dyn(0x8b8397, 0x8d85a3)
  static let text2 = dyn(0xcdc7e2, 0x4d4368)
  static let tertiary = dyn(0x6d667a, 0xaca4bd)
  static let ghost = dyn(0x3d3752, 0xd9d3e6)
  static let chromeText = dyn(0xe6e1f0, 0x3a3151)
  static let modified = dyn(0xe2cd6d, 0xa07f0c)
  static let tabActiveText = dyn(0x171420, 0xf3f0fa)

  static func tint(_ color: NSColor, _ alpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      var resolved = color
      appearance.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB) ?? color
      }
      return resolved.withAlphaComponent(alpha)
    }
  }

  static func panel(_ a: CGFloat) -> NSColor {
    rgba(dark: 0x1e1a26, darkA: a, light: 0xffffff, lightA: a)
  }
  static func shadow(_ a: CGFloat) -> NSColor {
    rgba(dark: 0x000000, darkA: a, light: 0x5a4696, lightA: a)
  }
  static func hairline(_ a: CGFloat) -> NSColor {
    rgba(dark: 0xc7b9eb, darkA: a, light: 0x6e5aaa, lightA: a * 1.4)
  }
  static func sunk(_ a: CGFloat) -> NSColor {
    rgba(dark: 0x0a080e, darkA: a, light: 0x3a3151, lightA: a * 0.3)
  }
  static func fill(_ a: CGFloat) -> NSColor {
    rgba(dark: 0xffffff, darkA: a, light: 0x3a3151, lightA: a * 0.6)
  }

  /// OrbeGlyph（外円から右半分の内半円を抜いた ◐。accent）。
  static let orbeGlyph = NSImage(size: NSSize(width: 12, height: 12), flipped: true) { rect in
    let k = rect.width / 32
    let path = NSBezierPath(ovalIn: NSRect(x: k, y: k, width: 30 * k, height: 30 * k))
    path.move(to: NSPoint(x: 16 * k, y: 4.223 * k))
    path.appendArc(
      withCenter: NSPoint(x: 16 * k, y: 16 * k), radius: 11.777 * k, startAngle: -90,
      endAngle: 90, clockwise: false)
    path.close()
    path.windingRule = .evenOdd
    accent.setFill()
    path.fill()
    return true
  }

  /// 高さ `height` の行の箱の中で、字を縦の中央に置く基線（CSS の行の半分の余白と同じ）。
  static func baseline(top: CGFloat, height: CGFloat, font: NSFont) -> CGFloat {
    top + (height - (font.ascender - font.descender)) / 2 + font.ascender
  }

  static func width(_ string: String, _ font: NSFont) -> CGFloat {
    ZoneTextLayout.width([ZoneTextRun(string, font: font, color: .black)])
  }
}
