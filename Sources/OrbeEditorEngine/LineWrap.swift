import CoreText
import Foundation
import OrbeEditorCore

/// 折り返した行——2 段目からの段の始まり（描く単位の位置。昇順）と、続きの段の字下げ（pt）。段の始まりが描く単位の数と
/// 同じなら、その段は打ち切った行の末尾の印だけを持つ。
struct WrappedLine: Equatable, Sendable {
  var starts: [Int32]
  var indent: Float
  /// 最後の段より前の各段について、その段の終わりを決めるために読んだ、描く単位の区間の終わり（その位置を含まない）。
  /// これより後ろだけを変えた編集では、その段の終わりは変わらない（→ `LineWrap.Resume`）。
  var ends: [Int32]

  /// 段の数。
  var segments: Int { starts.count + 1 }

  /// 段 `segment` の始まり（描く単位の位置）。
  func start(of segment: Int) -> Int { segment == 0 ? 0 : Int(starts[segment - 1]) }

  /// 位置 `column`（描く単位）を含む段。段の境の位置は、`upstream`（付き）なら上の段の終わり、そうでなければ下の段の頭。
  func segment(containing column: Int, upstream: Bool = false) -> Int {
    var low = 0
    var high = starts.count
    while low < high {
      let mid = (low + high) / 2
      let start = Int(starts[mid])
      if start < column || (start == column && !upstream) { low = mid + 1 } else { high = mid }
    }
    return low
  }
}

/// 行の折り返しの規則（純関数）。行の描く単位の列（`LineShaper.display` の後）を、字ごとの幅の足し算で段に分ける。字の幅は
/// 字ごとの字体と幅の表（`GlyphFonts`）の幅で、タブは段の頭から数えた次のタブ位置まで、書式文字の箱は箱の幅、打ち切った行の
/// 末尾の印は途中で分けない 1 字として数える。計算するのは main だけで、結果は縦の並びに載る。
///
/// 段を分けてよい位置は VS Code の既定（`wordWrapBreakBeforeCharacters`・`wordWrapBreakAfterCharacters` と、和文の字の
/// 前後）と同じ決め方で、空白の前では分けない。違いは、前後で分けてよい字の表を和文の字の範囲より先に引くこと——小書きの
/// かなと長音は、その後ろでだけ分けてよい字なので、行頭に来ない。分けてよい位置が無いまま幅を越えたら、書記素の境で分ける。
/// どの段にも書記素が 1 つは入る。
enum LineWrap {
  /// 折り返しの寸法。
  struct Metrics {
    let font: CTFont
    /// 折り返しの幅（pt）。
    let width: CGFloat
    /// タブの刻み（pt）。
    let tabWidth: CGFloat
    /// ASCII の字の幅（`GlyphFonts.asciiWidths`）。
    let ascii: [CGFloat]
    /// 打ち切った行の末尾の印の幅（打ち切った単位の数から。印の前の空きを含む）。
    let omittedWidth: (Int) -> CGFloat

    init(
      font: CTFont, width: CGFloat, tabWidth: CGFloat, ascii: [CGFloat]? = nil,
      omittedWidth: @escaping (Int) -> CGFloat
    ) {
      self.font = font
      self.width = width
      self.tabWidth = tabWidth
      self.ascii = ascii ?? GlyphFonts.asciiWidths(font)
      self.omittedWidth = omittedWidth
    }
  }

  /// 字の種類（VS Code の `CharacterClass`）。
  enum Kind {
    case none
    /// その前で分けてよい字（開き括弧など）。
    case before
    /// その後ろで分けてよい字（空白・閉じ括弧・句読点・小書きのかななど）。
    case after
    /// 和文の字（漢字・かな・全角の字）。
    case ideographic
  }

  /// 前の折り返しを引き継ぐ手がかり——編集の前の折り返し `old` と、編集の始まり（描く単位の位置。その前の単位は編集で
  /// 変わらない）。段を頭から決めるとき、結果は段の始まりの位置とその後ろの単位だけで決まる。そのため、終わりを決めるのに
  /// 編集の始まりより前だけを読んだ段は、そのまま引き継げる。
  struct Resume: Sendable {
    let old: WrappedLine
    let edited: Int

    /// 引き継ぐ頭の段（行の頭から続く、終わりを決めるのに編集の始まりより前だけを読んだ段）。字下げが変われば引き継がない。
    func kept(indent: Float) -> WrappedLine {
      guard old.indent == indent else { return WrappedLine(starts: [], indent: indent, ends: []) }
      let kept = old.ends.firstIndex { Int($0) >= edited } ?? old.ends.count
      return WrappedLine(
        starts: Array(old.starts[..<kept]), indent: indent, ends: Array(old.ends[..<kept]))
    }
  }

  /// 行を折り返す。1 段に収まれば nil。`resuming` があれば、編集の前の折り返しから変わらない頭の段を引き継ぎ、その後ろ
  /// だけを決め直す（長い行の行末で打つとき、行の全部を読み直さない）。
  static func wrap(
    _ shown: LineShaper.Displayed, _ metrics: Metrics, resuming: Resume? = nil
  ) -> WrappedLine? {
    let units = shown.units
    let count = units.count
    let width = metrics.width
    let boxes = shown.boxes
    if shown.omitted == 0, boxes.isEmpty, fitsASCII(units, metrics) { return nil }
    let glyphs: GlyphFonts.Glyphs? =
      LineShaper.isASCII(units) && boxes.isEmpty
      ? nil : GlyphFonts.glyphs(units, font: metrics.font)
    let tab = metrics.tabWidth
    /// 単位 `index` で始まる字の幅（字の続きの単位なら nil）。`x` は段の頭からの位置（タブの幅を決める）。
    func advance(_ index: Int, at x: CGFloat) -> CGFloat? {
      let unit = units[index]
      if unit == 0x09 { return tabAdvance(at: x, tab) }
      if !boxes.isEmpty, let label = boxes[index] {
        return LineShaper.shape(LineShaper.boxLabel(label), font: metrics.font).width
      }
      guard let glyphs else { return metrics.ascii[Int(unit) - 0x20] }
      return glyphs.width(at: index)
    }
    let indent = indentWidth(units, advance: advance, width: width)
    let mark = shown.omitted > 0 ? metrics.omittedWidth(shown.omitted) : 0
    var result =
      resuming.map { $0.kept(indent: indent) } ?? WrappedLine(starts: [], indent: indent, ends: [])
    var segment = result.starts.last.map(Int.init) ?? 0
    var limit = result.starts.isEmpty ? width : width - CGFloat(indent)
    var x: CGFloat = 0
    var opportunity: Int?
    var previous = Kind.none
    var index = segment
    while index <= count {
      let isMark = index == count
      guard !isMark || mark > 0 else { break }
      guard let w = isMark ? mark : advance(index, at: x) else {
        index += 1
        continue
      }
      let kind = isMark ? Kind.ideographic : self.kind(units, at: index)
      if index > segment, isMark || canBreak(after: previous, before: units[index], kind) {
        opportunity = index
      }
      if index > segment, x + w > limit {
        let cut = opportunity ?? index
        result.starts.append(Int32(cut))
        // 読んだのは、幅を越えた字（書記素）まで。打ち切った行の末尾の印の幅で越えたら、行の終わりまで読んだ。
        var end = index + 1
        while end < count, advance(end, at: 0) == nil { end += 1 }
        result.ends.append(Int32(isMark ? count + 1 : end))
        segment = cut
        index = cut
        x = 0
        opportunity = nil
        limit = width - CGFloat(indent)
        continue
      }
      x += w
      previous = kind
      index += 1
    }
    return result.starts.isEmpty ? nil : result
  }

  /// 段の頭から `x` の所のタブの幅——次のタブ位置（刻み `tab` の倍数で、`x` より右）まで。
  static func tabAdvance(at x: CGFloat, _ tab: CGFloat) -> CGFloat {
    tab > 0 ? (floor(x / tab + 1e-6) + 1) * tab - x : 0
  }

  /// ASCII の字とタブだけの行で、1 段に収まる。
  static func fitsASCII(_ units: some Collection<UInt16>, _ metrics: Metrics) -> Bool {
    var x: CGFloat = 0
    let tab = metrics.tabWidth
    for unit in units {
      if unit == 0x09 {
        x += tabAdvance(at: x, tab)
      } else if (0x20...0x7E).contains(unit) {
        x += metrics.ascii[Int(unit) - 0x20]
      } else {
        return false
      }
      if x > metrics.width { return false }
    }
    return true
  }

  /// 続きの段の字下げ——行頭の空白（空白とタブ）の幅。空白でない字が無い行と、折り返しの幅の半分を超える字下げは 0。
  private static func indentWidth(
    _ units: ContiguousArray<UInt16>, advance: (Int, CGFloat) -> CGFloat?, width: CGFloat
  ) -> Float {
    var x: CGFloat = 0
    for (index, unit) in units.enumerated() {
      guard unit == 0x20 || unit == 0x09 else {
        return x > width / 2 ? 0 : Float(x)
      }
      x += advance(index, x) ?? 0
    }
    return 0
  }

  /// `previous` の字の後ろ、`unit`（種類 `kind`）の字の前で分けてよいか（VS Code の `canBreak`。`wordBreak` は `normal`）。
  static func canBreak(after previous: Kind, before unit: UInt16, _ kind: Kind) -> Bool {
    guard unit != 0x20 else { return false }
    return (previous == .after && kind != .after) || (previous != .before && kind == .before)
      || (previous == .ideographic && kind != .after)
      || (kind == .ideographic && previous != .before)
  }

  /// 単位 `index` で始まる字の種類（字の最初の符号点で決める）。
  static func kind(_ units: ContiguousArray<UInt16>, at index: Int) -> Kind {
    let unit = units[index]
    if UTF16.isLeadSurrogate(unit), index + 1 < units.count,
      UTF16.isTrailSurrogate(units[index + 1])
    {
      let scalar = 0x10000 + (UInt32(unit) - 0xD800) << 10 + (UInt32(units[index + 1]) - 0xDC00)
      return (0x20000...0x3FFFF).contains(scalar) ? .ideographic : .none
    }
    return kind(of: unit)
  }

  /// BMP の字 `unit` の種類。
  static func kind(of unit: UInt16) -> Kind { kinds[Int(unit)] }

  /// BMP の字の種類の表。前後で分けてよい字の表を、和文の字の範囲より先に引く。
  private static let kinds: [Kind] = {
    var table = [Kind](repeating: .none, count: 0x10000)
    for range in [
      0x3000...0x303F, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
      0xF900...0xFAFF, 0xFF00...0xFFEF,
    ] {
      for unit in range { table[unit] = .ideographic }
    }
    for unit in breakBefore.utf16 { table[Int(unit)] = .before }
    for unit in breakAfter.utf16 { table[Int(unit)] = .after }
    return table
  }()

  /// その後ろで分けてよい字（VS Code 1.148 の `wordWrapBreakAfterCharacters` の既定）。
  static let breakAfter =
    " \t})]?|/&.,;¢°′″‰℃、。｡､￠，．：；？！％・･ゝゞヽヾーァィゥェォッャュョヮヵヶぁぃぅぇぉっゃゅょゎゕゖㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ々〻ｧｨｩｪｫｬｭｮｯｰ”〉》」』】〕）］｝｣"

  /// その前で分けてよい字（VS Code 1.148 の `wordWrapBreakBeforeCharacters` の既定）。
  static let breakBefore = "([{‘“〈《「『【〔（［｛｢£¥＄￡￥+＋"
}

extension LineWrap {
  /// 本文 `text` の連続する行 `rows` の折り返し（1 段に収まる行は nil）。行の頭を 1 度にまとめて読み、ASCII の字とタブだけで
  /// 1 段に収まる行は、描く単位の列を作らずに決める。`resuming` は、行 1 つを折り返し直すときの、前の折り返しの手がかり。
  static func wrap(
    rows: Range<Int>, in text: TextRope, _ metrics: Metrics, resuming: Resume? = nil
  ) -> [WrappedLine?] {
    precondition(resuming == nil || rows.count == 1, "前の折り返しを引き継ぐのは行 1 つ")
    let heads = text.lineHeads(rows, limit: LineShaper.headLimit + 1)
    var result: [WrappedLine?] = []
    result.reserveCapacity(rows.count)
    for index in 0..<rows.count {
      var head = heads.head(index)
      var complete = heads.isComplete(index)
      if complete {
        if head.last == 0x0A { head = head.dropLast() }
        if head.last == 0x0D { head = head.dropLast() }
        complete = head.count <= LineShaper.headLimit
        if complete, fitsASCII(head, metrics) {
          result.append(nil)
          continue
        }
      }
      let row = rows.lowerBound + index
      let source =
        complete
        ? LineShaper.Source(head: ContiguousArray(head), length: head.count)
        : LineShaper.source(
          start: heads.starts[index],
          next: row + 1 < text.lineCount ? heads.starts[index + 1] : nil, in: text)
      result.append(wrap(LineShaper.display(source), metrics, resuming: resuming))
    }
    return result
  }
}
