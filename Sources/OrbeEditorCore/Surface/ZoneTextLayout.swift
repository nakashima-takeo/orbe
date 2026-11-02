import AppKit
import CoreText

/// 絵の差し込みの字の組版（純関数）。面は配置の仕組みを持たない。載せる側は中身を組むときにここで測り、面は
/// 描くときにここで組む——測りと描きが同じ組み立て（→ `typeset`）を通るので、測った幅・位置と描いた字が食い違わない。
public enum ZoneTextLayout {
  /// 折り返した 1 行——元の文の中の範囲（改行は含めない）と、その範囲の字の見え方と、行の幅（行頭の余白を含み、行末の
  /// 空白を除く）と、見え方ごとの字の x 範囲（行の左端から。余白を含まない）。
  public struct Line: Equatable {
    public var range: NSRange
    public var styles: [ZoneTextStyle]
    public var width: CGFloat
    public var spans: [Range<CGFloat>]
  }

  /// 1 行に組んだもの——組んだ行と、行頭の余白（見た目で左端の見え方の左の余白。字はこの幅だけ右から始まる）。
  public struct Typeset {
    public let line: CTLine
    public let inset: CGFloat
  }

  /// 文 `string` を、見え方 `styles`（文の先頭から順に当てる）で組み、幅 `width` で行に割る。改行（`\n`）では必ず割る。
  /// 割る位置は Core Text の行の割り方（語の境。日本語は字の境）。空の文は空の 1 行。
  public static func lines(_ string: String, styles: [ZoneTextStyle], width: CGFloat) -> [Line] {
    let units = Array(string.utf16)
    var lines: [Line] = []
    var start = 0
    repeat {
      let end = units[start...].firstIndex(of: 0x0A) ?? units.count
      lines += paragraph(start..<end, units, styles: styles, width: width)
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
    _ span: Range<Int>, _ units: [UInt16], styles: [ZoneTextStyle], width: CGFloat
  ) -> [Line] {
    guard !span.isEmpty else {
      return [
        Line(
          range: NSRange(location: span.lowerBound, length: 0), styles: [], width: 0, spans: [])
      ]
    }
    let typesetter = CTTypesetterCreateWithAttributedString(
      padded(Array(units[span]), styles: Self.styles(styles, in: NSRange(span))).string)
    var lines: [Line] = []
    var start = span.lowerBound
    while start < span.upperBound {
      let inset = leadingPadding(at: start, styles)
      let suggested = CTTypesetterSuggestLineBreak(
        typesetter, start - span.lowerBound, Double(max(1, width - inset)))
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

  /// 1 行に組む。字の x 範囲はグリフの位置と送り幅から引き、余白の送りを置いた字の塊では、その送りが乗るグリフ（右端が
  /// 最も右のもの）から送りを引く（位置の境は余白の真ん中に来るので使わない）。
  private static func laid(_ units: [UInt16], styles: [ZoneTextStyle]) -> Laid {
    let set = padded(units, styles: styles)
    let line = CTLineCreateWithAttributedString(set.string)
    let width =
      CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
    let glyphs = Self.glyphs(of: line)
    var kerned: [Int: CGFloat] = [:]
    for (cluster, kern) in set.kerns {
      let carrier = glyphs.indices.filter { cluster.contains(glyphs[$0].offset) }
        .max { glyphs[$0].x.upperBound < glyphs[$1].x.upperBound }
      if let carrier { kerned[carrier] = kern }
    }
    var found = [Range<CGFloat>?](repeating: nil, count: styles.count)
    for (i, glyph) in glyphs.enumerated() {
      guard let index = glyph.style, found.indices.contains(index) else { continue }
      let lower = set.inset + glyph.x.lowerBound
      let upper = max(lower, set.inset + glyph.x.upperBound - kerned[i, default: 0])
      let span = found[index]
      found[index] = min(span?.lowerBound ?? lower, lower)..<max(span?.upperBound ?? upper, upper)
    }
    var spans: [Range<CGFloat>] = []
    for span in found {
      let end = spans.last?.upperBound ?? set.inset
      spans.append(span ?? end..<end)
    }
    return Laid(line: line, inset: set.inset, width: set.inset + max(0, width), spans: spans)
  }

  /// 余白を置いた属性文字列と、行頭の余白と、送りを置いた字の塊（文の範囲）ごとの送り。
  private struct Padded {
    let string: CFAttributedString
    let inset: CGFloat
    let kerns: [Range<Int>: CGFloat]
  }

  /// 余白を、Core Text が 1 つにまとめて組む字の塊（→ `Clusters`）の送りとして置く。右の余白は見え方の右端のグリフの
  /// 塊に、左の余白は見え方の左端のグリフのすぐ左に並ぶグリフの塊に送りを置く（すぐ左に字が無ければ行頭の余白）。送りは
  /// 塊の最後のグリフの右に空きを作るので、左右は見た目で決まり、右から左の字でも余白は見え方の字の外に出る。余白が
  /// 無ければ組まない。
  private static func padded(_ units: [UInt16], styles: [ZoneTextStyle]) -> Padded {
    let plain = attributed(units, styles: styles, kerns: [:])
    guard styles.contains(where: { $0.leadingPadding > 0 || $0.trailingPadding > 0 }) else {
      return Padded(string: plain, inset: 0, kerns: [:])
    }
    let glyphs = Self.glyphs(of: CTLineCreateWithAttributedString(plain))
    let clusters = Clusters(glyphs, units)
    var kerns: [Range<Int>: CGFloat] = [:]
    var inset: CGFloat = 0
    for (index, style) in styles.enumerated() {
      let own = glyphs.indices.filter { glyphs[$0].style == index }
      if style.trailingPadding > 0,
        let right = own.max(by: { glyphs[$0].x.upperBound < glyphs[$1].x.upperBound })
      {
        kerns[clusters.range(containing: glyphs[right].offset), default: 0] += style.trailingPadding
      }
      if style.leadingPadding > 0,
        let left = own.min(by: { glyphs[$0].x.lowerBound < glyphs[$1].x.lowerBound })
      {
        let leftCluster = clusters.range(containing: glyphs[left].offset)
        if let neighbour = glyphs[..<left].lastIndex(where: { !leftCluster.contains($0.offset) }) {
          kerns[clusters.range(containing: glyphs[neighbour].offset), default: 0] +=
            style.leadingPadding
        } else {
          inset += style.leadingPadding
        }
      }
    }
    return Padded(
      string: kerns.isEmpty ? plain : attributed(units, styles: styles, kerns: kerns), inset: inset,
      kerns: kerns)
  }

  /// 字の塊の区切り——余白なしで組んだ行のグリフの文字の位置のうち、書記素の境に当たるもの。結合記号を基底と別のグリフで
  /// 描く字体でも、記号は基底と同じ塊に入る。
  private struct Clusters {
    let starts: [Int]
    let end: Int

    init(_ glyphs: [Glyph], _ units: [UInt16]) {
      var boundaries: Set<Int> = []
      var position = 0
      for character in String(decoding: units, as: UTF16.self) {
        boundaries.insert(position)
        position += character.utf16.count
      }
      starts = Set(glyphs.map(\.offset)).intersection(boundaries).sorted()
      end = units.count
    }

    /// 文の位置 `offset` を含む塊（文の範囲）。
    func range(containing offset: Int) -> Range<Int> {
      guard let index = starts.lastIndex(where: { $0 <= offset }) else {
        return 0..<(starts.first ?? end)
      }
      return starts[index]..<(index + 1 < starts.count ? starts[index + 1] : end)
    }
  }

  /// 組んだ行のグリフ 1 つ——見え方（`styles` の添字）・文の位置・x 範囲（行の左端から。送りを含む）。
  private struct Glyph {
    let style: Int?
    let offset: Int
    let x: Range<CGFloat>
  }

  /// 組んだ行のグリフ（見た目の左から順に）。
  private static func glyphs(of line: CTLine) -> [Glyph] {
    var result: [Glyph] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      let index = style(of: run)
      var positions = [CGPoint](repeating: .zero, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      var offsets = [CFIndex](repeating: 0, count: count)
      let all = CFRange(location: 0, length: count)
      CTRunGetPositions(run, all, &positions)
      CTRunGetAdvances(run, all, &advances)
      CTRunGetStringIndices(run, all, &offsets)
      for i in 0..<count {
        let lower = positions[i].x
        result.append(
          Glyph(
            style: index, offset: offsets[i],
            x: lower..<max(lower, lower + advances[i].width)))
      }
    }
    return result
  }

  /// 見え方と送り `kerns`（字の塊ごと）を当てた属性文字列。
  private static func attributed(
    _ units: [UInt16], styles: [ZoneTextStyle], kerns: [Range<Int>: CGFloat]
  ) -> CFAttributedString {
    let string = units.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let attributed = CFAttributedStringCreateMutable(nil, 0)!
    CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
    var offset = 0
    for (index, style) in styles.enumerated() where offset < units.count {
      let length = min(style.length, units.count - offset)
      let range = CFRange(location: offset, length: length)
      CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, style.font as CTFont)
      CFAttributedStringSetAttribute(
        attributed, range, styleAttribute as CFString, index as NSNumber)
      offset += length
    }
    for (cluster, kern) in kerns {
      CFAttributedStringSetAttribute(
        attributed, CFRange(location: cluster.lowerBound, length: cluster.count),
        kCTKernAttributeName, kern as NSNumber)
    }
    return attributed
  }
}
