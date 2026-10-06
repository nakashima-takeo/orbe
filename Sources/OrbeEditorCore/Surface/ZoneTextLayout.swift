import AppKit
import CoreText

/// 区画の字の測りと折り返し（純関数）。面は配置の仕組みを持たないので、載せる側が区画の絵を組むときに使う——面が字を
/// 描くのと同じ Core Text の組版で測るので、測った幅と描いた字が食い違わない。
public enum ZoneTextLayout {
  /// 折り返した 1 行——元の文の中の範囲（改行は含めない）と、その範囲の字の見え方と、行の幅（行末の空白を除く）。
  public struct Line: Equatable {
    public var range: NSRange
    public var styles: [ZoneTextStyle]
    public var width: CGFloat
  }

  /// 文 `string` を、見え方 `styles`（文の先頭から順に当てる）で組み、幅 `width` で行に割る。改行（`\n`）では必ず割る。
  /// 割る位置は Core Text の行の割り方（語の境。日本語は字の境）。空の文は空の 1 行。
  public static func lines(_ string: String, styles: [ZoneTextStyle], width: CGFloat) -> [Line] {
    let units = Array(string.utf16)
    let typesetter = CTTypesetterCreateWithAttributedString(attributedString(units, styles: styles))
    var lines: [Line] = []
    var start = 0
    repeat {
      let end = units[start...].firstIndex(of: 0x0A) ?? units.count
      lines += paragraph(start..<end, typesetter, styles: styles, width: width)
      start = end + 1
    } while start <= units.count
    return lines
  }

  /// 字の連なりを 1 行に組んだ幅（折り返さない）。
  public static func width(_ runs: [ZoneTextRun]) -> CGFloat {
    let string = runs.map(\.string).joined()
    let styles = runs.map {
      ZoneTextStyle(length: $0.string.utf16.count, font: $0.font, color: $0.color)
    }
    let attributed = attributedString(Array(string.utf16), styles: styles)
    let line = CTLineCreateWithAttributedString(attributed)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
  }

  /// 見え方 `styles` の、範囲 `range`（文の中、`styles` の先頭は文の先頭）に掛かる部分（範囲の先頭から）。
  public static func styles(_ styles: [ZoneTextStyle], in range: NSRange) -> [ZoneTextStyle] {
    var result: [ZoneTextStyle] = []
    var offset = 0
    for style in styles {
      let lower = max(offset, range.location)
      let upper = min(offset + style.length, NSMaxRange(range))
      if upper > lower {
        result.append(ZoneTextStyle(length: upper - lower, font: style.font, color: style.color))
      }
      offset += style.length
    }
    return result
  }

  private static func paragraph(
    _ span: Range<Int>, _ typesetter: CTTypesetter, styles: [ZoneTextStyle], width: CGFloat
  ) -> [Line] {
    guard !span.isEmpty else {
      return [Line(range: NSRange(location: span.lowerBound, length: 0), styles: [], width: 0)]
    }
    var lines: [Line] = []
    var start = span.lowerBound
    while start < span.upperBound {
      let suggested = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width)))
      let count = min(max(1, suggested), span.upperBound - start)
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
      let measured =
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
      let range = NSRange(location: start, length: count)
      lines.append(
        Line(range: range, styles: Self.styles(styles, in: range), width: max(0, measured)))
      start += count
    }
    return lines
  }

  private static func attributedString(_ units: [UInt16], styles: [ZoneTextStyle])
    -> CFAttributedString
  {
    let string = units.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let attributed = CFAttributedStringCreateMutable(nil, 0)!
    CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
    var offset = 0
    for style in styles where offset < units.count {
      let length = min(style.length, units.count - offset)
      CFAttributedStringSetAttribute(
        attributed, CFRange(location: offset, length: length), kCTFontAttributeName,
        style.font as CTFont)
      offset += length
    }
    return attributed
  }
}
