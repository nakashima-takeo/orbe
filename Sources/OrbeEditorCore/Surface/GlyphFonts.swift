import CoreText
import Foundation
import os

/// 字（書記素）ごとの字体と幅の表。テキスト面の行の組版と、絵の差し込みの字組み（`ZoneComposition`）が、字の字体を前後の
/// 字に依らず決めるために引き、テキスト面の行の折り返しが、字の幅を引く。
///
/// 字の字体は、その字だけを、組む字体（本文なら本文の字体、絵の差し込みの字なら見え方の字体。以下、本体の字体）で
/// Core Text に組ませたときに選ばれる字体。Core Text は、本体の字体に無い字を、直前の字の代替フォントがその字を持って
/// いればそのフォントで続けて描く（和文の後ろの `※` は和文の字体、行頭の `※` は Monaco）ので、行を組んだ結果の字体は
/// 場所で変わる。この表の字体は場所で変わらない。字の幅は、その字だけを組んだ行の幅。
///
/// 本体の字体ごとにプロセスに 1 つ持ち、初めて出た字をその字だけ組んで覚え、組み直さない。描画スレッド・main・絵の差し込みの
/// 字を裏で組むスレッドが引くので鍵で守る。鍵は行 1 つを引く 1 回ごとに取り、表を読む・書く間だけ持つ——字を組む間は
/// 持たないので、どのスレッドも、ほかのスレッドが字を組む時間のあいだ待たない。同じ字を 2 つのスレッドが同時に組んでも
/// 答えは同じなので、後から書いた方で上書きしてよい。
public enum GlyphFonts {
  /// 行の字の、単位ごとの字体と幅。書記素の続きの単位は、頭の単位と同じ字体。
  public struct Glyphs {
    fileprivate let slots: [UInt16]
    fileprivate let fonts: [CTFont]
    /// 単位で始まる字の幅（書記素の続きの単位は NaN）。
    fileprivate let widths: [Float]

    /// 単位 `index` を含む字の字体（字の部分ごとに字体が分かれ、1 つに決まらない字は nil）。
    public func font(at index: Int) -> CTFont? {
      let slot = slots[index]
      return slot >= Slot.firstFont ? fonts[Int(slot - Slot.firstFont)] : nil
    }

    /// 単位 `index` と `other` の字が同じ字体か（どちらも 1 つに決まらない字なら真）。
    public func sameFont(_ index: Int, _ other: Int) -> Bool { slots[index] == slots[other] }

    /// 単位 `index` で始まる字の幅（pt。書記素の続きの単位なら nil）。
    public func width(at index: Int) -> CGFloat? {
      let width = widths[index]
      return width.isNaN ? nil : CGFloat(width)
    }
  }

  /// 字体の番号（`unknown`・`mixed`、または `firstFont` からの字体の番号）。
  fileprivate enum Slot {
    static let unknown: UInt16 = 0
    static let mixed: UInt16 = 1
    static let firstFont: UInt16 = 2
  }

  /// 字 1 つの覚え——字体の番号と幅（pt）。
  private struct Entry {
    var slot: UInt16
    var width: Float
  }

  /// 本体の字体 1 つの表。1 単位の字は、単位の上位 8 bit の頁と下位 8 bit で引き（頁は初めて使うときに作る。頁 0 は
  /// どの字も未知の頁）、2 単位以上の字は、字の単位の列で引く。字体の番号 `firstFont` は本体の字体。字体（`CTFont`）は
  /// 変わらない値で、どのスレッドから使ってもよい。
  private struct Table: @unchecked Sendable {
    let font: CTFont
    /// 本体の字体が、どの ASCII の字（U+0020…U+007E）も持つか。
    let coversASCII: Bool
    var fonts: [CTFont]
    var pages = [UInt16](repeating: 0, count: 256)
    var storage = [UInt16](repeating: Slot.unknown, count: 256)
    var advances = [Float](repeating: .nan, count: 256)
    var clusters: [ContiguousArray<UInt16>: Entry] = [:]

    init(font: CTFont) {
      self.font = font
      var units = (0x20...0x7E).map { UniChar($0) }
      var glyphs = [CGGlyph](repeating: 0, count: units.count)
      coversASCII = CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
      fonts = [font]
    }

    func slot(_ unit: UInt16) -> UInt16 {
      storage[Int(pages[Int(unit >> 8)]) << 8 | Int(unit & 0xFF)]
    }

    func advance(_ unit: UInt16) -> Float {
      advances[Int(pages[Int(unit >> 8)]) << 8 | Int(unit & 0xFF)]
    }

    mutating func set(_ entry: Entry, for cluster: ContiguousArray<UInt16>) {
      guard cluster.count == 1 else { return clusters[cluster] = entry }
      let unit = cluster[0]
      if pages[Int(unit >> 8)] == 0 {
        pages[Int(unit >> 8)] = UInt16(storage.count >> 8)
        storage.append(contentsOf: repeatElement(Slot.unknown, count: 256))
        advances.append(contentsOf: repeatElement(.nan, count: 256))
      }
      let index = Int(pages[Int(unit >> 8)]) << 8 | Int(unit & 0xFF)
      storage[index] = entry.slot
      advances[index] = entry.width
    }

    mutating func slot(of font: CTFont) -> UInt16 {
      if let index = fonts.firstIndex(where: { $0 === font })
        ?? fonts.firstIndex(where: { CFEqual($0, font) })
      {
        return UInt16(index) + Slot.firstFont
      }
      fonts.append(font)
      return UInt16(fonts.count - 1) + Slot.firstFont
    }
  }

  private static let tables = OSAllocatedUnfairLock<[Table]>(initialState: [])

  /// 本体の字体 `font` で、行の字 `units`（描く単位の列）を引く。初めて出た字は、その字だけを組んで覚える。
  public static func glyphs(_ units: ContiguousArray<UInt16>, font: CTFont) -> Glyphs {
    var unknown: [Range<Int>] = []
    var lookup: Lookup
    var fonts: [CTFont]
    (lookup, fonts) = tables.withLockUnchecked { tables -> (Lookup, [CTFont]) in
      let table = index(of: font, in: &tables)
      return (read(units, tables[table], unknown: &unknown), tables[table].fonts)
    }
    guard !unknown.isEmpty else {
      return Glyphs(slots: lookup.slots, fonts: fonts, widths: lookup.widths)
    }
    let clusters = Set(unknown.map { ContiguousArray(units[$0]) })
    let found = Dictionary(uniqueKeysWithValues: clusters.map { ($0, alone($0, font: font)) })
    var assigned: [ContiguousArray<UInt16>: Entry] = [:]
    fonts = tables.withLockUnchecked { tables in
      let table = index(of: font, in: &tables)
      for (cluster, alone) in found {
        let entry = Entry(
          slot: alone.font.map { tables[table].slot(of: $0) } ?? Slot.mixed, width: alone.width)
        tables[table].set(entry, for: cluster)
        assigned[cluster] = entry
      }
      return tables[table].fonts
    }
    for range in unknown {
      let entry = assigned[ContiguousArray(units[range])]!
      for index in range { lookup.slots[index] = entry.slot }
      lookup.widths[range.lowerBound] = entry.width
    }
    return Glyphs(slots: lookup.slots, fonts: fonts, widths: lookup.widths)
  }

  /// 本体の字体 `font` での、ASCII の字（U+0020…U+007E）の幅（pt。`code − 0x20` 番目）。
  public static func asciiWidths(_ font: CTFont) -> [CGFloat] {
    let glyphs = glyphs(ContiguousArray((0x20...0x7E).map { UInt16($0) }), font: font)
    return (0..<95).map { glyphs.width(at: $0) ?? 0 }
  }

  /// 本体の字体 `font` が、どの ASCII の字（U+0020…U+007E）も持つか。持つなら、ASCII の字だけの行は、Core Text がどの字も
  /// 本体の字体で組むので、表の字体と同じになる。
  public static func coversASCII(_ font: CTFont) -> Bool {
    tables.withLockUnchecked { tables in tables[index(of: font, in: &tables)].coversASCII }
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

  /// 表から引いた行の字の、単位ごとの字体の番号と幅。
  private typealias Lookup = (slots: [UInt16], widths: [Float])

  /// 表 `table` から行の字を引く。表に無い字の範囲を `unknown` に足す（その字の単位は未知のまま）。
  private static func read(
    _ units: ContiguousArray<UInt16>, _ table: Table, unknown: inout [Range<Int>]
  ) -> Lookup {
    var slots = [UInt16](repeating: Slot.unknown, count: units.count)
    var widths = [Float](repeating: .nan, count: units.count)
    if units.allSatisfy(isStandalone) {
      for (index, unit) in units.enumerated() {
        let slot = table.slot(unit)
        slots[index] = slot
        widths[index] = table.advance(unit)
        if slot == Slot.unknown { unknown.append(index..<index + 1) }
      }
      return (slots, widths)
    }
    var location = 0
    for character in String(decoding: units, as: UTF16.self) {
      let range = location..<location + character.utf16.count
      location = range.upperBound
      let entry =
        range.count == 1
        ? Entry(
          slot: table.slot(units[range.lowerBound]), width: table.advance(units[range.lowerBound]))
        : table.clusters[ContiguousArray(units[range])] ?? Entry(slot: Slot.unknown, width: .nan)
      guard entry.slot != Slot.unknown else {
        unknown.append(range)
        continue
      }
      for index in range { slots[index] = entry.slot }
      widths[range.lowerBound] = entry.width
    }
    return (slots, widths)
  }

  /// 字 `cluster` だけを本体の字体 `font` で組んだときの字体（字の部分ごとに分かれれば nil）と、組んだ行の幅。
  private static func alone(_ cluster: ContiguousArray<UInt16>, font: CTFont) -> (
    font: CTFont?, width: Float
  ) {
    let string = cluster.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let attributes: [CFString: Any] = [
      kCTFontAttributeName: font, kCTLanguageAttributeName: TextLanguage.neutral,
    ]
    let line = CTLineCreateWithAttributedString(
      CFAttributedStringCreate(nil, string, attributes as CFDictionary))
    let fonts = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).compactMap(self.font(of:))
    return (
      fonts.first.flatMap { first in fonts.allSatisfy { CFEqual($0, first) } ? first : nil },
      Float(CTLineGetTypographicBounds(line, nil, nil, nil))
    )
  }

  /// run を組んだフォント。
  public static func font(of run: CTRun) -> CTFont? {
    CFDictionaryGetValue(
      CTRunGetAttributes(run), Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
    ).map { Unmanaged<CTFont>.fromOpaque($0).takeUnretainedValue() }
  }

  /// 単位が単独の字——隣がどの単独の字でも、その隣と書記素を作らない字——か。単独の字とするのは、結合する記号・字を
  /// 合わせる記号・字母の組み合わせ・サロゲート・字の前に付く記号と、CR（後ろの LF と書記素を作る）のどれも含まない
  /// 区画の字。単位がどれも単独の字なら、単位 1 つが字 1 つになる。それ以外の単位を含む行は、書記素ごとに引く。
  private static func isStandalone(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x0000...0x000C, 0x000E...0x02FF, 0x0370...0x0482, 0x048A...0x058F, 0x1E00...0x1FFF,
      0x2010...0x20CF, 0x2100...0x2BFF, 0x2E00...0x3029, 0x3030...0x3098, 0x309B...0x9FFF,
      0xAC00...0xD7A3, 0xE000...0xFAFF, 0xFE10...0xFE1F, 0xFE30...0xFE6F, 0xFF00...0xFF9D,
      0xFFA0...0xFFEF, 0xFFFC, 0xFFFD:
      return true
    default:
      return false
    }
  }
}
