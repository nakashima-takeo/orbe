import AppKit
import CoreText

/// 絵の差し込みの字組みで組む文——元の文の段落 1 つ（か、その途中の区切り）に、余白のある見え方（インラインコード）ごとに
/// 次の並びを足したもの。
///
/// ```
/// [U+2068] [置き字] コード [置き字] [U+2069]
/// ```
///
/// 置き字は U+FFFC に余白の幅だけを返す run delegate を付けた字。U+2068・U+2069 は包んだ範囲を周りと独立した向きのかたまりに
/// する（向きは Core Text が中の字から決める。段落の区切りで切れたコードは、段落の中のコード全体の字から決めた U+2066 か
/// U+2067 で包む）。行を割る位置はこの文では探さない（→ `ZoneTextLayout`。余白を付けずに組んだ
/// 段落で探す）。コードの中の対にならない isolate の終わりは幅 0 の U+2060 に置き換え、閉じていない isolate と埋め込み・上書きは
/// 後ろの置き字の前で閉じる——元の文の制御字が、置き字の位置と包みの向きの独立を壊さない。コードの境が字の塊（書記素）の
/// 途中に来れば、包む範囲をその塊の端まで広げる（コードの始まりは塊の頭へ、終わりは塊の終わりへ）——包みの字と置き字が
/// 塊を割らない（Core Text は結合記号の後ろに幅 0 の書式の字が来ると、記号を基の字とまとめずに描く）。広げた範囲の字の
/// 見え方は変えない。
///
/// 元の文と組んだ文の位置の対応はこの型に閉じ、字組みの口（`ZoneTextLayout.TypesetLine`）は元の文の位置だけで答える。
final class ZoneComposition {
  /// 組む元の文の範囲（段落か、段落の途中の区切り）。
  let range: Range<Int>
  let typesetter: CTTypesetter
  /// 組んだ文。
  let units: [UInt16]
  var count: Int { units.count }
  /// 組んだ文の境 c（0...count）の、元の文の境。包みの頭の境はコードの始まり、包みの尾の境はコードの終わり。
  private let originals: [Int]
  /// 元の文の境 p（範囲の中）の、組んだ文の境（コードの始まりは包みの頭の前、コードの終わりは包みの尾の後）。
  private let composed: [Int]
  /// 組んだ文の字の地の見え方（包みの字と包みの中の字は包んだ見え方。区切りの頭に置いた、引き継いだ制御字は -1）。
  let owners: [Int32]
  /// 置き字の位置（組んだ文の位置）。
  let placeholders: Set<Int>
  /// 組んだ文の字が空白か（行末の空白を幅と地に数えない）。
  let whitespace: [Bool]

  /// 文 `source` の範囲 `range` を、見え方 `styles`（文の先頭から順に当てる）で組む。段落の向きは元の段落の最初の、
  /// 向きを持つ字で決める。見え方は `first`（範囲の始まりより後ろで終わる最初の見え方）から見て、範囲の終わりで止める
  /// ——範囲を組む仕事は、文の見え方の数に依らない。
  /// `context` を渡せば、範囲を段落 `context.paragraph` の途中の区切りとして組む——段落の向きと、区切りの前で開いた
  /// 埋め込み・上書き・isolate を引き継ぎ（開いた字を区切りの前に置く）、区切りの字の双方向の並びを段落の中と同じにする。
  /// 区切りで切れたコードは、段落の中のコード全体の向きのかたまりとして包む。
  init(
    _ source: [UInt16], range: Range<Int>, styles: [ZoneTextStyle],
    from first: StyleCursor = .init(), context: Context? = nil
  ) {
    self.range = range
    var builder = Builder(range: range, source: source, styles: styles, from: first)
    for unit in context?.open.units ?? [] { builder.carry(unit) }
    var clusters: ClusterStarts?
    var offset = first.offset
    for index in first.index..<styles.count {
      guard offset < range.upperBound else { break }
      let style = styles[index]
      let start = offset
      offset += style.length
      let lower = max(start, range.lowerBound)
      let upper = min(offset, range.upperBound)
      guard lower < upper, style.leadingPadding > 0 || style.trailingPadding > 0 else { continue }
      let starts = clusters ?? ClusterStarts(source, range)
      clusters = starts
      let low = max(builder.next, lower == start ? starts.boundary(atOrBefore: lower) : lower)
      let high = max(low, upper == offset ? starts.boundary(atOrAfter: upper) : upper)
      builder.plain(to: low)
      builder.isolate(
        low..<high, code: index,
        wrap: Builder.Wrap(
          initiator: Self.initiator(of: start..<offset, cutAt: lower..<upper, source, context),
          leading: lower == start ? style.leadingPadding : 0,
          trailing: upper == offset ? style.trailingPadding : 0))
    }
    builder.plain(to: range.upperBound)
    builder.finish()
    self.units = builder.units
    originals = builder.originals
    composed = builder.composed
    owners = builder.owners
    placeholders = builder.placeholders
    whitespace = builder.units.map { Unicode.Scalar($0)?.properties.isWhitespace ?? false }
    let rightToLeft = context?.rightToLeft ?? Self.isRightToLeft(source, range)
    typesetter = Self.typesetter(builder.attributed(rightToLeft: rightToLeft))
  }

  /// 範囲の中の字の塊（書記素）の境。コードの境が塊の途中に来たときにだけ求める（範囲の長さに比例する）。
  private struct ClusterStarts {
    let range: Range<Int>
    /// 範囲の頭からの位置ごとに、塊の境か。
    private let starts: [Bool]

    init(_ source: [UInt16], _ range: Range<Int>) {
      self.range = range
      var starts = [Bool](repeating: false, count: range.count + 1)
      var position = 0
      for character in String(decoding: source[range], as: UTF16.self) {
        starts[position] = true
        position += character.utf16.count
      }
      starts[range.count] = true
      self.starts = starts
    }

    /// 位置 `offset`（範囲の中）か、その前で最後の塊の境。
    func boundary(atOrBefore offset: Int) -> Int {
      var index = offset - range.lowerBound
      while !starts[index] { index -= 1 }
      return range.lowerBound + index
    }

    /// 位置 `offset`（範囲の中）か、その後ろで最初の塊の境。
    func boundary(atOrAfter offset: Int) -> Int {
      var index = offset - range.lowerBound
      while !starts[index] { index += 1 }
      return range.lowerBound + index
    }
  }

  /// 段落の途中の区切りが引き継ぐ、段落の範囲と向きと、区切りの前で開いた埋め込み・上書き・isolate と、段落の区切りで
  /// 切れたコードの向きの覚え（段落の区切りどうしで共にする）。
  struct Context {
    let paragraph: Range<Int>
    let rightToLeft: Bool
    let open: OpenControls
    let codes: CodeDirections
  }

  /// 段落の区切りで切れたコードの向き（コードの元の文の範囲 → 右から左か）。段落を区切って組む間だけ持ち、区切りごとに
  /// コード全体から求め直さない——強い字の無いコードや isolate の中にしか強い字の無いコードでは、求める仕事がコードの
  /// 長さに比例する。
  final class CodeDirections {
    private var directions: [Range<Int>: Bool] = [:]

    func isRightToLeft(_ code: Range<Int>, in source: [UInt16]) -> Bool {
      if let known = directions[code] { return known }
      let direction = ZoneComposition.isRightToLeft(source, code)
      directions[code] = direction
      return direction
    }
  }

  /// コード `code`（元の文の範囲）を組んだ文の範囲 `part` だけ包むときの、包みの頭の字。区切りで切れていなければ U+2068
  /// （向きは Core Text が中の字から決める）。区切りで切れていれば、段落の中のコード全体の向きで決めた U+2066 か U+2067
  /// ——区切りの中の字だけで向きを決め直さない。
  private static func initiator(
    of code: Range<Int>, cutAt part: Range<Int>, _ source: [UInt16], _ context: Context?
  ) -> UInt16 {
    guard let context else { return 0x2068 }
    let whole = code.clamped(to: context.paragraph)
    guard part != whole else { return 0x2068 }
    return context.codes.isRightToLeft(whole, in: source) ? 0x2067 : 0x2066
  }

  /// 組んだ文の境 `index` の、元の文の境。
  func original(_ index: Int) -> Int { originals[min(max(0, index), count)] }

  /// 元の文の境 `offset` の、組んだ文の境（範囲の外は範囲の端）。
  func composed(_ offset: Int) -> Int {
    composed[min(max(range.lowerBound, offset), range.upperBound) - range.lowerBound]
  }

  /// 組んだ文の範囲 `range` を 1 行に組む（空の範囲は空の行）。
  func line(_ range: Range<Int>) -> CTLine {
    guard !range.isEmpty else {
      return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "" as CFString, nil))
    }
    return CTTypesetterCreateLine(
      typesetter, CFRange(location: range.lowerBound, length: range.count))
  }

  /// 組んだ文の範囲 `range` を 1 行に組んだ幅（行末の空白を除く）。
  func width(_ range: Range<Int>) -> CGFloat { Self.width(of: line(range)) }

  /// 組んだ行の幅（行末の空白を除く）。
  static func width(of line: CTLine) -> CGFloat {
    max(
      0,
      CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
  }

}

extension ZoneComposition {
  /// 文 `string` を組む typesetter。Core Text は既定では、約 10,000 字（UTF-16）を超える文を簡略に組む——段落の向きを
  /// 解かず、ZWJ でつないだ絵文字を 1 字にまとめず、タイ語・ラオ語の語の境を探さない。段落の長さに依らず同じに組むため、
  /// この限りを外す。
  static func typesetter(_ string: CFAttributedString) -> CTTypesetter {
    CTTypesetterCreateWithAttributedStringAndOptions(
      string, [kCTTypesetterOptionAllowUnboundedLayout: kCFBooleanTrue] as CFDictionary)!
  }

  /// 見え方の番号を載せる属性（Core Text は属性の違う所で字の連なりを分ける。包みの字には載せない）。
  static let styleAttribute = "OrbeZoneTextStyle"
}

/// 組んだ文を積む。元の文の字は前から順に 1 度ずつ積み、字ごとの見え方は見え方の列を前へたどって決める。
private struct Builder {
  /// 元の文の字（見え方の番号つき）・幅 0 の制御字・置き字。
  enum Kind {
    case text(Int)
    case control
    case placeholder(CGFloat)
  }

  let range: Range<Int>
  private let source: [UInt16]
  private let styles: [ZoneTextStyle]
  var units: [UInt16] = []
  var originals: [Int] = []
  var composed: [Int]
  var owners: [Int32] = []
  /// 組んだ文の字ごとの種類と字体（字体が無ければ Core Text の既定）。
  var kinds: [(kind: Kind, font: CTFont?)] = []
  /// 置き字の位置（組んだ文の位置）。
  var placeholders: Set<Int> = []
  /// 積み終えた元の文の位置。
  private(set) var next: Int
  /// 次に積む字より後ろで終わる見え方（字の見え方を前へたどる）。
  private var style: StyleCursor

  init(range: Range<Int>, source: [UInt16], styles: [ZoneTextStyle], from first: StyleCursor) {
    self.range = range
    self.source = source
    self.styles = styles
    style = first
    next = range.lowerBound
    composed = [Int](repeating: 0, count: range.count + 1)
  }

  /// 元の文の字を位置 `end` の手前まで、字の見え方のまま積む。
  mutating func plain(to end: Int) {
    while next < end {
      style.advance(to: next, in: styles)
      composed[next - range.lowerBound] = units.count
      append(source[next], original: next, owner: style.index, .text(style.index), font)
      next += 1
    }
  }

  /// 包み方——isolate の頭の字と、左右の置き字の幅。
  struct Wrap {
    let initiator: UInt16
    let leading: CGFloat
    let trailing: CGFloat
  }

  /// 範囲 `range`（見え方 `code` のコード。境を字の塊の端まで広げた範囲）を、`wrap` の頭の字で向きを独立させて包み、左右に
  /// 置き字を置く（幅 0 の余白には置かない）。包みの字と置き字はコードの見え方で組み、中の字は字の見え方で組んで地は
  /// コードに数える。
  mutating func isolate(_ range: Range<Int>, code: Int, wrap: Wrap) {
    let (start, end) = (range.lowerBound, range.upperBound)
    let (leading, trailing) = (wrap.leading, wrap.trailing)
    let codeFont = styles[code].font
    composed[start - self.range.lowerBound] = units.count
    append(wrap.initiator, original: start, owner: code, .control, codeFont)
    if leading > 0 {
      placeholders.insert(units.count)
      append(0xFFFC, original: start, owner: code, .placeholder(leading), codeFont)
    }
    var open = OpenControls()
    for offset in range {
      style.advance(to: offset, in: styles)
      if offset > start { composed[offset - self.range.lowerBound] = units.count }
      let unit = open.read(source[offset]) ? source[offset] : 0x2060
      append(
        unit, original: offset, owner: code,
        unit == source[offset] ? .text(style.index) : .control, font)
    }
    next = end
    for closer in open.closers {
      append(closer, original: end, owner: code, .control, codeFont)
    }
    if trailing > 0 {
      placeholders.insert(units.count)
      append(0xFFFC, original: end, owner: code, .placeholder(trailing), codeFont)
    }
    append(0x2069, original: end, owner: code, .control, codeFont)
    composed[end - self.range.lowerBound] = units.count
  }

  /// 区切りの前で開いた字 `unit` を、区切りの頭に置く。
  mutating func carry(_ unit: UInt16) {
    append(unit, original: range.lowerBound, owner: -1, .text(-1), nil)
  }

  mutating func finish() {
    originals.append(range.upperBound)
    composed[range.count] = units.count
  }

  /// 次に積む字の字体。
  private var font: CTFont { styles[style.index].font }

  private mutating func append(
    _ unit: UInt16, original: Int, owner: Int, _ kind: Kind, _ font: CTFont?
  ) {
    units.append(unit)
    originals.append(original)
    owners.append(Int32(owner))
    kinds.append((kind, font))
  }

  /// 段落の向きを `rightToLeft` に決めた属性文字列。元の文の字は、字ごとの字体の表（`GlyphFonts`）の字体で組む——
  /// 見え方の字体に無い字の字体が、前の字の代替フォントに引きずられない（テキスト面の行の組版と同じ決まり）。
  func attributed(rightToLeft: Bool) -> CFAttributedString {
    let kinds = pinned(self.kinds)
    let string = units.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let attributed = CFAttributedStringCreateMutable(nil, 0)!
    CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
    CFAttributedStringBeginEditing(attributed)
    var direction: CTWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
    let paragraphStyle = withUnsafeBytes(of: &direction) {
      var setting = CTParagraphStyleSetting(
        spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
        value: $0.baseAddress!)
      return CTParagraphStyleCreate(&setting, 1)
    }
    let whole = CFRange(location: 0, length: units.count)
    CFAttributedStringSetAttribute(
      attributed, whole, kCTParagraphStyleAttributeName, paragraphStyle)
    CFAttributedStringSetAttribute(
      attributed, whole, kCTLanguageAttributeName, TextLanguage.neutral as CFString)
    var start = 0
    while start < kinds.count {
      var end = start + 1
      while end < kinds.count, Self.same(kinds[start], kinds[end]) { end += 1 }
      let range = CFRange(location: start, length: end - start)
      if let font = kinds[start].font {
        CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
      }
      switch kinds[start].kind {
      case .text(let style) where style >= 0:
        CFAttributedStringSetAttribute(
          attributed, range, ZoneComposition.styleAttribute as CFString, style as NSNumber)
      case .placeholder(let width):
        CFAttributedStringSetAttribute(
          attributed, range, kCTRunDelegateAttributeName, Self.delegate(width: width))
      case .control:
        // 見え方の字体に無い字のために Core Text が選ぶ代わりの字体は、制御字に幅のあるグリフを返すことがある。
        CFAttributedStringSetAttribute(
          attributed, range, kCTRunDelegateAttributeName, Self.delegate(width: 0))
      case .text: break
      }
      start = end
    }
    CFAttributedStringEndEditing(attributed)
    return attributed
  }

  /// `kinds` の元の文の字の字体を、同じ字体が続く範囲ごとに、表の字体に替えたもの（字体が 1 つに決まらない字は見え方の
  /// 字体のまま）。
  private func pinned(_ kinds: [(kind: Kind, font: CTFont?)]) -> [(kind: Kind, font: CTFont?)] {
    var pinned = kinds
    var start = 0
    while start < kinds.count {
      guard case .text = kinds[start].kind, let font = kinds[start].font else {
        start += 1
        continue
      }
      var end = start + 1
      while end < kinds.count, case .text = kinds[end].kind, kinds[end].font == font { end += 1 }
      let glyphs = GlyphFonts.glyphs(ContiguousArray(units[start..<end]), font: font)
      for index in start..<end {
        pinned[index].font = glyphs.font(at: index - start) ?? font
      }
      start = end
    }
    return pinned
  }

  /// 続く字を同じ属性でまとめられるか（置き字は 1 字ずつ）。
  private static func same(_ a: (kind: Kind, font: CTFont?), _ b: (kind: Kind, font: CTFont?))
    -> Bool
  {
    guard a.font == b.font else { return false }
    switch (a.kind, b.kind) {
    case (.text(let x), .text(let y)): return x == y
    case (.control, .control): return true
    default: return false
    }
  }

  /// 幅 `width` だけを返す run delegate（高さは持たない）。
  private static func delegate(width: CGFloat) -> CTRunDelegate {
    var callbacks = CTRunDelegateCallbacks(
      version: kCTRunDelegateVersion1,
      dealloc: { $0.assumingMemoryBound(to: CGFloat.self).deallocate() },
      getAscent: { _ in 0 }, getDescent: { _ in 0 },
      getWidth: { $0.assumingMemoryBound(to: CGFloat.self).pointee })
    let pointer = UnsafeMutablePointer<CGFloat>.allocate(capacity: 1)
    pointer.initialize(to: width)
    return CTRunDelegateCreate(&callbacks, pointer)!
  }
}
