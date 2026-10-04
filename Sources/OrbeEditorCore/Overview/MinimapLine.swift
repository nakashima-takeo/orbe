import Foundation

/// ミニマップの行 1 つを字の列にする規則（VS Code `InnerMinimap._renderLine` / `getXOffsetForPosition` / `getCharIndex`）。
/// 字は 1 字 1 桁、全角は 2 桁、空白は描かずに 1 桁進む。タブは字と装飾で数え方が違う——字は次のタブ位置まで空け、
/// 装飾（選択・一致）の x はタブを固定の `tabSize` 桁と数える（VS Code がそう描く）。単位は UTF-16。
public enum MinimapLine {
  /// 字形の数（ASCII 32…126 と U+FFFD）。
  public static let glyphCount = 96
  /// 字の左のガター（デバイス px）。
  public static let gutter = 8

  /// 行の字を左から順に `body`（桁・字形の番号・行の中の UTF-16 位置）へ渡す。`units` は行の本文（改行を除く）で、
  /// `columns` 桁目以降は描かない（`columns(canvasWidth:scale:)`）。
  @inlinable public static func forEachCell(
    _ units: some Collection<UInt16>, tabSize: Int, columns: Int,
    _ body: (_ column: Int, _ glyph: Int, _ index: Int) -> Void
  ) {
    var column = 0
    var tabsDelta = 0
    var index = 0
    for unit in units {
      guard column < columns else { break }
      switch unit {
      case 0x09:
        let spaces = tabSize - (index + tabsDelta) % tabSize
        tabsDelta += spaces - 1
        column += spaces
      case 0x20:
        column += 1
      default:
        let glyph = glyph(of: unit)
        for _ in 0..<(CharacterWidth.isFullWidth(UInt32(unit)) ? 2 : 1) {
          guard column < columns else { break }
          body(column, glyph, index)
          column += 1
        }
      }
      index += 1
    }
  }

  /// 装飾（選択・一致）の x で字 1 つが進める桁（タブは `tabSize` 桁、全角は 2 桁）。
  @inlinable public static func decorationWidth(of unit: UInt16, tabSize: Int) -> Int {
    unit == 0x09 ? tabSize : CharacterWidth.isFullWidth(UInt32(unit)) ? 2 : 1
  }

  /// 幅 `canvasWidth` デバイス px・倍率 `scale`（1 字の幅）のミニマップに描ける桁数——字の左端が
  /// `canvasWidth − scale` を越えたら描かない。
  public static func columns(canvasWidth: Int, scale: Int) -> Int {
    guard scale > 0, canvasWidth >= gutter + scale else { return 0 }
    return (canvasWidth - scale - gutter) / scale + 1
  }

  /// 字形の番号。ASCII 32…126 は `code − 32`、ほかは任意の ASCII の字形で代える（VS Code と同じ
  /// `(code − 32 + 96) % 96`）。
  @inlinable public static func glyph(of unit: UInt16) -> Int {
    let code = Int(unit) - 32
    return code >= 0 && code < glyphCount ? code : (code + glyphCount) % glyphCount
  }

}
