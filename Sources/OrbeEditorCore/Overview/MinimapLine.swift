import Foundation

/// ミニマップに描く字 1 つ——桁（ガターの右から 0 始まり）・字形の番号・役割（無ければ素の文字色）。
public struct MinimapCell: Equatable, Sendable {
  public let column: Int
  public let glyph: Int
  public let role: SyntaxRole?

  public init(column: Int, glyph: Int, role: SyntaxRole?) {
    self.column = column
    self.glyph = glyph
    self.role = role
  }
}

/// ミニマップの行 1 つを字の列にする規則（VS Code `InnerMinimap._renderLine` / `getXOffsetForPosition` / `getCharIndex`）。
/// 字は 1 字 1 桁、全角は 2 桁、空白は描かずに 1 桁進む。タブは字と装飾で数え方が違う——字は次のタブ位置まで空け、
/// 装飾（選択・一致）の x はタブを固定の `tabSize` 桁と数える（VS Code がそう描く）。単位は UTF-16。
public enum MinimapLine {
  /// 字形の数（ASCII 32…126 と U+FFFD）。
  public static let glyphCount = 96
  /// 字の左のガター（デバイス px）。
  public static let gutter = 8

  /// 行の字の列。`units` は行の本文（改行を除く）、`lineStart` はその行頭のオフセット、`roles` は行に掛かる役割の区間
  /// （昇順・重ならない。本文全体のオフセット）。`columns` 桁目以降は描かない（`columns(canvasWidth:scale:)`）。
  public static func cells(
    _ units: some Collection<UInt16>, lineStart: Int, roles: ArraySlice<HighlightSpan>,
    tabSize: Int, columns: Int
  ) -> [MinimapCell] {
    var result: [MinimapCell] = []
    var column = 0
    var tabsDelta = 0
    var role = roles.startIndex
    for (index, unit) in units.enumerated() {
      guard column < columns else { break }
      switch unit {
      case 0x09:
        let spaces = tabSize - (index + tabsDelta) % tabSize
        tabsDelta += spaces - 1
        column += spaces
      case 0x20:
        column += 1
      default:
        let offset = lineStart + index
        while role < roles.endIndex, NSMaxRange(roles[role].range) <= offset { role += 1 }
        let span = role < roles.endIndex && roles[role].range.location <= offset ? roles[role] : nil
        let glyph = glyph(of: unit)
        for _ in 0..<(isFullWidth(unit) ? 2 : 1) {
          guard column < columns else { break }
          result.append(MinimapCell(column: column, glyph: glyph, role: span?.role))
          column += 1
        }
      }
    }
    return result
  }

  /// 行の中の UTF-16 位置 `index` の左端の桁（装飾の x）。タブは `tabSize` 桁、全角は 2 桁。
  public static func decorationColumn(_ units: some Collection<UInt16>, at index: Int, tabSize: Int)
    -> Int
  {
    var column = 0
    for unit in units.prefix(index) {
      column += unit == 0x09 ? tabSize : isFullWidth(unit) ? 2 : 1
    }
    return column
  }

  /// 幅 `canvasWidth` デバイス px・倍率 `scale`（1 字の幅）のミニマップに描ける桁数——字の左端が
  /// `canvasWidth − scale` を越えたら描かない。
  public static func columns(canvasWidth: Int, scale: Int) -> Int {
    guard scale > 0, canvasWidth >= gutter + scale else { return 0 }
    return (canvasWidth - scale - gutter) / scale + 1
  }

  /// 字形の番号。ASCII 32…126 は `code − 32`、ほかは任意の ASCII の字形で代える（VS Code と同じ
  /// `(code − 32 + 96) % 96`）。
  public static func glyph(of unit: UInt16) -> Int {
    let code = Int(unit) - 32
    return code >= 0 && code < glyphCount ? code : (code + glyphCount) % glyphCount
  }

  /// VS Code `strings.isFullWidthCharacter`。
  public static func isFullWidth(_ unit: UInt16) -> Bool {
    (0x2E80...0xD7AF).contains(unit) || (0xF900...0xFAFF).contains(unit)
      || (0xFF01...0xFF5E).contains(unit) || (0xFFE0...0xFFE6).contains(unit)
  }
}
