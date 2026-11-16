import AppKit
import CoreText

/// 絵の差し込みの字組みで組む文——元の文の段落 1 つに、余白のある見え方（インラインコード）ごとに次の並びを足したもの。
///
/// ```
/// [U+2068] [置き字] [U+2060] コード [U+2060] [置き字] [U+2069]
/// ```
///
/// 置き字は U+FFFC に余白の幅だけを返す run delegate を付けた字。U+2060 は置き字とコードの間だけを折らせない（置き字の外側は
/// 元の文と同じ位置で折れる）。U+2068・U+2069 は包んだ範囲を周りと独立した向きのかたまりにする（向きは Core Text が中の字から
/// 決める）。コードの中の対にならない isolate の終わりは幅 0 の U+2060 に置き換え、閉じていない isolate と埋め込み・上書きは
/// 後ろの置き字の前で閉じる——元の文の制御字が、置き字の位置と包みの向きの独立を壊さない。
///
/// 元の文と組んだ文の位置の対応はこの型に閉じ、字組みの口（`ZoneTextLayout.Line`）は元の文の位置だけで答える。
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
  /// 組んだ文の字が空白か（行末の空白を幅と地に数えない）。
  let whitespace: [Bool]

  /// 文 `source` の範囲 `paragraph` を、見え方 `styles`（文の先頭から順に当てる）で組む。段落の向きは元の段落の最初の、
  /// 向きを持つ字で決める。
  init(_ source: [UInt16], paragraph: Range<Int>, styles: [ZoneTextStyle]) {
    self.paragraph = paragraph
    var builder = Builder(paragraph: paragraph)
    var offset = 0
    for (index, style) in styles.enumerated() {
      let start = offset
      offset += style.length
      let lower = max(start, paragraph.lowerBound)
      let upper = min(offset, paragraph.upperBound)
      guard lower < upper else { continue }
      if style.leadingPadding > 0 || style.trailingPadding > 0 {
        builder.isolate(
          source, lower..<upper, style: index, font: style.font,
          padding: (
            lower == start ? style.leadingPadding : 0, upper == offset ? style.trailingPadding : 0
          ))
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
    whitespace = builder.units.map { Unicode.Scalar($0)?.properties.isWhitespace ?? false }
    typesetter = CTTypesetterCreateWithAttributedString(
      builder.attributed(rightToLeft: Self.isRightToLeft(source[paragraph])))
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

  /// 組んだ文の境 `index` で行を割れるか——元の文の位置から引ける境（→ `composed(_:)`）で、サロゲートの対を割らない。
  func isBreakable(_ index: Int) -> Bool {
    guard index > 0, index < count else { return true }
    return composed(original(index)) == index && !UTF16.isTrailSurrogate(units[index])
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
}

extension ZoneComposition {
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
  var kinds: [(kind: Kind, font: NSFont?)] = []

  init(paragraph: Range<Int>) {
    self.paragraph = paragraph
    composed = [Int](repeating: 0, count: paragraph.count + 1)
  }

  mutating func plain(_ source: [UInt16], _ range: Range<Int>, style: Int, font: NSFont?) {
    for offset in range {
      composed[offset - paragraph.lowerBound] = units.count
      append(source[offset], original: offset, owner: style, .text(style), font)
    }
  }

  /// 範囲 `range`（見え方 `style` の字）を向きを独立させて包み、左右に置き字を置く（幅 0 の余白には置かない）。
  mutating func isolate(
    _ source: [UInt16], _ range: Range<Int>, style: Int, font: NSFont,
    padding: (leading: CGFloat, trailing: CGFloat)
  ) {
    let (start, end) = (range.lowerBound, range.upperBound)
    let (leading, trailing) = padding
    composed[start - paragraph.lowerBound] = units.count
    append(0x2068, original: start, owner: style, .control, font)
    if leading > 0 {
      append(0xFFFC, original: start, owner: style, .placeholder(leading), font)
      append(0x2060, original: start, owner: style, .control, font)
    }
    // 開いている isolate（true）と埋め込み・上書き（false）。
    var open: [Bool] = []
    for offset in range {
      if offset > start { composed[offset - paragraph.lowerBound] = units.count }
      var unit = source[offset]
      switch unit {
      case 0x2066...0x2068: open.append(true)
      case 0x202A, 0x202B, 0x202D, 0x202E: open.append(false)
      case 0x202C: if open.last == false { open.removeLast() }
      case 0x2069:
        if let isolate = open.lastIndex(of: true) {
          open.removeSubrange(isolate...)
        } else {
          unit = 0x2060
        }
      default: break
      }
      append(
        unit, original: offset, owner: style, unit == source[offset] ? .text(style) : .control,
        font)
    }
    for isolate in open.reversed() {
      append(isolate ? 0x2069 : 0x202C, original: end, owner: style, .control, font)
    }
    if trailing > 0 {
      append(0x2060, original: end, owner: style, .control, font)
      append(0xFFFC, original: end, owner: style, .placeholder(trailing), font)
    }
    append(0x2069, original: end, owner: style, .control, font)
    composed[end - paragraph.lowerBound] = units.count
  }

  mutating func finish() {
    originals.append(paragraph.upperBound)
    composed[paragraph.count] = units.count
  }

  private mutating func append(
    _ unit: UInt16, original: Int, owner: Int, _ kind: Kind, _ font: NSFont?
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
        CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font as CTFont)
      }
      switch kinds[start].kind {
      case .text(let style) where style >= 0:
        CFAttributedStringSetAttribute(
          attributed, range, ZoneComposition.styleAttribute as CFString, style as NSNumber)
      case .placeholder(let width):
        CFAttributedStringSetAttribute(
          attributed, range, kCTRunDelegateAttributeName, Self.delegate(width: width))
      case .control:
        // 字体の代わりに選ばれた字体が、制御字に幅のあるグリフを返すことがある。
        CFAttributedStringSetAttribute(
          attributed, range, kCTRunDelegateAttributeName, Self.delegate(width: 0))
      case .text: break
      }
      start = end
    }
    CFAttributedStringEndEditing(attributed)
    return attributed
  }

  /// 続く字を同じ属性でまとめられるか（置き字は 1 字ずつ）。
  private static func same(_ a: (kind: Kind, font: NSFont?), _ b: (kind: Kind, font: NSFont?))
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
