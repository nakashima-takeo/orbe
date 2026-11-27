import CoreText
import Foundation
import OrbeEditorCore

/// 1 行を組んだ結果——run ごとのフォント・グリフ・位置（pt、行頭の基線から。y は上が正で、結合文字の記号などだけが
/// 0 でない）・元の行の UTF-16 の位置（色を引くため）と、行の幅、上限で打ち切って描かない UTF-16 の単位の数、組んだ行。
struct ShapedLine {
  struct Run {
    let font: CTFont
    let glyphs: [CGGlyph]
    let xs: [CGFloat]
    let ys: [CGFloat]
    let offsets: [Int]
  }

  let runs: [Run]
  let width: CGFloat
  let omitted: Int
  /// 組んだ行（位置と x の対応を作り、x にいちばん近い位置を引く）。
  let line: CTLine
  /// 等幅のフォントで組んだ、描く単位がどれも ASCII の字かタブで、単位ごとに 1 つのグリフが左から順に並んだ行（minified の
  /// 1 行の多く）。
  let simple: Bool

  /// 行の中の位置と x の対応（キャレット・選択の地・強調の地・装備のある行だけが要る——作る手間は行の長さに比例する）。
  /// 単純な行はグリフの位置から作る（Core Text に縁を数えさせると 1 万字の行で数 ms かかる）。等幅のフォントの ASCII の
  /// 字は合字も詰めも持たないので、字の縁はグリフの位置と送りに一致し、Core Text の答えと同じになる。面のフォントは
  /// 面を載せる側が等幅のシステムフォントに固定しているが、等幅でないフォントで組んだ行は Core Text に数えさせる。
  var carets: CaretMap {
    simple ? CaretMap(ascii: runs.flatMap(\.xs), width: width) : CaretMap(line, width: width)
  }
}

/// 行の組版の規則（純関数）。描画スレッドと、横の位置が要る main の操作が同じ規則を使う。
///
/// 行は文書の行（`\n` で割った行）の中身で、見せ方は VS Code の既定（`renderControlCharacters`）と同じ——行末の `\r` は
/// 描かない、C0 の制御文字は U+2400 台の記号、DEL は U+2421、U+2028・U+2029・U+0085・U+FEFF は U+FFFD、方向を変える
/// 書式文字（U+202A〜202E・U+2066〜2069・U+200E・U+200F・U+061C）は `[U+202E]` の形の箱で見せる（字の並びを変えない）。
/// タブは次のタブ位置まで空ける。置き換えは 1 単位を 1 単位にする（箱もタブと同じく 1 単位が何桁かの幅を持つ）ので、
/// 描く字の位置は元の行の位置と同じ。行は常に左から右の段落として並べる（右から左の字で始まる行でも。VS Code と
/// 同じ）。1 行で描くのは `limit` 単位まで（書記素の境で切る）で、残りは描かない。
enum LineShaper {
  static let limit = 10_000
  /// 描きうる先頭として読む単位の数（書記素の境を探すために、上限より余分に読む）。
  static let headLimit = limit + Grapheme.reach

  /// 行の中身のうち描きうる先頭（上限と余分まで）と、行の長さ（行末の改行と `\r` を除く）。長い行でも読むのは先頭だけ。
  struct Source: Hashable {
    var head: ContiguousArray<UInt16>
    var length: Int
  }

  /// 文書の行 `row` の中身と行頭のオフセット。
  static func source(row: Int, in text: TextRope) -> (source: Source, start: Int) {
    let start = text.lineStart(row)
    let next = row + 1 < text.lineCount ? text.lineStart(row + 1) : nil
    return (source(start: start, next: next, in: text), start)
  }

  /// 改行を含まない字列 `line` の中身。
  static func source(_ line: String) -> Source {
    let units = line.utf16
    return Source(head: ContiguousArray(units.prefix(headLimit)), length: units.count)
  }

  /// 行頭 `start` から次の行頭 `next`（最後の行なら nil）までの行の中身。読むのは描きうる先頭と、それより長い行だけ
  /// 行末の 1 単位（`\r` か）。
  static func source(start: Int, next: Int?, in text: TextRope) -> Source {
    let end = next.map { $0 - 1 } ?? text.length
    var head = text.units(in: NSRange(location: start, length: min(end - start, headLimit + 1)))
    let last =
      head.count == end - start
      ? head.last : text.units(in: NSRange(location: end - 1, length: 1)).first
    let length = end - start - (last == 0x0D ? 1 : 0)
    if head.count > min(length, headLimit) { head.removeLast(head.count - min(length, headLimit)) }
    return Source(head: head, length: length)
  }

  /// 箱で見せる書式文字 1 つ——描く単位の位置と、元の字。
  struct Box: Hashable {
    var index: Int
    var unit: UInt16
  }

  /// 描く単位の列（上限を書記素の境で切り、制御文字を記号に置き換えたもの）と、打ち切って描かない単位の数と、箱で
  /// 見せる書式文字（位置の昇順）。箱の位置の単位は、並びに効かない U+FFFC に置き換える。箱は列で持つ——書式文字の多い
  /// 本文で、行ごとに表を作らない。
  struct Displayed: Hashable {
    var units: ContiguousArray<UInt16>
    var omitted: Int
    var boxes: [Box]

    /// 描く単位の区間 `range` の段——区間の単位と、区間の中の箱（位置は区間の頭から）。打ち切った単位の数は、行の最後の段
    /// （`last`）だけが持つ。
    func segment(_ range: Range<Int>, last: Bool) -> Displayed {
      guard range != 0..<units.count || !last else { return self }
      let first = boxes.firstBox(atOrAfter: range.lowerBound)
      let end = boxes.firstBox(atOrAfter: range.upperBound)
      return Displayed(
        units: ContiguousArray(units[range]), omitted: last ? omitted : 0,
        boxes: boxes[first..<end].map { Box(index: $0.index - range.lowerBound, unit: $0.unit) })
    }
  }

  static func display(_ source: Source) -> Displayed {
    let cut = source.length > limit ? graphemeCut(source.head) : source.length
    var units = ContiguousArray(source.head[0..<cut])
    var boxes: [Box] = []
    for i in units.indices {
      let u = units[i]
      if u < 0x20, u != 0x09 {
        units[i] = 0x2400 + u
      } else if u == 0x7F {
        units[i] = 0x2421
      } else if u == 0x2028 || u == 0x2029 || u == 0x85 || u == 0xFEFF {
        units[i] = 0xFFFD
      } else if isDirectionalFormat(u) {
        boxes.append(Box(index: i, unit: u))
        units[i] = 0xFFFC
      }
    }
    return Displayed(units: units, omitted: source.length - cut, boxes: boxes)
  }

  /// 方向を変える書式文字（VS Code が `renderControlCharacters` で見せるもの）。
  static func isDirectionalFormat(_ u: UInt16) -> Bool {
    (0x202A...0x202E).contains(u) || (0x2066...0x2069).contains(u) || u == 0x200E || u == 0x200F
      || u == 0x061C
  }

  /// 書式文字の箱に描く中身。
  static func boxLabel(_ u: UInt16) -> String { String(format: "[U+%04X]", u) }

  /// 書式文字 `u` の箱の幅——中身（`boxLabel`）の字の、ASCII の字の幅 `ascii`（`GlyphFonts.asciiWidths`）の和。組版と
  /// 折り返しが同じ幅を引く。中身の文字列は作らない（書式文字の多い行で、箱ごとに文字列を作って組まない）。
  static func boxWidth(_ u: UInt16, ascii: [CGFloat]) -> CGFloat {
    func width(_ unit: UInt16) -> CGFloat { ascii[Int(unit) - 0x20] }
    var sum = width(0x5B) + width(0x55) + width(0x2B) + width(0x5D)
    for shift in [12, 8, 4, 0] {
      let digit = (u >> UInt16(shift)) & 0xF
      sum += width(digit < 10 ? 0x30 + digit : 0x41 + digit - 10)
    }
    return sum
  }

  /// `limit` 以下で最も後ろの書記素の境（1 つの書記素が上限を越えるほど長ければ `limit`）。上限の位置の前後だけを見る
  /// （行頭から書記素を数えると、長い行を組むたびに 10000 字を歩く）。
  private static func graphemeCut(_ head: ContiguousArray<UInt16>) -> Int {
    let cluster = Grapheme.cluster(
      containing: limit, count: head.count, unit: { head[$0] }, units: { ContiguousArray(head[$0]) }
    )
    return cluster.lowerBound > 0 ? cluster.lowerBound : limit
  }

  /// 行を組む。`tabWidth` はタブの刻み（pt）。
  static func shape(_ source: Source, font: CTFont, tabWidth: CGFloat) -> ShapedLine {
    shape(display(source), font: font, tabWidth: tabWidth)
  }

  /// 描く単位の列（行か、折り返した行の段）を 1 行として組む。タブの位置は列の頭から数える。
  static func shape(_ shown: Displayed, font: CTFont, tabWidth: CGFloat) -> ShapedLine {
    let ascii = isASCII(shown.units)
    let line = makeLine(
      shown.units, boxes: shown.boxes, font: font, tabWidth: tabWidth, ascii: ascii)
    return ShapedLine(
      line, omitted: shown.omitted, boxes: shown.boxes, font: font,
      ascii: isMonospaced(font) && ascii)
  }

  /// 等幅のフォント。
  private static func isMonospaced(_ font: CTFont) -> Bool {
    CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
  }

  /// どの単位も ASCII の字（U+0020…U+007E）かタブ。
  static func isASCII(_ units: ContiguousArray<UInt16>) -> Bool {
    units.allSatisfy { $0 == 0x09 || (0x20...0x7E).contains($0) }
  }

  /// 文字列を 1 行として組む（打ち切った行の末尾の印・書式文字の箱の中身）。
  static func shape(_ string: String, font: CTFont) -> ShapedLine {
    let units = ContiguousArray(string.utf16)
    let ascii = isASCII(units)
    let line = makeLine(units, boxes: [], font: font, tabWidth: 0, ascii: ascii)
    return ShapedLine(
      line, omitted: 0, boxes: [], font: font, ascii: isMonospaced(font) && ascii)
  }

  /// 行を組む。字の字体は字ごとの字体の表（`GlyphFonts`）から引き、同じ字体が続く範囲ごとに表の字体を渡して組む。渡した
  /// 字体はその字を持つので、Core Text は代替を探さず、前の字の代替フォントを引き継がない。字体が 1 つに決まらない字は
  /// 本体の字体のまま渡す。ASCII の字とタブだけの行は、本体の字体がどの ASCII の字も持つなら、表を引かずに本体の字体で
  /// 組む。
  private static func makeLine(
    _ units: ContiguousArray<UInt16>, boxes: [Box], font: CTFont, tabWidth: CGFloat,
    ascii: Bool
  ) -> CTLine {
    let attributed = attributed(units, font: font, tabWidth: tabWidth)
    let widths = boxes.isEmpty ? [] : GlyphFonts.asciiWidths(font)
    for box in boxes {
      CFAttributedStringSetAttribute(
        attributed, CFRange(location: box.index, length: 1), kCTRunDelegateAttributeName,
        boxDelegate(width: boxWidth(box.unit, ascii: widths), font: font))
    }
    if !units.isEmpty, !ascii || !GlyphFonts.coversASCII(font) {
      let glyphs = GlyphFonts.glyphs(units, font: font)
      var start = 0
      for end in 1...units.count where end == units.count || !glyphs.sameFont(start, end) {
        defer { start = end }
        guard let pinned = glyphs.font(at: start), pinned !== font else { continue }
        CFAttributedStringSetAttribute(
          attributed, CFRange(location: start, length: end - start), kCTFontAttributeName, pinned)
      }
    }
    return CTLineCreateWithAttributedString(attributed)
  }

  /// 単位の列 `units` に、本文の字の属性（字体 `font`・言語を持たない字として組む言語の属性・左から右の段落とタブの刻み
  /// `tabWidth`）を付けた文字列。
  private static func attributed(
    _ units: ContiguousArray<UInt16>, font: CTFont, tabWidth: CGFloat
  ) -> CFMutableAttributedString {
    let string = units.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let attributes: [CFString: Any] = [
      kCTFontAttributeName: font,
      kCTLanguageAttributeName: TextLanguage.neutral,
      kCTParagraphStyleAttributeName: paragraphStyle(tabWidth: tabWidth),
    ]
    let attributed = CFAttributedStringCreateMutable(nil, 0)!
    CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
    CFAttributedStringSetAttributes(
      attributed, CFRange(location: 0, length: units.count), attributes as CFDictionary, true)
    return attributed
  }

  /// 左から右の段落（タブの刻みがあれば、その刻みで空ける）。
  private static func paragraphStyle(tabWidth: CGFloat) -> CTParagraphStyle {
    var direction = CTWritingDirection.leftToRight
    var interval = tabWidth
    let stops = [] as CFArray
    return withUnsafeBytes(of: &direction) { directionBytes in
      withUnsafeBytes(of: &interval) { intervalBytes in
        withUnsafeBytes(of: stops) { stopsBytes in
          var settings = [
            CTParagraphStyleSetting(
              spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
              value: directionBytes.baseAddress!)
          ]
          if tabWidth > 0 {
            settings += [
              CTParagraphStyleSetting(
                spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size,
                value: intervalBytes.baseAddress!),
              CTParagraphStyleSetting(
                spec: .tabStops, valueSize: MemoryLayout<CFArray>.size,
                value: stopsBytes.baseAddress!),
            ]
          }
          return CTParagraphStyleCreate(settings, settings.count)
        }
      }
    }
  }

  /// 書式文字の箱の幅を取る置き場（字の高さはフォントのまま）。
  private struct BoxMetrics {
    var ascent: CGFloat
    var descent: CGFloat
    var width: CGFloat
  }

  private static func boxDelegate(width: CGFloat, font: CTFont) -> CTRunDelegate {
    var callbacks = CTRunDelegateCallbacks(
      version: kCTRunDelegateVersion1,
      dealloc: { $0.deallocate() },
      getAscent: { $0.load(as: BoxMetrics.self).ascent },
      getDescent: { $0.load(as: BoxMetrics.self).descent },
      getWidth: { $0.load(as: BoxMetrics.self).width })
    let metrics = UnsafeMutablePointer<BoxMetrics>.allocate(capacity: 1)
    metrics.initialize(
      to: BoxMetrics(ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font), width: width))
    return CTRunDelegateCreate(&callbacks, metrics)!
  }
}

extension ShapedLine {
  /// 組んだ行から写す。書式文字の箱（`boxes`）の位置には、箱の中身の字を同じ元の位置で置く。`ascii` は等幅のフォントで
  /// 組み、描く単位がどれも ASCII の字かタブか。
  fileprivate init(
    _ line: CTLine, omitted: Int, boxes: [LineShaper.Box], font: CTFont, ascii: Bool
  ) {
    var runs: [Run] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      let attributes = CTRunGetAttributes(run)
      guard let runFont = GlyphFonts.font(of: run) else { continue }
      var glyphs = [CGGlyph](repeating: 0, count: count)
      var positions = [CGPoint](repeating: .zero, count: count)
      var indices = [CFIndex](repeating: 0, count: count)
      let all = CFRange(location: 0, length: count)
      CTRunGetGlyphs(run, all, &glyphs)
      CTRunGetPositions(run, all, &positions)
      CTRunGetStringIndices(run, all, &indices)
      guard
        CFDictionaryGetValue(
          attributes, Unmanaged.passUnretained(kCTRunDelegateAttributeName).toOpaque()) == nil
      else {
        for (position, index) in zip(positions, indices) {
          guard let unit = boxes.unit(at: index) else { continue }
          for label in LineShaper.shape(LineShaper.boxLabel(unit), font: font).runs {
            runs.append(
              Run(
                font: label.font, glyphs: label.glyphs, xs: label.xs.map { $0 + position.x },
                ys: label.ys, offsets: Array(repeating: index, count: label.glyphs.count)))
          }
        }
        continue
      }
      runs.append(
        Run(
          font: runFont, glyphs: glyphs, xs: positions.map(\.x), ys: positions.map(\.y),
          offsets: indices))
    }
    let offsets = runs.lazy.flatMap(\.offsets)
    let ordered =
      offsets.count == CTLineGetStringRange(line).length
      && zip(offsets, 0...).allSatisfy { $0 == $1 }
    self.init(
      runs: runs, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), omitted: omitted,
      line: line, simple: ascii && ordered)
  }
}

extension ShapedLine {
  /// 字の元の位置と x の列（run をまたいで並べたもの。x は左から右へ増えていく）。
  var stops: (offsets: [Int], xs: [CGFloat]) {
    (runs.flatMap(\.offsets), runs.flatMap(\.xs))
  }
}

extension [LineShaper.Box] {
  /// 位置の昇順の箱の列で、位置が `index` 以上の最初の箱の番号（無ければ `count`）。
  func firstBox(atOrAfter index: Int) -> Int {
    var low = 0
    var high = count
    while low < high {
      let mid = (low + high) / 2
      if self[mid].index < index { low = mid + 1 } else { high = mid }
    }
    return low
  }

  /// 位置 `index` の箱の元の字（箱が無ければ nil）。
  func unit(at index: Int) -> UInt16? {
    let found = firstBox(atOrAfter: index)
    return found < count && self[found].index == index ? self[found].unit : nil
  }
}
