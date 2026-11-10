import AppKit
import CoreText

/// 絵の差し込みの字の組版（純関数）。面は配置の仕組みを持たない。載せる側は絵を組むときにここで測り、面は
/// 描くときにここで組む——測りと描きが同じ組み立て（→ `typeset`）を通るので、測った幅・位置と描いた字が食い違わない。
public enum ZoneTextLayout {
  /// 折り返した 1 行——元の文の中の範囲（改行は含めない）と、その範囲の字の見え方と、行の幅（左端の余白を含み、行末の
  /// 空白を除く）と、見え方ごとの字の x 範囲（行の左端から。余白と行末の空白を含まない。見え方の字が双方向の並べ替えで
  /// 見た目の 2 か所に分かれれば、両端を結んだ範囲）。行は段落（改行で区切った文）の向きで組む。段落の向きは段落の
  /// 最初の、向きを持つ字で決まり、段落の途中の行も同じ向きで組む。
  public struct Line: Equatable {
    public var range: NSRange
    public var styles: [ZoneTextStyle]
    public var width: CGFloat
    public var spans: [Range<CGFloat>]
    var rightToLeft: Bool

    /// 見え方 `index` の地の x 範囲——字の x 範囲を、見た目の左右の余白の分だけ広げたもの（行に描く字が無ければ空）。
    public func ground(_ index: Int) -> Range<CGFloat> {
      let span = spans[index]
      guard !span.isEmpty else { return span }
      let padding = styles[index].padding(rightToLeft: rightToLeft)
      return span.lowerBound - padding.left..<span.upperBound + padding.right
    }
  }

  /// 1 行に組んだもの——組んだ文の範囲と、組んだ行と、左端の余白（見た目で行の左端に来る見え方の、左の余白。字はこの
  /// 幅だけ右へずらして置く）。
  public struct Typeset {
    public let range: NSRange
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
      let span = paragraphSpan(around: start, in: units)
      lines += paragraph(span, units, styles: styles, width: width)
      start = span.upperBound + 1
    } while start <= units.count
    return lines
  }

  /// 字の連なりを 1 つの段落として 1 行に組んだ幅（折り返さない。行末の空白を除く）。
  public static func width(_ runs: [ZoneTextRun]) -> CGFloat {
    laid(runs).width
  }

  /// 字の連なりを 1 つの段落として 1 行に組む（折り返さない。見え方は連なりごと）。組んだ字の連なりは見え方の境で必ず
  /// 分かれる（→ `style(of:)`）。
  public static func typeset(_ runs: [ZoneTextRun]) -> Typeset {
    let line = laid(runs)
    return Typeset(
      range: NSRange(location: 0, length: runs.reduce(0) { $0 + $1.string.utf16.count }),
      line: line.line, inset: line.inset)
  }

  /// 選べる文のまとまり `text` の行を、`text.lines` の順に 1 行ずつ組む（折り返さない）。行の範囲は文の中へ切り詰める。
  /// 行は範囲を含む段落の向きで組み（→ `Line`）、段落の向きは段落ごとに 1 度だけ求める。組んだ字の連なりは見え方の境で
  /// 必ず分かれる（→ `style(of:)`）。
  public static func typeset(_ text: ZoneText) -> [Typeset] {
    let units = Array(text.string.utf16)
    var paragraph: (span: Range<Int>, rightToLeft: Bool)?
    return text.lines.map { line in
      let lower = min(max(0, line.range.location), units.count)
      let upper = min(max(lower, NSMaxRange(line.range)), units.count)
      let current: (span: Range<Int>, rightToLeft: Bool)
      if let paragraph, (paragraph.span.lowerBound...paragraph.span.upperBound).contains(lower) {
        current = paragraph
      } else {
        let span = paragraphSpan(around: lower, in: units)
        current = (span, isRightToLeft(units[span]))
        paragraph = current
      }
      let set = laid(
        Array(units[lower..<upper]), styles: line.styles, rightToLeft: current.rightToLeft)
      return Typeset(
        range: NSRange(location: lower, length: upper - lower), line: set.line, inset: set.inset)
    }
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
          range: NSRange(location: span.lowerBound, length: 0), styles: [], width: 0, spans: [],
          rightToLeft: false)
      ]
    }
    let rightToLeft = isRightToLeft(units[span])
    let typesetter = CTTypesetterCreateWithAttributedString(
      breaking(
        Array(units[span]), styles: Self.styles(styles, in: NSRange(span)),
        rightToLeft: rightToLeft))
    var lines: [Line] = []
    var start = span.lowerBound
    while start < span.upperBound {
      let leading = leadingPadding(at: start, styles)
      let suggested = CTTypesetterSuggestLineBreak(
        typesetter, start - span.lowerBound, Double(max(1, width - leading)))
      let count = min(max(1, suggested), span.upperBound - start)
      let range = NSRange(location: start, length: count)
      let pieces = Self.styles(styles, in: range)
      let line = laid(Array(units[start..<start + count]), styles: pieces, rightToLeft: rightToLeft)
      lines.append(
        Line(
          range: range, styles: pieces, width: line.width, spans: line.spans,
          rightToLeft: rightToLeft))
      start += count
    }
    return lines
  }

  /// 字の連なりを 1 つの段落として 1 行に組む。段落の向きは連なりをつないだ文の最初の、向きを持つ字で決まる。
  private static func laid(_ runs: [ZoneTextRun]) -> Laid {
    let styles = runs.map {
      ZoneTextStyle(length: $0.string.utf16.count, font: $0.font, color: $0.color)
    }
    let units = Array(runs.map(\.string).joined().utf16)
    return laid(units, styles: styles, rightToLeft: isRightToLeft(units[...]))
  }

  /// 文の位置 `offset` で始まる見え方の先頭の余白（そこで始まる見え方が無ければ 0）。
  private static func leadingPadding(at offset: Int, _ styles: [ZoneTextStyle]) -> CGFloat {
    var start = 0
    for style in styles {
      if start == offset, style.length > 0 { return style.leadingPadding }
      if start > offset { break }
      start += style.length
    }
    return 0
  }

  /// 1 行に組んだ行・左端の余白・幅（左端の余白を含み、行末の空白を除く）・見え方ごとの字の x 範囲。
  private struct Laid {
    let line: CTLine
    let inset: CGFloat
    let width: CGFloat
    let spans: [Range<CGFloat>]
  }

  /// 1 行に組む。字の x 範囲はグリフの位置と送り幅から引き、余白を置いた字の塊では、その余白が乗るグリフ（右端が
  /// 最も右のもの）から余白を引く（位置の境は余白の真ん中に来るので使わない）。
  private static func laid(_ units: [UInt16], styles: [ZoneTextStyle], rightToLeft: Bool) -> Laid {
    let set = padded(units, styles: styles, rightToLeft: rightToLeft)
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
    let hanging = Self.hanging(units)
    var found = [Range<CGFloat>?](repeating: nil, count: styles.count)
    for (i, glyph) in glyphs.enumerated() where glyph.offset < hanging {
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

  /// 余白を置いた属性文字列と、左端の余白と、字の塊（文の範囲）ごとに置いた余白。
  private struct Padded {
    let string: CFAttributedString
    let inset: CGFloat
    let kerns: [Range<Int>: CGFloat]
  }

  /// 余白を、Core Text が 1 つにまとめて組む字の塊（→ `Clusters`）の送りとして置く。見え方の先頭の余白は段落の向きの
  /// 始まりの側（左から右の段落では左、右から左の段落では右）に、末尾の余白はその反対の側に付く。右に付く余白は見え方の
  /// 右端のグリフの塊に、左に付く余白は見え方の左端のグリフのすぐ左に並ぶグリフの塊に送りを置く（すぐ左に字が無ければ
  /// 左端の余白）。送りは塊の最後のグリフの右に空きを作るので、右から左の字でも余白は見え方の字の外に出る（Core Text が
  /// 塊の中をさらに区切る字では、区切りごとに空きができる → `ZoneTextStyle`）。余白が無ければ組まない。
  private static func padded(_ units: [UInt16], styles: [ZoneTextStyle], rightToLeft: Bool)
    -> Padded
  {
    let plain = attributed(units, styles: styles, kerns: [:], rightToLeft: rightToLeft)
    guard styles.contains(where: { $0.leadingPadding > 0 || $0.trailingPadding > 0 }) else {
      return Padded(string: plain, inset: 0, kerns: [:])
    }
    let all = Self.glyphs(of: CTLineCreateWithAttributedString(plain))
    let clusters = Clusters(all, units)
    let hanging = Self.hanging(units)
    let glyphs = all.filter { $0.offset < hanging }
    var kerns: [Range<Int>: CGFloat] = [:]
    var inset: CGFloat = 0
    for (index, style) in styles.enumerated() {
      let padding = style.padding(rightToLeft: rightToLeft)
      let own = glyphs.indices.filter { glyphs[$0].style == index }
      if padding.right > 0,
        let right = own.max(by: { glyphs[$0].x.upperBound < glyphs[$1].x.upperBound })
      {
        kerns[clusters.range(containing: glyphs[right].offset), default: 0] += padding.right
      }
      if padding.left > 0,
        let left = own.min(by: { glyphs[$0].x.lowerBound < glyphs[$1].x.lowerBound })
      {
        let leftCluster = clusters.range(containing: glyphs[left].offset)
        if let neighbour = glyphs[..<left].lastIndex(where: { !leftCluster.contains($0.offset) }) {
          kerns[clusters.range(containing: glyphs[neighbour].offset), default: 0] += padding.left
        } else {
          inset += padding.left
        }
      }
    }
    return Padded(
      string: kerns.isEmpty
        ? plain : attributed(units, styles: styles, kerns: kerns, rightToLeft: rightToLeft),
      inset: inset,
      kerns: kerns)
  }

  /// 行の割り位置を測る属性文字列。余白は文の並びの順に送りとして置く——末尾の余白は見え方の最後の、空白でない字の塊に
  /// （行末に来て幅に入らない空白には乗せない → `hanging(_:)`）、先頭の余白は見え方のすぐ前の字の塊に置く。行の頭で
  /// 始まる見え方の先頭の余白は、その行を割るときに幅から引く（→ `leadingPadding(at:)`）。割った行で外す余白
  /// （→ `styles(_:in:)`）も文の並びの順で決まり、送りの量は組んだ行と同じなので、組んだ行の幅はふつう割るときに測った
  /// 幅と同じになる。ただし、Core Text が和文とほかの字の間に入れる空き（字の大きさの 1/8）の入り方は送りを置く字で
  /// 変わるので、和文と右から左の字のインラインコードが同じ行にあると、組んだ行は割った幅を字の大きさの 1/8 まで
  /// 超える。
  private static func breaking(_ units: [UInt16], styles: [ZoneTextStyle], rightToLeft: Bool)
    -> CFAttributedString
  {
    let plain = attributed(units, styles: styles, kerns: [:], rightToLeft: rightToLeft)
    guard styles.contains(where: { $0.leadingPadding > 0 || $0.trailingPadding > 0 }) else {
      return plain
    }
    let clusters = Clusters(glyphs(of: CTLineCreateWithAttributedString(plain)), units)
    var kerns: [Range<Int>: CGFloat] = [:]
    var offset = 0
    for style in styles {
      let own = offset..<offset + style.length
      if !own.isEmpty, style.trailingPadding > 0 {
        let last = own.last { !isWhitespace(units[$0]) } ?? own.upperBound - 1
        kerns[clusters.range(containing: last), default: 0] += style.trailingPadding
      }
      if !own.isEmpty, style.leadingPadding > 0, offset > 0 {
        kerns[clusters.range(containing: offset - 1), default: 0] += style.leadingPadding
      }
      offset += style.length
    }
    return attributed(units, styles: styles, kerns: kerns, rightToLeft: rightToLeft)
  }

  /// 見え方と、字の塊ごとの余白 `kerns` を当て、段落の向きを `rightToLeft` に決めた属性文字列。
  private static func attributed(
    _ units: [UInt16], styles: [ZoneTextStyle], kerns: [Range<Int>: CGFloat], rightToLeft: Bool
  ) -> CFAttributedString {
    let string = units.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let attributed = CFAttributedStringCreateMutable(nil, 0)!
    CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
    var direction: CTWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
    let paragraph = withUnsafeBytes(of: &direction) {
      var setting = CTParagraphStyleSetting(
        spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
        value: $0.baseAddress!)
      return CTParagraphStyleCreate(&setting, 1)
    }
    CFAttributedStringSetAttribute(
      attributed, CFRange(location: 0, length: units.count), kCTParagraphStyleAttributeName,
      paragraph)
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

extension ZoneTextLayout {
  /// 文の位置 `offset` を含む段落（改行で区切った文。改行は含めない）の範囲。`offset` が改行の位置のときは、その改行で
  /// 終わる段落の範囲を返す。
  private static func paragraphSpan(around offset: Int, in units: [UInt16]) -> Range<Int> {
    let start = units[..<offset].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
    return start..<(units[offset...].firstIndex(of: 0x0A) ?? units.count)
  }

  /// 段落 `units` が右から左か——段落の最初の、向きを持つ字で決まる（UAX #9 の P2・P3。向きを持つ字が無ければ左から
  /// 右）。Core Text は段落の向きを返さないので、末尾に空白を 1 つ足して組み、その空白の向きを読む（行末の空白は段落の
  /// 向きで組まれる。UAX #9 の L1）。
  private static func isRightToLeft(_ units: ArraySlice<UInt16>) -> Bool {
    let probe = Array(units) + [0x20]
    let string = probe.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string, nil))
    let space = probe.count - 1
    let run = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).first {
      let range = CTRunGetStringRange($0)
      return range.location <= space && space < range.location + range.length
    }
    return run.map { CTRunGetStatus($0).contains(.rightToLeft) } ?? false
  }

  /// 行末の空白の始まり（文の位置）。行末の空白は行の幅に入らず、行の見た目の端の外に出る（右から左の行では左の外）ので、
  /// 字の x 範囲にも余白の置き場にも数えない。
  private static func hanging(_ units: [UInt16]) -> Int {
    (units.lastIndex { !isWhitespace($0) } ?? -1) + 1
  }

  /// 単位 `unit` が空白の字か（サロゲートの片割れは空白でない）。
  private static func isWhitespace(_ unit: UInt16) -> Bool {
    Unicode.Scalar(unit)?.properties.isWhitespace ?? false
  }
}

extension ZoneTextStyle {
  /// 見た目の左と右の余白——先頭の余白は段落の向きの始まりの側に、末尾の余白はその反対の側に付く。
  fileprivate func padding(rightToLeft: Bool) -> (left: CGFloat, right: CGFloat) {
    rightToLeft ? (trailingPadding, leadingPadding) : (leadingPadding, trailingPadding)
  }
}
