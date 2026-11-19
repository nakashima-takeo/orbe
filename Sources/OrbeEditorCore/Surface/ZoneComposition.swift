import AppKit
import CoreText

/// 絵の差し込みの字組みで組む文——元の文の段落 1 つに、余白のある見え方（インラインコード）ごとに次の並びを足したもの。
///
/// ```
/// [U+2068] [置き字] コード [置き字] [U+2069]
/// ```
///
/// 置き字は U+FFFC に余白の幅だけを返す run delegate を付けた字。U+2068・U+2069 は包んだ範囲を周りと独立した向きのかたまりに
/// する（向きは Core Text が中の字から決める。段落の区切りで切れたコードは、段落の中のコード全体の字から決めた U+2066 か
/// U+2067 で包む）。行を割る位置はこの文では探さない（→ `ZoneTextLayout`。余白を付けずに組んだ
/// 段落で探す）。コードの中の対にならない isolate の終わりは幅 0 の U+2060 に置き換え、閉じていない isolate と埋め込み・上書きは
/// 後ろの置き字の前で閉じる——元の文の制御字が、置き字の位置と包みの向きの独立を壊さない。
///
/// 元の文と組んだ文の位置の対応はこの型に閉じ、字組みの口（`ZoneTextLayout.TypesetLine`）は元の文の位置だけで答える。
final class ZoneComposition {
  /// 元の文の中の段落の範囲。
  let paragraph: Range<Int>
  let typesetter: CTTypesetter
  /// 組んだ文。
  let units: [UInt16]
  var count: Int { units.count }
  /// 組んだ文の境 c（0...count）の、元の文の境。包みの頭の境はコードの始まり、包みの尾の境はコードの終わり。
  private let originals: [Int]
  /// 元の文の境 p（段落の中）の、組んだ文の境（コードの始まりは包みの頭の前、コードの終わりは包みの尾の後）。
  private let composed: [Int]
  /// 組んだ文の字の見え方（包みの字は包んだ見え方。見え方の無い字は -1）。
  let owners: [Int32]
  /// 置き字の位置（組んだ文の位置）。
  let placeholders: Set<Int>
  /// 組んだ文の字が空白か（行末の空白を幅と地に数えない）。
  let whitespace: [Bool]
  /// 段落が右から左か。
  let rightToLeft: Bool

  /// 文 `source` の範囲 `paragraph` を、見え方 `styles`（文の先頭から順に当てる）で組む。段落の向きは元の段落の最初の、
  /// 向きを持つ字で決める。見え方は `first`（番号と、その見え方が当たり始める文の位置。段落の始まりより後ろで終わる最初の
  /// 見え方）から見て、段落の終わりで止める——段落を組む仕事は、文の見え方の数に依らない。
  /// `context` を渡せば、範囲を段落 `context.paragraph` の途中の区切りとして組む——段落の向きと、区切りの前で開いた
  /// 埋め込み・上書き・isolate を引き継ぎ（開いた字を区切りの前に置く）、区切りの字の双方向の並びを段落の中と同じにする。
  /// 区切りで切れたコードは、段落の中のコード全体の向きのかたまりとして包む。
  init(
    _ source: [UInt16], paragraph: Range<Int>, styles: [ZoneTextStyle],
    from first: (index: Int, offset: Int) = (0, 0), context: Context? = nil
  ) {
    self.paragraph = paragraph
    var builder = Builder(paragraph: paragraph)
    for unit in context?.open.units ?? [] { builder.carry(unit) }
    var offset = first.offset
    for index in first.index..<styles.count {
      guard offset < paragraph.upperBound else { break }
      let style = styles[index]
      let start = offset
      offset += style.length
      let lower = max(start, paragraph.lowerBound)
      let upper = min(offset, paragraph.upperBound)
      guard lower < upper else { continue }
      if style.leadingPadding > 0 || style.trailingPadding > 0 {
        builder.isolate(
          source, lower..<upper, style: index, font: style.font,
          wrap: Builder.Wrap(
            initiator: Self.initiator(of: start..<offset, cutAt: lower..<upper, source, context),
            leading: lower == start ? style.leadingPadding : 0,
            trailing: upper == offset ? style.trailingPadding : 0))
      } else {
        builder.plain(source, lower..<upper, style: index, font: style.font)
      }
    }
    builder.plain(
      source, min(max(offset, paragraph.lowerBound), paragraph.upperBound)..<paragraph.upperBound,
      style: -1, font: nil)
    builder.finish()
    self.units = builder.units
    originals = builder.originals
    composed = builder.composed
    owners = builder.owners
    placeholders = builder.placeholders
    whitespace = builder.units.map { Unicode.Scalar($0)?.properties.isWhitespace ?? false }
    rightToLeft = context?.rightToLeft ?? Self.isRightToLeft(source, paragraph)
    typesetter = Self.typesetter(builder.attributed(rightToLeft: rightToLeft))
  }

  /// 段落の途中の区切りが引き継ぐ、段落の範囲と向きと、区切りの前で開いた埋め込み・上書き・isolate。
  struct Context {
    let paragraph: Range<Int>
    let rightToLeft: Bool
    let open: OpenControls
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
    return isRightToLeft(source, whole) ? 0x2067 : 0x2066
  }

  /// 組んだ文の境 `index` の、元の文の境。
  func original(_ index: Int) -> Int { originals[min(max(0, index), count)] }

  /// 元の文の境 `offset` の、組んだ文の境（段落の外は段落の端）。
  func composed(_ offset: Int) -> Int {
    composed[min(max(paragraph.lowerBound, offset), paragraph.upperBound) - paragraph.lowerBound]
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

/// 組んだ文を積む。
private struct Builder {
  /// 元の文の字（見え方の番号つき）・幅 0 の制御字・置き字。
  enum Kind {
    case text(Int)
    case control
    case placeholder(CGFloat)
  }

  let paragraph: Range<Int>
  var units: [UInt16] = []
  var originals: [Int] = []
  var composed: [Int]
  var owners: [Int32] = []
  /// 組んだ文の字ごとの種類と字体（字体が無ければ Core Text の既定）。
  var kinds: [(kind: Kind, font: CTFont?)] = []
  /// 置き字の位置（組んだ文の位置）。
  var placeholders: Set<Int> = []
  /// 包んだコードの字の範囲（組んだ文の位置。包みの制御字と置き字は含まない）。
  var codes: [Range<Int>] = []

  init(paragraph: Range<Int>) {
    self.paragraph = paragraph
    composed = [Int](repeating: 0, count: paragraph.count + 1)
  }

  mutating func plain(_ source: [UInt16], _ range: Range<Int>, style: Int, font: CTFont?) {
    for offset in range {
      composed[offset - paragraph.lowerBound] = units.count
      append(source[offset], original: offset, owner: style, .text(style), font)
    }
  }

  /// 包み方——isolate の頭の字と、左右の置き字の幅。
  struct Wrap {
    let initiator: UInt16
    let leading: CGFloat
    let trailing: CGFloat
  }

  /// 範囲 `range`（見え方 `style` の字）を、`wrap` の頭の字で向きを独立させて包み、左右に置き字を置く（幅 0 の余白には
  /// 置かない）。
  mutating func isolate(
    _ source: [UInt16], _ range: Range<Int>, style: Int, font: CTFont, wrap: Wrap
  ) {
    let (start, end) = (range.lowerBound, range.upperBound)
    let (leading, trailing) = (wrap.leading, wrap.trailing)
    composed[start - paragraph.lowerBound] = units.count
    append(wrap.initiator, original: start, owner: style, .control, font)
    if leading > 0 {
      placeholders.insert(units.count)
      append(0xFFFC, original: start, owner: style, .placeholder(leading), font)
    }
    let head = units.count
    var open = OpenControls()
    for offset in range {
      if offset > start { composed[offset - paragraph.lowerBound] = units.count }
      let unit = open.read(source[offset]) ? source[offset] : 0x2060
      append(
        unit, original: offset, owner: style, unit == source[offset] ? .text(style) : .control,
        font)
    }
    let tail = units.count
    for closer in open.closers {
      append(closer, original: end, owner: style, .control, font)
    }
    if trailing > 0 {
      placeholders.insert(units.count)
      append(0xFFFC, original: end, owner: style, .placeholder(trailing), font)
    }
    append(0x2069, original: end, owner: style, .control, font)
    composed[end - paragraph.lowerBound] = units.count
    codes.append(head..<tail)
  }

  /// 区切りの前で開いた字 `unit` を、区切りの頭に置く。
  mutating func carry(_ unit: UInt16) {
    append(unit, original: paragraph.lowerBound, owner: -1, .text(-1), nil)
  }

  mutating func finish() {
    originals.append(paragraph.upperBound)
    composed[paragraph.count] = units.count
  }

  private mutating func append(
    _ unit: UInt16, original: Int, owner: Int, _ kind: Kind, _ font: CTFont?
  ) {
    units.append(unit)
    originals.append(original)
    owners.append(Int32(owner))
    kinds.append((kind, font))
  }

  /// 段落の向きを `rightToLeft` に決めた属性文字列。
  func attributed(rightToLeft: Bool) -> CFAttributedString {
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
    CFAttributedStringSetAttribute(
      attributed, CFRange(location: 0, length: units.count), kCTParagraphStyleAttributeName,
      paragraphStyle)
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
    // コードの字は言語を持たない字として組む——Core Text は言語（既定は利用者の環境の言語）で和文の約物を詰め、括弧の
    // 送りの片側を空ける。向きの逆なコードでは空きが余白の側に出て、余白が渡した幅より広く見える。包みの制御字と置き字
    // には付けない（付けると、コードの外の隣の約物の詰め方が変わり、その字がコードの地にかぶる）。
    for code in codes {
      CFAttributedStringSetAttribute(
        attributed, CFRange(location: code.lowerBound, length: code.count),
        kCTLanguageAttributeName, "zxx" as CFString)
    }
    CFAttributedStringEndEditing(attributed)
    return attributed
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
