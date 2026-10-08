import AppKit
import CoreText

/// 区画の字の組版（純関数）。面は配置の仕組みを持たないので、載せる側が区画の絵を組むときにここで測り、面が描くときにも
/// ここで組む——測りと描きが同じ組み立て（→ `typeset`）を通るので、測った幅・位置と描いた字が食い違わない。
public enum ZoneTextLayout {
  /// 折り返した 1 行——元の文の中の範囲（改行は含めない）と、その範囲の字の見え方と、行の幅（行頭の余白を含み、行末の
  /// 空白を除く）と、見え方ごとの字の x 範囲（行の左端から。余白を含まない）。
  public struct Line: Equatable {
    public var range: NSRange
    public var styles: [ZoneTextStyle]
    public var width: CGFloat
    public var spans: [Range<CGFloat>]
  }

  /// 1 行に組んだもの——組んだ行と、行頭の余白（行の先頭の見え方の前の余白。字はこの幅だけ右から始まる）。
  public struct Typeset {
    public let line: CTLine
    public let inset: CGFloat
  }

  /// 文 `string` を、見え方 `styles`（文の先頭から順に当てる）で組み、幅 `width` で行に割る。改行（`\n`）では必ず割る。
  /// 割る位置は Core Text の行の割り方（語の境。日本語は字の境）。空の文は空の 1 行。
  public static func lines(_ string: String, styles: [ZoneTextStyle], width: CGFloat) -> [Line] {
    let units = Array(string.utf16)
    let typesetter = CTTypesetterCreateWithAttributedString(
      attributed(units, styles: styles).string)
    var lines: [Line] = []
    var start = 0
    repeat {
      let end = units[start...].firstIndex(of: 0x0A) ?? units.count
      lines += paragraph(start..<end, units, typesetter, styles: styles, width: width)
      start = end + 1
    } while start <= units.count
    return lines
  }

  /// 字の連なりを 1 行に組んだ幅（折り返さない。行末の空白を除く）。
  public static func width(_ runs: [ZoneTextRun]) -> CGFloat {
    let styles = runs.map {
      ZoneTextStyle(length: $0.string.utf16.count, font: $0.font, color: $0.color)
    }
    return laid(Array(runs.map(\.string).joined().utf16), styles: styles).width
  }

  /// 文 `string` を見え方 `styles` で 1 行に組む（折り返さない）。組んだ字の連なりは見え方の境で必ず分かれる（→ `style(of:)`）。
  public static func typeset(_ string: String, styles: [ZoneTextStyle]) -> Typeset {
    let line = laid(Array(string.utf16), styles: styles)
    return Typeset(line: line.line, inset: line.inset)
  }

  /// `typeset` で組んだ字の連なりの見え方（`styles` の添字）。
  public static func style(of run: CTRun) -> Int? {
    (CTRunGetAttributes(run) as NSDictionary)[styleAttribute] as? Int
  }

  /// 見え方 `styles` の、範囲 `range`（文の中、`styles` の先頭は文の先頭）に掛かる部分（範囲の先頭から）。範囲の端で
  /// 割れた側の余白は外す。
  public static func styles(_ styles: [ZoneTextStyle], in range: NSRange) -> [ZoneTextStyle] {
    var result: [ZoneTextStyle] = []
    var offset = 0
    for style in styles {
      let lower = max(offset, range.location)
      let upper = min(offset + style.length, NSMaxRange(range))
      if upper > lower {
        var piece = style
        piece.length = upper - lower
        if lower > offset { piece.leadingPadding = 0 }
        if upper < offset + style.length { piece.trailingPadding = 0 }
        result.append(piece)
      }
      offset += style.length
    }
    return result
  }

  /// 見え方の番号を載せる属性（Core Text は属性の違う所で字の連なりを分ける）。
  private static let styleAttribute = "OrbeZoneTextStyle"

  private static func paragraph(
    _ span: Range<Int>, _ units: [UInt16], _ typesetter: CTTypesetter, styles: [ZoneTextStyle],
    width: CGFloat
  ) -> [Line] {
    guard !span.isEmpty else {
      return [
        Line(
          range: NSRange(location: span.lowerBound, length: 0), styles: [], width: 0, spans: [])
      ]
    }
    var lines: [Line] = []
    var start = span.lowerBound
    while start < span.upperBound {
      let inset = leadingPadding(at: start, styles)
      let suggested = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width - inset)))
      let count = min(max(1, suggested), span.upperBound - start)
      let range = NSRange(location: start, length: count)
      let pieces = Self.styles(styles, in: range)
      let line = laid(Array(units[start..<start + count]), styles: pieces)
      lines.append(Line(range: range, styles: pieces, width: line.width, spans: line.spans))
      start += count
    }
    return lines
  }

  /// 文の位置 `offset` で始まる見え方の前の余白（そこで始まる見え方が無ければ 0）。
  private static func leadingPadding(at offset: Int, _ styles: [ZoneTextStyle]) -> CGFloat {
    var start = 0
    for style in styles {
      if start == offset, style.length > 0 { return style.leadingPadding }
      if start > offset { break }
      start += style.length
    }
    return 0
  }

  /// 1 行に組んだ行・行頭の余白・幅（行頭の余白を含み、行末の空白を除く）・見え方ごとの字の x 範囲。
  private struct Laid {
    let line: CTLine
    let inset: CGFloat
    let width: CGFloat
    let spans: [Range<CGFloat>]
  }

  /// 1 行に組む。字の x 範囲は字の位置と送りから引く（位置の境は余白の真ん中に来るので使わない）。
  private static func laid(_ units: [UInt16], styles: [ZoneTextStyle]) -> Laid {
    let (string, kerns) = attributed(units, styles: styles)
    let line = CTLineCreateWithAttributedString(string)
    let inset = styles.first { $0.length > 0 }?.leadingPadding ?? 0
    let width =
      CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
    var found = [Range<CGFloat>?](repeating: nil, count: styles.count)
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0, let index = style(of: run) else { continue }
      var positions = [CGPoint](repeating: .zero, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      var offsets = [CFIndex](repeating: 0, count: count)
      let all = CFRange(location: 0, length: count)
      CTRunGetPositions(run, all, &positions)
      CTRunGetAdvances(run, all, &advances)
      CTRunGetStringIndices(run, all, &offsets)
      for i in 0..<count {
        let lower = inset + positions[i].x
        let upper = lower + max(0, advances[i].width - kerns[offsets[i], default: 0])
        let span = found[index]
        found[index] = min(span?.lowerBound ?? lower, lower)..<max(span?.upperBound ?? upper, upper)
      }
    }
    var spans: [Range<CGFloat>] = []
    for span in found {
      let end = spans.last?.upperBound ?? inset
      spans.append(span ?? end..<end)
    }
    return Laid(line: line, inset: inset, width: inset + max(0, width), spans: spans)
  }

  /// 見え方を当てた属性文字列と、字ごとに足した送り（余白。字の後ろに足す）。前の余白は手前の字の後ろに足す（行頭の見え方
  /// の前の余白は行頭の余白として組む側が持つ）。
  private static func attributed(_ units: [UInt16], styles: [ZoneTextStyle]) -> (
    string: CFAttributedString, kerns: [Int: CGFloat]
  ) {
    let string = units.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let attributed = CFAttributedStringCreateMutable(nil, 0)!
    CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
    var kerns: [Int: CGFloat] = [:]
    var offset = 0
    for (index, style) in styles.enumerated() where offset < units.count {
      let length = min(style.length, units.count - offset)
      let range = CFRange(location: offset, length: length)
      CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, style.font as CTFont)
      CFAttributedStringSetAttribute(
        attributed, range, styleAttribute as CFString, index as NSNumber)
      if length > 0 {
        if offset > 0, style.leadingPadding > 0 {
          kerns[offset - 1, default: 0] += style.leadingPadding
        }
        if style.trailingPadding > 0 {
          kerns[offset + length - 1, default: 0] += style.trailingPadding
        }
      }
      offset += length
    }
    for (index, kern) in kerns {
      CFAttributedStringSetAttribute(
        attributed, CFRange(location: index, length: 1), kCTKernAttributeName, kern as NSNumber)
    }
    return (attributed, kerns)
  }
}
