import AppKit
import CoreText

/// 絵の差し込みの字の組版（純関数）。面は配置の仕組みを持たない。載せる側は選べる文をここで組み（`typeset(_:width:)`。
/// どのスレッドからも呼べ、組んだものは main へ渡せる）、組んだ行の範囲・幅・地で飾りを置き、組んだものを絵に渡す——面は
/// 渡された組んだ行をそのまま描き、当たりと選択に使うので、飾りを置いた幅・位置と描いた字が食い違わない。
///
/// 余白のある見え方（インラインコード）は、余白の幅を持つ見えない字（置き字）で包み、周りの文と独立した向きのかたまりとして
/// 並べる。並べ替え・折り返し・和文との間の空きは Core Text が決める。字組みの口は元の文の位置だけで答え、置き字と制御字は
/// 口の外へ出ない。
public enum ZoneTextLayout {
  /// 組んだ 1 行——元の文の中の範囲（改行は含めない）と、行の幅（行末の空白を除く）と、見え方ごとの地の x 範囲と、描く
  /// グリフの連なりと、当たりとキャレットの答え。行は段落（改行で区切った文）の向きで組む。段落の向きは段落の最初の、
  /// 向きを持つ字で決まり、段落の途中の行も同じ向きで組む。
  public struct TypesetLine {
    public let range: NSRange
    public let width: CGFloat
    /// 描くグリフの連なり（見え方ごと。置き字と制御字は含まない）。
    public let runs: [GlyphRun]
    let line: CTLine
    /// 組んだ文の中の行の範囲。
    let composedRange: Range<Int>
    let composition: ZoneComposition
    /// 見え方の番号 → 地の x 範囲の列（行に字の無い見え方は持たない）。
    private let grounds: [Int: [Range<CGFloat>]]

    init(_ composition: ZoneComposition, _ composedRange: Range<Int>) {
      let line = composition.line(composedRange)
      let lower = composition.original(composedRange.lowerBound)
      self.line = line
      self.composedRange = composedRange
      self.composition = composition
      range = NSRange(
        location: lower, length: composition.original(composedRange.upperBound) - lower)
      width = ZoneComposition.width(of: line)
      runs = Self.runs(of: line)
      grounds = Self.grounds(of: line, composedRange, composition)
    }

    /// 見え方 `style` の地の x 範囲の列（行の左端から、見た目の左から順に。行末の空白を含まない）。余白のある見え方は
    /// 置き字を含み、1 行の中で必ず 1 つの続いた範囲になる。ほかの見え方は、双方向の並べ替えで見た目の何か所かに分かれうる。
    public func spans(of style: Int) -> [Range<CGFloat>] { grounds[style] ?? [] }

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

    /// 見え方の番号 → 地の x 範囲の列。グリフを見た目の左から並べ、同じ見え方の続いたグリフを 1 つの範囲にまとめる。
    private static func grounds(
      of line: CTLine, _ composedRange: Range<Int>, _ composition: ZoneComposition
    ) -> [Int: [Range<CGFloat>]] {
      let hanging = hangingStart(composedRange, composition)
      var glyphs: [(x: Range<CGFloat>, owner: Int32)] = []
      forEachGlyph(of: line) { index, x in
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

    /// 組んだ行の、描くグリフの連なり。
    private static func runs(of line: CTLine) -> [GlyphRun] {
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
        let raised = positions.contains { $0.y != 0 }
        return GlyphRun(
          // swiftlint:disable:next force_cast
          style: style, font: value as! CTFont, glyphs: glyphs,
          xs: positions.map { Float($0.x) }, ys: raised ? positions.map { Float($0.y) } : [])
      }
    }

    /// 行末の空白の始まり（組んだ文の位置）。
    var hangingStart: Int { Self.hangingStart(composedRange, composition) }

    private static func hangingStart(_ composedRange: Range<Int>, _ composition: ZoneComposition)
      -> Int
    {
      var index = composedRange.upperBound
      while index > composedRange.lowerBound, composition.whitespace[index - 1] { index -= 1 }
      return index
    }

    /// 組んだ行のグリフごとに、組んだ文の位置と x 範囲を渡す。
    func forEachGlyph(_ body: (Int, Range<CGFloat>) -> Void) {
      Self.forEachGlyph(of: line, body)
    }

    /// 組んだ行 `line` のグリフごとに、組んだ文の位置と x 範囲を渡す。
    private static func forEachGlyph(of line: CTLine, _ body: (Int, Range<CGFloat>) -> Void) {
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

  /// 見え方 1 つのグリフの連なり——見え方の番号（組んだときの見え方の列の添字）・字体・グリフと、行の左端からの x・
  /// 基線からの上向きのずれ（どのグリフも基線の上なら空）。外観に依らない。
  public struct GlyphRun {
    public let style: Int
    public let font: CTFont
    public let glyphs: [CGGlyph]
    public let xs: [Float]
    public let ys: [Float]
  }

  /// 見え方つきの文 `text` を組み、幅 `width` で行に割る。どのスレッドからも呼べる（載せる側は裏で組み、組んだものを main で
  /// 覚えて、絵を問われたら覚えから絵を組める）。改行（`\n`）では必ず割る。
  /// 割る位置は、余白を付けずに組んだ段落で Core Text が選ぶ位置だけ（語の境。日本語は字の境。禁則も余白なしと同じ）で、
  /// 置き字はコードから離れない。余白を付けた行が幅に収まる所で割り、語が幅に入らなければ、余白なしで狭い幅に組んだとき
  /// と同じく語の途中で割る。1 つの割れない塊（字 1 つなど）と余白が幅に入らない行だけが幅を超える。空の文は空の 1 行。
  /// 4,096 字を超える段落は区切って組む。行を組む文（行の頭の 512 字前から区切りの終わりまで）の外の字は、段落の向き・
  /// 文の頭で開いている埋め込み・上書き・isolate（コードの中で開いたものを除く）・文の端で切れたコードの向きとしてだけ
  /// 効く。そのため字の向きが文の外の字で決まる所では、段落を丸ごと組んだときと字の並びと割る位置が変わりうる——向きを
  /// 持つ字の無い字の続きが 512 字を超えて文の端をまたぐ所（UAX #9 の W2・W7・N1）、括弧の組（BD16・N0）が文の端を
  /// またぐ所、isolate を閉じる字が文の終わりより後ろにある所、U+2068 の向きを決める字が文の外にある所。コードの中で文の
  /// 頭より前に開いた isolate・埋め込みは文の中に及ばず、それを閉じる字は何も閉じない（isolate を閉じる字は幅 0 の字として
  /// 組む）。
  public static func typeset(_ text: ZoneStyledText, width: CGFloat) -> ZoneTypeset {
    typeset(text, width: width, window: 4_096)
  }

  /// `typeset(_:width:)` を、段落を区切る長さ `window`（UTF-16）で組む。
  static func typeset(_ text: ZoneStyledText, width: CGFloat, window: Int) -> ZoneTypeset {
    let units = Array(text.string.utf16)
    let bareStyles = text.styles.map(\.bare)
    var lines: [TypesetLine] = []
    var start = 0
    // 位置 `offset` より後ろで終わる最初の見え方（段落と区切りは前から順に組むので、見え方を前から 1 度だけたどる）。
    var first = (index: 0, offset: 0)
    let advance = { (offset: Int) in
      while first.index < text.styles.count,
        first.offset + text.styles[first.index].length <= offset
      {
        first = (first.index + 1, first.offset + text.styles[first.index].length)
      }
    }
    repeat {
      let span = paragraphSpan(around: start, in: units)
      advance(span.lowerBound)
      guard !span.isEmpty else {
        let composition = ZoneComposition(units, paragraph: span, styles: text.styles, from: first)
        lines.append(TypesetLine(composition, 0..<0))
        start = span.upperBound + 1
        continue
      }
      // 段落は行の頭から `window` 字ずつ区切って組む——それより短い段落は丸ごと 1 回で組む。Core Text が 1 行の割る位置を
      // 探す仕事は段落の頭からの位置（タイ語・ラオ語は段落の長さ）に、長さの限りを外した文を組む仕事は右から左の字の続きの
      // 長さの 2 乗に比例するので、段落ごと組むと段落を組む仕事が長さの 2 乗になる。区切りの終わりから `margin` 以上
      // 手前で終わる行だけを採り（割る位置は後ろの字にも依るので、区切りの終わりの近くの行は次の区切りで組み直す）、1 行も
      // 採れなければ区切りを倍に広げる。区切りは段落の向きと、区切りの前で開いた埋め込み・上書き・isolate を引き継ぐ。
      let rightToLeft = ZoneComposition.isRightToLeft(units, span)
      let codes = ZoneComposition.CodeDirections()
      // 行の頭の前で開いた制御字（`head` は行を組む文の頭の、`line` は割る位置を探す文の頭の）。
      var carried = (
        head: CarriedControls(units, styles: text.styles, from: span.lowerBound, style: first),
        line: CarriedControls(units, styles: text.styles, from: span.lowerBound, style: first)
      )
      var lineStart = span.lowerBound
      var size = window
      while lineStart < span.upperBound {
        let end = min(span.upperBound, lineStart + size)
        // 行を組む文は行の頭より `margin` 字前から組む——字の向きは前の字にも依る（数字・中立の字は前の向きを持つ字の
        // 向きを取る。UAX #9 の W2・N1）。
        let head = max(span.lowerBound, lineStart - margin)
        carried.head.read(to: head)
        carried.line.read(to: lineStart)
        let composition = ZoneComposition(
          units, paragraph: head..<end, styles: text.styles, from: carried.head.style,
          context: .init(
            paragraph: span, rightToLeft: rightToLeft, open: carried.head.composed, codes: codes))
        let bare = ZoneComposition(
          units, paragraph: lineStart..<end, styles: bareStyles, from: carried.line.style,
          context: .init(
            paragraph: span, rightToLeft: rightToLeft, open: carried.line.bare, codes: codes))
        let made = wrap(composition, breakingAs: bare, width: width)
        let taken =
          end == span.upperBound
          ? made[...] : made.prefix { NSMaxRange($0.range) <= end - margin }
        guard let last = taken.last else {
          size *= 2
          continue
        }
        lines += taken
        lineStart = NSMaxRange(last.range)
        size = window
      }
      start = span.upperBound + 1
    } while start <= units.count
    return ZoneTypeset(text, lines: lines)
  }

  /// 区切りの前後に足す字の数——区切りの終わりから採る行の終わりまでに空ける字（割る位置は後ろの字にも依る）と、行を
  /// 組む文を行の頭より前から組む字（字の向きは前の字にも依る）。
  private static let margin = 512

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

  /// 段落の区切りを組んだ文 `composition` の、`bare`（範囲の頭から余白を付けずに組んだもの。元の文と同じ並び）の範囲を、
  /// 幅 `width` で行に割る。割る位置は `bare` で Core Text が選ぶ位置だけ——余白を付けても、余白なしでは割れない
  /// 所（コードの外の語の続き・禁則）で割れない。行は余白を付けて組んだ幅で確かめ、幅を超えれば、余白なしで探す幅を、
  /// 超えた分だけ狭めた幅と、余白付きと余白なしの幅の比で狭めた幅の広い方にして探し直す（行は短くなるだけで、狭め方は
  /// 倍々に広げるので、探し直しは数回で止まる）。それ以上狭められない（行が 1 つの割れない塊だけ）ときは、その行が幅を
  /// 超える。行の境は元の文の位置から組んだ文の境へ写す（コードの始まりは包みの頭の前、終わりは包みの尾の後）。余白なしで
  /// 探すのは、置き字の run delegate があると、Core Text が分け目を 1 つ探す仕事が段落の終わりまでの長さに比例するため
  /// でもある。
  private static func wrap(
    _ composition: ZoneComposition, breakingAs bare: ZoneComposition, width: CGFloat
  ) -> [TypesetLine] {
    let part = bare.paragraph
    let limit = Double(max(1, width))
    var lines: [TypesetLine] = []
    var start = part.lowerBound
    while start < part.upperBound {
      let from = bare.composed(start)
      let breakAt = { (width: Double) in
        start + max(1, CTTypesetterSuggestLineBreak(bare.typesetter, from, max(0, width)))
      }
      let composed = { (end: Int) in composition.composed(start)..<composition.composed(end) }
      var available = limit
      var end = breakAt(available)
      var lineWidth = Double(composition.width(composed(end)))
      while lineWidth > limit {
        let bareWidth = Double(bare.width(from..<bare.composed(end)))
        available = max(
          min(available - (lineWidth - limit), bareWidth), bareWidth * limit / lineWidth)
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
        lineWidth = Double(composition.width(composed(end)))
      }
      lines.append(TypesetLine(composition, composed(end)))
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
