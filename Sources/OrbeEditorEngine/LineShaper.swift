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

/// 行の組版の規則（純関数）。描画スレッドと、横の位置が要る main の操作が同じ規則を使う。
///
/// 行は文書の行（`\n` で割った行）の中身で、見せ方は VS Code の既定（`renderControlCharacters`）と同じ——行末の `\r` は
/// 描かない、C0 の制御文字は U+2400 台の記号、DEL は U+2421、U+2028・U+2029・U+0085 は U+FFFD。タブは次のタブ位置まで
/// 空ける。置き換えは 1 単位を 1 単位にするので、描く字の位置は元の行の位置と同じ。1 行で描くのは `limit` 単位まで
/// （書記素の境で切る）で、残りは描かない。
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

  /// 描く単位の列（上限を書記素の境で切り、制御文字を記号に置き換えたもの）と、打ち切って描かない単位の数。
  static func display(_ source: Source) -> (units: ContiguousArray<UInt16>, omitted: Int) {
    let cut = source.length > limit ? graphemeCut(source.head) : source.length
    var units = ContiguousArray(source.head[0..<cut])
    for i in units.indices {
      let u = units[i]
      if u < 0x20, u != 0x09 {
        units[i] = 0x2400 + u
      } else if u == 0x7F {
        units[i] = 0x2421
      } else if u == 0x2028 || u == 0x2029 || u == 0x85 {
        units[i] = 0xFFFD
      }
    }
    return (units, source.length - cut)
  }

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
    let (units, omitted) = display(source)
    return ShapedLine(makeLine(units, font: font, tabWidth: tabWidth), omitted: omitted)
  }

  /// 文字列を 1 行として組む（打ち切った行の末尾の印など）。
  static func shape(_ string: String, font: CTFont) -> ShapedLine {
    ShapedLine(makeLine(ContiguousArray(string.utf16), font: font, tabWidth: 0), omitted: 0)
  }

  /// 行の中の位置 `offset`（UTF-16）の字の左端の x（pt）。描かない部分は描いた部分の右端。
  static func x(ofOffset offset: Int, in source: Source, font: CTFont, tabWidth: CGFloat) -> CGFloat
  {
    let (units, _) = display(source)
    let line = makeLine(units, font: font, tabWidth: tabWidth)
    guard offset < units.count else {
      return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
    return CTLineGetOffsetForStringIndex(line, max(0, offset), nil)
  }

  private static func makeLine(
    _ units: ContiguousArray<UInt16>, font: CTFont, tabWidth: CGFloat
  ) -> CTLine {
    let string = units.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    var attributes: [CFString: Any] = [kCTFontAttributeName: font]
    if tabWidth > 0 {
      var interval = tabWidth
      let stops = [] as CFArray
      attributes[kCTParagraphStyleAttributeName] = withUnsafeBytes(of: &interval) { intervalBytes in
        withUnsafeBytes(of: stops) { stopsBytes in
          let settings = [
            CTParagraphStyleSetting(
              spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size,
              value: intervalBytes.baseAddress!),
            CTParagraphStyleSetting(
              spec: .tabStops, valueSize: MemoryLayout<CFArray>.size,
              value: stopsBytes.baseAddress!),
          ]
          return CTParagraphStyleCreate(settings, settings.count)
        }
      }
    }
    let attributed = CFAttributedStringCreate(nil, string, attributes as CFDictionary)!
    return CTLineCreateWithAttributedString(attributed)
  }
}

extension ShapedLine {
  fileprivate init(_ line: CTLine, omitted: Int) {
    var runs: [Run] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      guard
        let value = CFDictionaryGetValue(
          CTRunGetAttributes(run), Unmanaged.passUnretained(kCTFontAttributeName).toOpaque())
      else { continue }
      let font = Unmanaged<CTFont>.fromOpaque(value).takeUnretainedValue()
      var glyphs = [CGGlyph](repeating: 0, count: count)
      var positions = [CGPoint](repeating: .zero, count: count)
      var indices = [CFIndex](repeating: 0, count: count)
      let all = CFRange(location: 0, length: count)
      CTRunGetGlyphs(run, all, &glyphs)
      CTRunGetPositions(run, all, &positions)
      CTRunGetStringIndices(run, all, &indices)
      runs.append(
        Run(font: font, glyphs: glyphs, xs: positions.map(\.x), offsets: indices))
    }
    self.init(
      runs: runs, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), omitted: omitted)
  }
}
