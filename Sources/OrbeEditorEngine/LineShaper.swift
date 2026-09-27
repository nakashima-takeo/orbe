import CoreText
import Foundation
import OrbeEditorCore

/// 1 行を組んだ結果——run ごとのフォント・グリフ・x（pt、行頭から）・元の行の UTF-16 の位置（色を引くため）と、行の幅、
/// 上限で打ち切って描かない UTF-16 の単位の数。
struct ShapedLine {
  struct Run {
    let font: CTFont
    let glyphs: [CGGlyph]
    let xs: [CGFloat]
    let offsets: [Int]
  }

  let runs: [Run]
  let width: CGFloat
  let omitted: Int
}

/// main が横の位置を問うために 1 度組んだ行。幅も行の中の位置の x もこの値に問い、同じ行を何度も組まない。`CTLine` を
/// 持つので、組んだスレッドの外へ出さない。
struct MeasuredLine {
  private let line: CTLine
  /// 描いた単位の数（打ち切った分を除く）。
  private let displayed: Int
  let width: CGFloat

  fileprivate init(_ line: CTLine, displayed: Int) {
    self.line = line
    self.displayed = displayed
    width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  /// 行の中の位置 `offset`（UTF-16）の字の左端の x（pt）。描かない部分は描いた部分の右端。
  func x(ofOffset offset: Int) -> CGFloat {
    guard offset < displayed else { return width }
    return CTLineGetOffsetForStringIndex(line, max(0, offset), nil)
  }
}

@available(*, unavailable)
extension MeasuredLine: Sendable {}

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
  /// 書記素の境を探すために、上限より余分に読む単位の数。
  private static let lookahead = 64

  /// 行の中身のうち描きうる先頭（上限と余分まで）と、行の長さ（行末の改行と `\r` を除く）。長い行でも読むのは先頭だけ。
  struct Source: Hashable {
    var head: ContiguousArray<UInt16>
    var length: Int
  }

  /// 文書の行 `row` の中身と行頭のオフセット。
  static func source(row: Int, in text: TextRope) -> (source: Source, start: Int) {
    let start = text.lineStart(row)
    var end = row + 1 < text.lineCount ? text.lineStart(row + 1) - 1 : text.length
    if end > start, text.units(in: NSRange(location: end - 1, length: 1)).first == 0x0D { end -= 1 }
    let head = text.units(
      in: NSRange(location: start, length: min(end - start, limit + lookahead)))
    return (Source(head: head, length: end - start), start)
  }

  /// 描く単位の列（上限を書記素の境で切り、制御文字を記号に置き換えたもの）と、打ち切って描かない単位の数と、箱で
  /// 見せる書式文字（描く単位の位置 → 元の字）。箱の位置の単位は、並びに効かない U+FFFC に置き換える。
  struct Displayed {
    var units: ContiguousArray<UInt16>
    var omitted: Int
    var boxes: [Int: UInt16]
  }

  static func display(_ source: Source) -> Displayed {
    let cut = source.length > limit ? graphemeCut(source.head) : source.length
    var units = ContiguousArray(source.head[0..<cut])
    var boxes: [Int: UInt16] = [:]
    for i in units.indices {
      let u = units[i]
      if u < 0x20, u != 0x09 {
        units[i] = 0x2400 + u
      } else if u == 0x7F {
        units[i] = 0x2421
      } else if u == 0x2028 || u == 0x2029 || u == 0x85 || u == 0xFEFF {
        units[i] = 0xFFFD
      } else if isDirectionalFormat(u) {
        boxes[i] = u
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

  /// `limit` 以下で最も後ろの書記素の境（1 つの書記素が上限を越えるほど長ければ `limit`）。
  private static func graphemeCut(_ head: ContiguousArray<UInt16>) -> Int {
    var cut = 0
    for character in String(decoding: head, as: UTF16.self) {
      let next = cut + character.utf16.count
      guard next <= limit else { break }
      cut = next
    }
    return cut > 0 ? cut : limit
  }

  /// 行を組む。`tabWidth` はタブの刻み（pt）。
  static func shape(_ source: Source, font: CTFont, tabWidth: CGFloat) -> ShapedLine {
    let shown = display(source)
    let line = makeLine(shown.units, boxes: shown.boxes, font: font, tabWidth: tabWidth)
    return ShapedLine(line, omitted: shown.omitted, boxes: shown.boxes, font: font)
  }

  /// 文字列を 1 行として組む（打ち切った行の末尾の印・書式文字の箱の中身）。
  static func shape(_ string: String, font: CTFont) -> ShapedLine {
    let line = makeLine(ContiguousArray(string.utf16), boxes: [:], font: font, tabWidth: 0)
    return ShapedLine(line, omitted: 0, boxes: [:], font: font)
  }

  /// 横の位置を問うために行を 1 度組む（main）。
  static func measure(_ source: Source, font: CTFont, tabWidth: CGFloat) -> MeasuredLine {
    let shown = display(source)
    return MeasuredLine(
      makeLine(shown.units, boxes: shown.boxes, font: font, tabWidth: tabWidth),
      displayed: shown.units.count)
  }

  private static func makeLine(
    _ units: ContiguousArray<UInt16>, boxes: [Int: UInt16], font: CTFont, tabWidth: CGFloat
  ) -> CTLine {
    let string = units.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let attributes: [CFString: Any] = [
      kCTFontAttributeName: font,
      kCTParagraphStyleAttributeName: paragraphStyle(tabWidth: tabWidth),
    ]
    let attributed = CFAttributedStringCreateMutable(nil, 0)!
    CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
    CFAttributedStringSetAttributes(
      attributed, CFRange(location: 0, length: units.count), attributes as CFDictionary, true)
    for (index, unit) in boxes {
      CFAttributedStringSetAttribute(
        attributed, CFRange(location: index, length: 1), kCTRunDelegateAttributeName,
        boxDelegate(width: shape(boxLabel(unit), font: font).width, font: font))
    }
    return CTLineCreateWithAttributedString(attributed)
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
  /// 組んだ行から写す。書式文字の箱（`boxes`）の位置には、箱の中身の字を同じ元の位置で置く。
  fileprivate init(_ line: CTLine, omitted: Int, boxes: [Int: UInt16], font: CTFont) {
    var runs: [Run] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      let attributes = CTRunGetAttributes(run)
      guard
        let value = CFDictionaryGetValue(
          attributes, Unmanaged.passUnretained(kCTFontAttributeName).toOpaque())
      else { continue }
      let runFont = Unmanaged<CTFont>.fromOpaque(value).takeUnretainedValue()
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
          guard let unit = boxes[index] else { continue }
          for label in LineShaper.shape(LineShaper.boxLabel(unit), font: font).runs {
            runs.append(
              Run(
                font: label.font, glyphs: label.glyphs, xs: label.xs.map { $0 + position.x },
                offsets: Array(repeating: index, count: label.glyphs.count)))
          }
        }
        continue
      }
      runs.append(
        Run(font: runFont, glyphs: glyphs, xs: positions.map(\.x), offsets: indices))
    }
    self.init(
      runs: runs, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), omitted: omitted)
  }
}
