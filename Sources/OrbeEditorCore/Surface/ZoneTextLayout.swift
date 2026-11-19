import AppKit
import CoreText

/// 絵の差し込みの字の組版（純関数）。面は配置の仕組みを持たない。載せる側は絵を組むときにここで測り（`lines(_:styles:width:)`。
/// どのスレッドからも呼べ、結果は値で main へ渡せる）、面は描くときに測った行の範囲で組む（`lines(of:)`）——どちらも段落を
/// 1 回組んだもの（→ `ZoneComposition`）から行を切り出すので、測った幅・位置と描いた字が食い違わない。
///
/// 余白のある見え方（インラインコード）は、余白の幅を持つ見えない字（置き字）で包み、周りの文と独立した向きのかたまりとして
/// 並べる。並べ替え・折り返し・和文との間の空きは Core Text が決める。字組みの口は元の文の位置だけで答え、置き字と制御字は
/// 口の外へ出ない。
public enum ZoneTextLayout {
  /// 測った 1 行——元の文の中の範囲（改行は含めない）と、行の幅（行末の空白を除く）と、見え方ごとの地の x 範囲の列。値だけを
  /// 持ち、どのスレッドへも渡せる。行は段落（改行で区切った文）の向きで組む。段落の向きは段落の最初の、向きを持つ字で
  /// 決まり、段落の途中の行も同じ向きで組む。
  public struct Line: Sendable, Equatable {
    public let range: NSRange
    public let width: CGFloat
    /// 見え方の番号 → 地の x 範囲の列（行に字の無い見え方は持たない）。
    let grounds: [Int: [Range<CGFloat>]]

    /// 見え方 `style` の地の x 範囲の列（行の左端から、見た目の左から順に。行末の空白を含まない）。余白のある見え方は
    /// 置き字を含み、1 行の中で必ず 1 つの続いた範囲になる。ほかの見え方は、双方向の並べ替えで見た目の何か所かに分かれうる。
    public func spans(of style: Int) -> [Range<CGFloat>] { grounds[style] ?? [] }
  }

  /// 組んだ 1 行——測った行と同じ範囲・幅に、描くグリフと当たりとキャレットの答えを足したもの（面が描くときに使う）。
  public struct TypesetLine {
    public let range: NSRange
    public let width: CGFloat
    let line: CTLine
    /// 組んだ文の中の行の範囲。
    let composedRange: Range<Int>
    let composition: ZoneComposition

    init(_ composition: ZoneComposition, _ composedRange: Range<Int>) {
      let line = composition.line(composedRange)
      let lower = composition.original(composedRange.lowerBound)
      self.line = line
      self.composedRange = composedRange
      self.composition = composition
      range = NSRange(
        location: lower, length: composition.original(composedRange.upperBound) - lower)
      width = max(
        0,
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
          - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
    }

    /// 行の左端から x の所にいちばん近い、元の文の位置（行の範囲の中）。置き字の上はコードの端に当たる——置き字の
    /// グリフの上かを先に見る（Core Text の位置の当て方は、利用者の文の双方向の制御字があると置き字の外の字を返しうる）。
    public func offset(atX x: CGFloat) -> Int {
      guard x > 0 else { return range.location }
      guard x < width else { return NSMaxRange(range) }
      var edge: Int?
      forEachGlyph { index, extent in
        if edge == nil, composition.placeholders.contains(index), extent.contains(x) {
          edge = composition.original(index)
        }
      }
      let offset =
        edge
        ?? composition.original(CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0)))
      return min(max(range.location, offset), NSMaxRange(range))
    }

    /// 元の文の位置 `offset` のキャレットの、行の左端からの x。コードの始まりと終わりは、置き字の外側。
    public func x(of offset: Int) -> CGFloat {
      let clamped = min(max(range.location, offset), NSMaxRange(range))
      let index = min(
        max(composedRange.lowerBound, composition.composed(clamped)), composedRange.upperBound)
      return CTLineGetOffsetForStringIndex(line, index, nil)
    }

    /// 見え方 `style` の地の x 範囲の列（→ `Line.spans(of:)`）。
    func spans(of style: Int) -> [Range<CGFloat>] { grounds()[style] ?? [] }

    /// 測った行（値）。
    var measured: Line { Line(range: range, width: width, grounds: grounds()) }

    /// 見え方の番号 → 地の x 範囲の列。グリフを見た目の左から並べ、同じ見え方の続いたグリフを 1 つの範囲にまとめる。
    func grounds() -> [Int: [Range<CGFloat>]] {
      let hanging = hangingStart
      var glyphs: [(x: Range<CGFloat>, owner: Int32)] = []
      forEachGlyph { index, x in
        guard index < hanging, !x.isEmpty else { return }
        glyphs.append((x, composition.owners[index]))
      }
      glyphs.sort { $0.x.lowerBound < $1.x.lowerBound }
      var grounds: [Int: [Range<CGFloat>]] = [:]
      var open: (owner: Int32, x: Range<CGFloat>)?
      for glyph in glyphs {
        if let current = open, current.owner == glyph.owner {
          open = (
            current.owner, current.x.lowerBound..<max(current.x.upperBound, glyph.x.upperBound)
          )
          continue
        }
        if let current = open, current.owner >= 0 {
          grounds[Int(current.owner), default: []].append(current.x)
        }
        open = (glyph.owner, glyph.x)
      }
      if let current = open, current.owner >= 0 {
        grounds[Int(current.owner), default: []].append(current.x)
      }
      return grounds
    }

    /// 描くグリフの連なり（見え方ごと。置き字と制御字は含まない）。
    public var runs: [GlyphRun] {
      (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).compactMap { run in
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let count = CTRunGetGlyphCount(run)
        guard count > 0, let style = attributes[ZoneComposition.styleAttribute] as? Int,
          let value = attributes[kCTFontAttributeName]
        else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        let all = CFRange(location: 0, length: count)
        CTRunGetGlyphs(run, all, &glyphs)
        CTRunGetPositions(run, all, &positions)
        // swiftlint:disable:next force_cast
        return GlyphRun(style: style, font: value as! CTFont, glyphs: glyphs, positions: positions)
      }
    }

    /// 行末の空白の始まり（組んだ文の位置）。
    var hangingStart: Int {
      var index = composedRange.upperBound
      while index > composedRange.lowerBound, composition.whitespace[index - 1] { index -= 1 }
      return index
    }

    /// 組んだ行のグリフごとに、組んだ文の位置と x 範囲を渡す。
    func forEachGlyph(_ body: (Int, Range<CGFloat>) -> Void) {
      for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { continue }
        var positions = [CGPoint](repeating: .zero, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        let all = CFRange(location: 0, length: count)
        CTRunGetPositions(run, all, &positions)
        CTRunGetAdvances(run, all, &advances)
        CTRunGetStringIndices(run, all, &indices)
        for i in 0..<count {
          let lower = positions[i].x
          body(indices[i], lower..<max(lower, lower + advances[i].width))
        }
      }
    }
  }

  /// 見え方 1 つのグリフの連なり——見え方の番号（組んだときの見え方の列の添字）・字体・グリフと、行の左端・基線からの位置。
  public struct GlyphRun {
    public let style: Int
    public let font: CTFont
    public let glyphs: [CGGlyph]
    public let positions: [CGPoint]
  }

  /// 見え方つきの文 `text` を組み、幅 `width` で行に割って測る。どのスレッドからも呼べる
  /// （載せる側は裏で測り、結果の行を main で覚えて、絵を問われたら覚えから組める）。改行（`\n`）では必ず割る。
  /// 割る位置は、余白を付けずに組んだ段落で Core Text が選ぶ位置だけ（語の境。日本語は字の境。禁則も余白なしと同じ）で、
  /// 置き字はコードから離れない。余白を付けた行が幅に収まる所で割り、語が幅に入らなければ、余白なしで狭い幅に組んだとき
  /// と同じく語の途中で割る。1 つの割れない塊（字 1 つなど）と余白が幅に入らない行だけが幅を超える。空の文は空の 1 行。
  public static func lines(_ text: ZoneStyledText, width: CGFloat) -> [Line] {
    typeset(text, width: width).map(\.measured)
  }

  /// 文を幅で行に割り、組んだ行を返す（測る口と、測った行を確かめる所が使う）。
  static func typeset(_ text: ZoneStyledText, width: CGFloat) -> [TypesetLine] {
    let units = Array(text.string.utf16)
    var lines: [TypesetLine] = []
    var start = 0
    repeat {
      let span = paragraphSpan(around: start, in: units)
      let composition = ZoneComposition(units, paragraph: span, styles: text.styles)
      let bare = ZoneComposition(units, paragraph: span, styles: text.styles.map(\.bare))
      lines += wrap(composition, breakingAs: bare, width: width)
      start = span.upperBound + 1
    } while start <= units.count
    return lines
  }

  /// 選べる文のまとまり `text` の行を、`text.lines` の順に組む（折り返さない）。行の範囲は、範囲の始まりを含む段落の中へ
  /// 切り詰める。段落は 1 回だけ組み、同じ段落の行はそこから切り出す——`lines` で測った行と同じ字組みになる。
  public static func lines(of text: ZoneText) -> [TypesetLine] {
    let units = Array(text.content.string.utf16)
    var composition: ZoneComposition?
    return text.lines.map { line in
      let lower = min(max(0, line.range.location), units.count)
      let current: ZoneComposition
      if let composition,
        (composition.paragraph.lowerBound...composition.paragraph.upperBound).contains(lower)
      {
        current = composition
      } else {
        current = ZoneComposition(
          units, paragraph: paragraphSpan(around: lower, in: units), styles: text.content.styles)
        composition = current
      }
      let upper = min(max(lower, NSMaxRange(line.range)), current.paragraph.upperBound)
      let from = current.composed(lower)
      return TypesetLine(current, from..<max(from, current.composed(upper)))
    }
  }

  /// 字の連なりを 1 つの段落として 1 行に組む（折り返さない。見え方の番号は連なりの添字）。
  public static func line(_ runs: [ZoneTextRun]) -> TypesetLine {
    let text = ZoneStyledText(
      runs.map { ($0.string, ZoneTextStyle(font: $0.font, color: $0.color)) })
    let units = Array(text.string.utf16)
    let composition = ZoneComposition(units, paragraph: 0..<units.count, styles: text.styles)
    return TypesetLine(composition, 0..<composition.count)
  }

  /// 字の連なりを 1 つの段落として 1 行に組んだ幅（折り返さない。行末の空白を除く）。
  public static func width(_ runs: [ZoneTextRun]) -> CGFloat {
    line(runs).width
  }

  /// 段落を幅 `width` で行に割る。割る位置は、同じ段落を余白を付けずに組んだもの `bare`（元の文と同じ並び）で Core Text が
  /// 選ぶ位置だけ——余白を付けても、余白なしでは割れない所（コードの外の語の続き・禁則）で割れない。行は余白を付けて組んだ
  /// 幅で確かめ、幅を超えれば、余白なしで探す幅を超えた分だけ狭めて探し直す（行は短くなるだけで、狭め方は倍々に広げる
  /// ので、探し直しは数回で止まる）。それ以上狭められない（行が 1 つの割れない塊だけ）ときは、その行が幅を超える。行の境は元の文の位置から組んだ
  /// 文の境へ写す（コードの始まりは包みの頭の前、終わりは包みの尾の後）——描く側（`lines(of:)`）も同じ境を引く。余白なしで
  /// 探すのは、置き字の run delegate があると、Core Text が分け目を 1 つ探す仕事が段落の終わりまでの長さに比例するため
  /// でもある（余白なしで探せば、段落を割る仕事は段落の長さに比例する）。
  private static func wrap(
    _ composition: ZoneComposition, breakingAs bare: ZoneComposition, width: CGFloat
  ) -> [TypesetLine] {
    let paragraph = composition.paragraph
    guard !paragraph.isEmpty else { return [TypesetLine(composition, 0..<0)] }
    let limit = Double(max(1, width))
    var lines: [TypesetLine] = []
    var start = paragraph.lowerBound
    while start < paragraph.upperBound {
      let from = start - paragraph.lowerBound
      let breakAt = { (width: Double) in
        start + max(1, CTTypesetterSuggestLineBreak(bare.typesetter, from, max(0, width)))
      }
      var available = limit
      var end = breakAt(available)
      var line = TypesetLine(composition, composition.composed(start)..<composition.composed(end))
      while Double(line.width) > limit {
        let bareWidth = Double(TypesetLine(bare, from..<end - paragraph.lowerBound).width)
        available = min(available - (Double(line.width) - limit), bareWidth)
        var shorter = breakAt(available)
        // Core Text は約物を詰めて、測った幅より少し広い行も幅に収める。収めた分だけ狭めて探す。
        var step = 1.0
        while shorter >= end, available > 0 {
          available -= step
          step *= 2
          shorter = breakAt(available)
        }
        guard shorter < end else { break }
        end = shorter
        line = TypesetLine(composition, composition.composed(start)..<composition.composed(end))
      }
      lines.append(line)
      start = end
    }
    return lines
  }

  /// 文の位置 `offset` を含む段落（改行で区切った文。改行は含めない）の範囲。`offset` が改行の位置のときは、その改行で
  /// 終わる段落の範囲を返す。
  private static func paragraphSpan(around offset: Int, in units: [UInt16]) -> Range<Int> {
    let start = units[..<offset].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
    return start..<(units[offset...].firstIndex(of: 0x0A) ?? units.count)
  }
}
