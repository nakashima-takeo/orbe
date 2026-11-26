import CoreText
import Foundation
import os

/// 字（書記素）ごとの字体と幅の表。テキスト面の行の組版と、絵の差し込みの字組み（`ZoneComposition`）が、字の字体を前後の
/// 字に依らず決めるために引く。
///
/// 字の字体は、その字だけを、組む字体（本文なら本文の字体、絵の差し込みの字なら見え方の字体。以下、本体の字体）で
/// Core Text に組ませたときに選ばれる字体で、幅はその字だけを組んだ幅。Core Text は、本体の字体に無い字を、直前の字の
/// 代替フォントがその字を持っていればそのフォントで続けて描く（和文の後ろの `※` は和文の字体、行頭の `※` は Monaco）ので、
/// 行を組んだ結果の字体は場所で変わる。この表の字体は場所で変わらない。
///
/// 本体の字体ごとにプロセスに 1 つ持ち、初めて出た字をその字だけ組んで覚え、測り直さない。描画スレッド・main・絵の差し込みの
/// 字を裏で組むスレッドが引くので鍵で守る。鍵は行 1 つを引く 1 回ごとに取り、表を読む・書く間だけ持つ——字を組んで測る間は
/// 持たないので、どのスレッドも、ほかのスレッドが字を組む時間のあいだ待たない。同じ字を 2 つのスレッドが同時に測っても
/// 答えは同じなので、後から書いた方で上書きしてよい。
public enum GlyphFonts {
  /// 行の字の、単位ごとの字体と幅。書記素の続きの単位は、頭の単位と同じ字体で、幅 0。
  public struct Glyphs {
    fileprivate let entries: [Entry]
    fileprivate let fonts: [CTFont]

    /// 単位 `index` を含む字の字体（字の部分ごとに字体が分かれ、1 つに決まらない字は nil）。
    public func font(at index: Int) -> CTFont? {
      let slot = entries[index].slot
      return slot >= Entry.firstFont ? fonts[Int(slot - Entry.firstFont)] : nil
    }

    /// 単位 `index` が頭の字の幅（続きの単位は 0）。
    public func width(at index: Int) -> CGFloat { CGFloat(entries[index].width) }

    /// 単位 `index` と `other` の字が同じ字体か（どちらも 1 つに決まらない字なら真）。
    public func sameFont(_ index: Int, _ other: Int) -> Bool {
      entries[index].slot == entries[other].slot
    }
  }

  fileprivate struct Entry {
    /// 字体の番号（`unknown`・`mixed`、または `firstFont` からの字体の番号）。
    var slot: UInt16
    var width: Float

    static let unknown: UInt16 = 0
    static let mixed: UInt16 = 1
    static let firstFont: UInt16 = 2
  }

  /// 本体の字体 1 つの表。1 単位の字は、単位の上位 8 bit の頁と下位 8 bit で引き（頁は初めて使うときに作る。頁 0 は
  /// どの字も未知の頁）、2 単位以上の字は、字の単位の列で引く。字体の番号 `firstFont` は本体の字体。字体（`CTFont`）は
  /// 変わらない値で、どのスレッドから使ってもよい。
  private struct Table: @unchecked Sendable {
    let font: CTFont
    var fonts: [CTFont]
    var pages = [UInt16](repeating: 0, count: 256)
    var storage = [Entry](repeating: Entry(slot: Entry.unknown, width: 0), count: 256)
    var clusters: [ContiguousArray<UInt16>: Entry] = [:]

    init(font: CTFont) {
      self.font = font
      fonts = [font]
    }

    func entry(_ unit: UInt16) -> Entry {
      storage[Int(pages[Int(unit >> 8)]) << 8 | Int(unit & 0xFF)]
    }

    mutating func set(_ entry: Entry, for cluster: ContiguousArray<UInt16>) {
      guard cluster.count == 1 else { return clusters[cluster] = entry }
      let unit = cluster[0]
      if pages[Int(unit >> 8)] == 0 {
        pages[Int(unit >> 8)] = UInt16(storage.count >> 8)
        storage.append(contentsOf: repeatElement(Entry(slot: Entry.unknown, width: 0), count: 256))
      }
      storage[Int(pages[Int(unit >> 8)]) << 8 | Int(unit & 0xFF)] = entry
    }

    mutating func slot(of font: CTFont) -> UInt16 {
      let index =
        fonts.firstIndex { $0 === font } ?? fonts.firstIndex { CFEqual($0, font) }
        ?? {
          fonts.append(font)
          return fonts.count - 1
        }()
      return UInt16(index) + Entry.firstFont
    }
  }

  private static let tables = OSAllocatedUnfairLock<[Table]>(initialState: [])

  /// 本体の字体 `font` で、行の字 `units`（描く単位の列）を引く。初めて出た字は、その字だけを組んで覚える。
  public static func glyphs(_ units: ContiguousArray<UInt16>, font: CTFont) -> Glyphs {
    var unknown: [Range<Int>] = []
    var (entries, fonts) = tables.withLockUnchecked { tables in
      let table = index(of: font, in: &tables)
      return (read(units, tables[table], unknown: &unknown), tables[table].fonts)
    }
    guard !unknown.isEmpty else { return Glyphs(entries: entries, fonts: fonts) }
    var measured: [ContiguousArray<UInt16>: (font: CTFont?, width: CGFloat)] = [:]
    for range in unknown where measured[ContiguousArray(units[range])] == nil {
      measured[ContiguousArray(units[range])] = measure(ContiguousArray(units[range]), font: font)
    }
    var slots: [ContiguousArray<UInt16>: UInt16] = [:]
    fonts = tables.withLockUnchecked { tables in
      let table = index(of: font, in: &tables)
      for (cluster, value) in measured {
        let slot = value.font.map { tables[table].slot(of: $0) } ?? Entry.mixed
        tables[table].set(Entry(slot: slot, width: Float(value.width)), for: cluster)
        slots[cluster] = slot
      }
      return tables[table].fonts
    }
    for range in unknown {
      let cluster = ContiguousArray(units[range])
      entries[range.lowerBound] = Entry(
        slot: slots[cluster]!, width: Float(measured[cluster]!.width))
      for index in range.dropFirst() { entries[index].slot = slots[cluster]! }
    }
    return Glyphs(entries: entries, fonts: fonts)
  }

  private static func index(of font: CTFont, in tables: inout [Table]) -> Int {
    if let index = tables.firstIndex(where: { $0.font === font })
      ?? tables.firstIndex(where: { CFEqual($0.font, font) })
    {
      return index
    }
    tables.append(Table(font: font))
    return tables.count - 1
  }

  /// 表 `table` から行の字を引く。表に無い字の範囲を `unknown` に足す（その字の項目は未知のまま）。
  private static func read(
    _ units: ContiguousArray<UInt16>, _ table: Table, unknown: inout [Range<Int>]
  ) -> [Entry] {
    var entries = [Entry](repeating: Entry(slot: Entry.unknown, width: 0), count: units.count)
    if units.allSatisfy(isStandalone) {
      for (index, unit) in units.enumerated() {
        let entry = table.entry(unit)
        entries[index] = entry
        if entry.slot == Entry.unknown { unknown.append(index..<index + 1) }
      }
      return entries
    }
    var location = 0
    for character in String(decoding: units, as: UTF16.self) {
      let range = location..<location + character.utf16.count
      location = range.upperBound
      let entry =
        range.count == 1
        ? table.entry(units[range.lowerBound])
        : table.clusters[ContiguousArray(units[range])] ?? Entry(slot: Entry.unknown, width: 0)
      guard entry.slot != Entry.unknown else {
        unknown.append(range)
        continue
      }
      entries[range.lowerBound] = entry
      for index in range.dropFirst() { entries[index].slot = entry.slot }
    }
    return entries
  }

  /// 字 `cluster` だけを本体の字体 `font` で組んだときの字体（字の部分ごとに分かれれば nil）と幅。
  private static func measure(_ cluster: ContiguousArray<UInt16>, font: CTFont) -> (
    font: CTFont?, width: CGFloat
  ) {
    let string = cluster.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let attributes: [CFString: Any] = [
      kCTFontAttributeName: font, kCTLanguageAttributeName: TextLanguage.neutral,
    ]
    let line = CTLineCreateWithAttributedString(
      CFAttributedStringCreate(nil, string, attributes as CFDictionary))
    let fonts = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).compactMap(font(of:))
    let single = fonts.first.flatMap { first in
      fonts.allSatisfy { CFEqual($0, first) } ? first : nil
    }
    return (single, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
  }

  /// run を組んだフォント。
  public static func font(of run: CTRun) -> CTFont? {
    CFDictionaryGetValue(
      CTRunGetAttributes(run), Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
    ).map { Unmanaged<CTFont>.fromOpaque($0).takeUnretainedValue() }
  }

  /// 単位が単独の字——隣がどの単独の字でも、その隣と書記素を作らない字——か。単独の字とするのは、結合する記号・字を
  /// 合わせる記号・字母の組み合わせ・サロゲート・字の前に付く記号のどれも含まない区画の字。単位がどれも単独の字なら、
  /// 単位 1 つが字 1 つになる。それ以外の単位を含む行は、書記素ごとに引く。
  private static func isStandalone(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x0000...0x02FF, 0x0370...0x0482, 0x048A...0x058F, 0x1E00...0x1FFF, 0x2010...0x20CF,
      0x2100...0x2BFF, 0x2E00...0x3029, 0x3030...0x3098, 0x309B...0x9FFF, 0xAC00...0xD7A3,
      0xE000...0xFAFF, 0xFE10...0xFE1F, 0xFE30...0xFE6F, 0xFF00...0xFF9D, 0xFFA0...0xFFEF,
      0xFFFC, 0xFFFD:
      return true
    default:
      return false
    }
  }
}
