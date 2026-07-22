import Foundation

/// Orbe 識別色の単一 SSOT（唯一の正）。
/// 端末 ANSI 16 色・端末 bg/fg/cursor/selection・chrome 共有アンカーをプレーンな Swift 定数で持つ。
/// 下流: 端末 conf 2枚（`app/themes/OrbeDark` / `OrbeLight`）は `renderConf(_:)` が生成し、
/// chrome（`DesignTokens.swift`）は `Chrome` アンカーを直接参照する（手写しの転写ゼロ）。
/// ゲート（`OrbePaletteTests`）が ink の WCAG AA 4.5 と conf の drift を検証する。
enum OrbePalette {

  // MARK: - 端末 ANSI 16 色（index = ANSI スロット）

  /// ダーク（背景 `#171420`）。VS Code Dark+ の**シンタックストークン色**を ANSI スロットへ
  /// 再配置した確定配色値（`#569cd6`=keyword, `#c586c0`=control keyword, `#9cdcfe`=variable,
  /// `#4fc1ff`=numeric constant, `#d4d4d4`=editor foreground）。
  /// VS Code の端末色（`terminal.ansi*`）とは別物。
  static let termAnsiDark: [Int] = [
    0x4a4452, 0xd16969, 0x81b88b, 0xe2cd6d, 0x569cd6, 0xc586c0, 0x4bbfc7, 0xd4d4d4,
    0x7a7387, 0xf44747, 0x89d185, 0xf5e590, 0x9cdcfe, 0xd9a9d9, 0x4fc1ff, 0xe9e9e9,
  ]

  /// ライト（背景 `#fcfbfe`）。無彩色ランプ 0/7/15 は Catppuccin Latte 由来
  /// （`#5c5f77` / `#acb0be` / `#bcc0cc`）。8 だけ Latte の `#6c6f85` から AA 是正して `#64677d`。
  /// 有彩色 1–6 は light 背景向けに決めた確定配色値（bright 9–14 は 1–6 のミラー）。
  static let termAnsiLight: [Int] = [
    0x5c5f77, 0xe02d33, 0x279a4d, 0xb17b00, 0x145deb, 0xab3c91, 0x007a8a, 0xacb0be,
    0x64677d, 0xe02d33, 0x279a4d, 0xb17b00, 0x145deb, 0xab3c91, 0x007a8a, 0xbcc0cc,
  ]

  // MARK: - 端末 bg/fg/cursor/selection（Level 0 対象外・このファイルが値の正）

  struct Terminal {
    let background: Int
    let foreground: Int
    let cursorColor: Int
    let cursorText: Int
    let selectionBackground: Int
    let selectionForeground: Int
  }

  static let terminalDark = Terminal(
    background: 0x171420, foreground: 0xe6e1f0, cursorColor: 0x9068f0,
    cursorText: 0x171420, selectionBackground: 0x264f78, selectionForeground: 0xeaddc7)

  static let terminalLight = Terminal(
    background: 0xfcfbfe, foreground: 0x3a3151, cursorColor: 0x6d43d8,
    cursorText: 0xfcfbfe, selectionBackground: 0xc9d9f2, selectionForeground: 0x3a3151)

  // MARK: - chrome 共有アンカー（DesignTokens.swift が直接参照する識別色）
  // dark/light とも識別色は端末 ink と同値（ANSI スロット・カーソル・地を共有）。

  enum Chrome {
    static let backgroundDark = terminalDark.background  // #171420
    static let backgroundLight = terminalLight.background  // #fcfbfe
    static let foregroundDark = terminalDark.foreground  // #e6e1f0
    static let foregroundLight = terminalLight.foreground  // #3a3151
    static let accentDark = terminalDark.cursorColor  // #9068f0
    static let accentLight = terminalLight.cursorColor  // #6d43d8
    static let greenDark = termAnsiDark[Slot.green]  // 追加/成功（端末緑と同値）
    static let greenLight = termAnsiLight[Slot.green]
    static let redDark = termAnsiDark[Slot.red]  // 削除/エラー（端末赤と同値）
    static let redLight = termAnsiLight[Slot.red]
    static let yellowDark = termAnsiDark[Slot.yellow]  // 競合/待機（端末黄と同値）
    static let yellowLight = termAnsiLight[Slot.yellow]
  }

  /// chrome が共有する ANSI スロット番地（red/green/yellow）。
  private enum Slot {
    static let red = 1
    static let green = 2
    static let yellow = 3
  }

  // MARK: - コントラストゲートのスロット分類

  /// AA 対象の ink スロット（色 6 種 + コメント用 bright black=8）。
  static let inkSlots: Set<Int> = [1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14]

  /// AA 対象外の構造色スロット。dark 0=最暗・light 7/15=最明の淡色（ANSI 慣習）。
  static let structuralSlots: Set<Int> = [0, 7, 15]

  /// ink だが AA 4.5 を満たさず、確定値ゆえゲートから除外するスロット（モード別）。
  /// 値は人が承認済みの確定配色値で、AA 通過のために色を曲げない方針。
  /// ゲートは残りの ink スロットで 4.5 を守り、将来の回帰は引き続き検出する。
  /// dark: bright black 8（#7a7387 = 3.90）。
  /// light: 赤 1/9（#e02d33 = 4.44）・緑 2/10（#279a4d = 3.50）・黄 3/11（#b17b00 = 3.57）。
  static let aaExemptDark: Set<Int> = [8]
  static let aaExemptLight: Set<Int> = [1, 2, 3, 9, 10, 11]

  // MARK: - conf 生成（端末 view の full codegen）

  enum Mode {
    case dark, light
  }

  /// SSOT から ghostty theme conf を生成する（コミット済み conf と byte 一致・drift ゲートで担保）。
  static func renderConf(_ mode: Mode) -> String {
    let ansi = mode == .dark ? termAnsiDark : termAnsiLight
    let term = mode == .dark ? terminalDark : terminalLight
    var lines = [confHeader(mode)]
    for (slot, color) in ansi.enumerated() {
      lines.append("palette = \(slot)=#\(hex(color))")
    }
    lines.append("background = \(hex(term.background))")
    lines.append("foreground = \(hex(term.foreground))")
    lines.append("cursor-color = \(hex(term.cursorColor))")
    lines.append("cursor-text = \(hex(term.cursorText))")
    lines.append("selection-background = \(hex(term.selectionBackground))")
    lines.append("selection-foreground = \(hex(term.selectionForeground))")
    return lines.joined(separator: "\n") + "\n"
  }

  private static func hex(_ color: Int) -> String {
    String(format: "%06x", color)
  }

  private static func confHeader(_ mode: Mode) -> String {
    switch mode {
    case .dark:
      return """
        # Orbe 端末テーマ（ダーク）— 16 色＋bg/fg/cursor/selection。
        # OrbePalette.swift（識別色 SSOT）が生成。手編集不可（swift test が drift 検出）。
        # 16 色は VS Code Dark+ のシンタックストークン色を ANSI スロットへ再配置した確定配色値。
        # カーソル＝ブランド accent。
        """
    case .light:
      return """
        # Orbe 端末テーマ（ライト）— 16 色＋bg/fg/cursor/selection。
        # OrbePalette.swift（識別色 SSOT）が生成。手編集不可（swift test が drift 検出）。
        # 無彩色ランプ 0/7/15 は Catppuccin Latte 由来（8 のみ AA 是正）。有彩色 1–6 は light 向けの
        # 確定配色値（bright 9–14 は 1–6 のミラー）。
        """
    }
  }

  // MARK: - WCAG コントラスト（コントラストゲートが使う純関数）

  /// WCAG 2.x コントラスト比 (L1+0.05)/(L2+0.05)。foreground/background は 0xRRGGBB。
  static func contrastRatio(_ foreground: Int, _ background: Int) -> Double {
    let lf = relativeLuminance(foreground)
    let lb = relativeLuminance(background)
    return (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
  }

  private static func relativeLuminance(_ color: Int) -> Double {
    let r = linear((color >> 16) & 0xff)
    let g = linear((color >> 8) & 0xff)
    let b = linear(color & 0xff)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }

  private static func linear(_ channel: Int) -> Double {
    let c = Double(channel) / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }
}
