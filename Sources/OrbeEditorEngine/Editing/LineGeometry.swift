import CoreText
import Foundation
import OrbeEditorCore

/// 行の横位置の問い合わせ（↑↓の覚えた位置・クリック・ドラッグ）。位置は行頭からの UTF-16 の距離、x は行の左端（本文の
/// 区画の行頭。続きの段の字下げを含む）からの pt。折り返した行は段ごとに問う——折り返さない行は 1 段。
protocol LineGeometry {
  /// 行 `row` の位置 `column` の段と x。段の境の位置は、付き（`upstream`）なら上の段の終わり、そうでなければ下の段の頭。
  func place(ofColumn column: Int, row: Int, upstream: Bool) -> (segment: Int, x: CGFloat)
  /// 行 `row` の段 `segment` の中で x にいちばん近い書記素の境と、その付き（下に段が続く段の終わりなら true）。段の左より左は
  /// 段の頭、右より右は段の終わり（最後の段なら、描かない部分を含めた行の終わり）。
  func column(atX x: CGFloat, row: Int, segment: Int) -> (column: Int, upstream: Bool)
}

extension LineGeometry {
  /// 行 `row` の位置 `column` の x（付きなし）。
  func x(ofColumn column: Int, row: Int) -> CGFloat {
    place(ofColumn: column, row: row, upstream: false).x
  }
}

/// 組んだ行（段）の字の位置を覚える入れ物（main。面ごと）。鍵は描く単位の列とタブの刻みで、本文の版に依らない——打鍵の
/// 前後で変わらない行と段は組み直さない。main が問う行は少ない（キャレットの行・↑↓の先・ポインタの下）ので、少しだけ覚え、溢れたら最も
/// 古く使われた 1 つを捨てる（打鍵のたびに変わる長い行の古い結果を、1 つずつ手放す）。
final class LineStopsCache {
  struct Stops {
    /// 字の元の位置と x（左から右へ増えていく）。
    let offsets: [Int]
    let xs: [CGFloat]
    let width: CGFloat
    let carets: CaretMap
    let line: CTLine

    /// x 以下にある最後の字の番号（どの字より左なら nil）。
    func glyph(atX x: CGFloat) -> Int? {
      var low = 0
      var high = xs.count
      while low < high {
        let mid = (low + high) / 2
        if xs[mid] <= x { low = mid + 1 } else { high = mid }
      }
      return low > 0 ? low - 1 : nil
    }
  }

  private struct Key: Hashable {
    let shown: LineShaper.Displayed
    let tabWidth: CGFloat
  }

  static let capacity = 16
  private var entries: [Key: (stops: Stops, used: UInt64)] = [:]
  private var clock: UInt64 = 0
  private let font: CTFont

  init(font: CTFont) {
    self.font = font
  }

  /// 描く単位の列 `shown`（行か段の中身）を組んだ字の位置。
  func stops(_ shown: LineShaper.Displayed, tabWidth: CGFloat) -> Stops {
    clock += 1
    let key = Key(shown: shown, tabWidth: tabWidth)
    if let index = entries.index(forKey: key) {
      entries.values[index].used = clock
      return entries.values[index].stops
    }
    let shaped = LineShaper.shape(shown, font: font, tabWidth: tabWidth)
    let (offsets, xs) = shaped.stops
    let stops = Stops(
      offsets: offsets, xs: xs, width: shaped.width, carets: shaped.carets, line: shaped.line)
    if entries.count >= Self.capacity,
      let oldest = entries.min(by: { $0.value.used < $1.value.used })
    {
      entries.removeValue(forKey: oldest.key)
    }
    entries[key] = (stops, clock)
    return stops
  }
}

/// 行の段 1 つを組んだ字の位置（main）——段の始まり・次の段の始まり（最後の段なら nil）・字下げ（pt）と、段を組んだ字の
/// 位置（位置は段の頭から）と、行頭のオフセット・行の中身の長さ。
struct SegmentStops {
  let base: Int
  let end: Int?
  let indent: CGFloat
  let stops: LineStopsCache.Stops
  let lineStart: Int
  let length: Int
}

/// 描画と同じ組版の規則（`LineShaper` と `CaretMap`）と、縦の並びの行ごとの折り返しで答える、本文の写しの行の横位置。
/// 折り返した行は、描画と同じく段ごとに独立した行として組む。
struct ShapedLineGeometry: LineGeometry {
  let text: TextRope
  let cache: LineStopsCache
  let tabWidth: CGFloat
  /// 本文の写しと同じ時点の縦の並び（行ごとの折り返し）。
  let rows: RowLayout

  /// 行 `row` の段 `segment` を組んだ字の位置。
  func stops(_ segment: Int, row: Int) -> SegmentStops {
    let (source, start) = LineShaper.source(row: row, in: text)
    let shown = LineShaper.display(source)
    guard let wrap = rows.wrap(ofLine: row) else {
      let stops = cache.stops(shown, tabWidth: tabWidth)
      return SegmentStops(
        base: 0, end: nil, indent: 0, stops: stops, lineStart: start, length: source.length)
    }
    let segment = min(max(0, segment), wrap.segments - 1)
    let base = wrap.start(of: segment)
    let end = segment + 1 < wrap.segments ? wrap.start(of: segment + 1) : nil
    let stops = cache.stops(
      shown.segment(base..<(end ?? shown.units.count), last: end == nil), tabWidth: tabWidth)
    return SegmentStops(
      base: base, end: end, indent: segment > 0 ? CGFloat(wrap.indent) : 0, stops: stops,
      lineStart: start, length: source.length)
  }

  func place(ofColumn column: Int, row: Int, upstream: Bool) -> (segment: Int, x: CGFloat) {
    let segment = rows.segment(containing: column, line: row, upstream: upstream)
    let piece = stops(segment, row: row)
    return (segment, piece.indent + piece.stops.carets.x(column - piece.base))
  }

  /// x にいちばん近い位置（`CTLineGetStringIndexForPosition`。右から左の字の並びでも見た目に合う）を、書記素の境へ寄せる
  /// （組版の字の単位と OS の書記素が違えば、x の近い方の端）。
  func column(atX x: CGFloat, row: Int, segment: Int) -> (column: Int, upstream: Bool) {
    let piece = stops(segment, row: row)
    let start = piece.lineStart
    let end = piece.end ?? piece.length
    let carets = piece.stops.carets
    let x = x - piece.indent
    guard x >= 0 else { return (piece.base, false) }
    guard x <= carets.width else { return (end, piece.end != nil) }
    let local = max(0, CTLineGetStringIndexForPosition(piece.stops.line, CGPoint(x: x, y: 0)))
    let column = piece.base + local
    let cluster = text.grapheme(containing: start + column)
    guard cluster.location < start + column else { return (column, column == piece.end) }
    let left = max(cluster.location - start, piece.base)
    let right = min(NSMaxRange(cluster) - start, end)
    let nearer =
      abs(x - carets.x(left - piece.base)) <= abs(carets.x(right - piece.base) - x) ? left : right
    return (nearer, nearer == piece.end)
  }
}

/// 変換中の未確定の文字の横位置（IME が問う文字の矩形と点の下の字）。未確定の先頭の x は、今の折り返しで未確定の先頭を含む段の
/// 頭から未確定の先頭までを、今の本文から組んで出す（段の頭と同じ本文の描く単位で切る）——変換中は未確定より前の中身が変わら
/// ないので、中身を鍵に覚えた組版に当たり、組むのは段の頭が動いたときだけ。未確定の中は、その x に未確定の文字列だけを組んだ x を足す（打鍵ごとに組む
/// のは未確定の長さだけ）。境目の字詰め・合字・右から左の字・タブの位置・段の終わりで描画とわずかにずれうるが、候補窓の
/// 位置には効かない。
struct MarkedLineGeometry {
  /// 未確定のうち、先頭の行の、先頭の段にある部分（文書の座標）。
  let range: NSRange
  let row: Int
  /// 未確定の先頭を含む段。
  let segment: Int
  private let anchor: CGFloat
  private let stops: LineStopsCache.Stops

  /// 未確定の先頭より前の中身が変換の前のままでなければ（IME が未確定の内側を指して先頭が後ろへずれた）nil。`rows` は今の
  /// 本文の縦の並び。
  init?(
    _ composition: Composition, text: TextRope, rows: RowLayout, cache: LineStopsCache,
    tabWidth: CGFloat
  ) {
    let marked = composition.range
    guard marked.location <= composition.changes.edits.first?.range.location ?? marked.location
    else { return nil }
    row = text.row(containing: marked.location)
    let start = text.lineStart(row)
    let column = marked.location - start
    segment = rows.segment(containing: column, line: row)
    let wrap = rows.wrap(ofLine: row)
    let base = wrap?.start(of: segment) ?? 0
    var end = min(NSMaxRange(marked), NSMaxRange(text.contentRange(ofRow: row)))
    if let wrap, segment + 1 < wrap.segments { end = min(end, start + wrap.start(of: segment + 1)) }
    range = NSRange(location: marked.location, length: max(0, end - marked.location))
    let shown = LineShaper.display(LineShaper.source(row: row, in: text).source)
    let head = cache.stops(
      shown.segment(base..<min(column, shown.units.count), last: false), tabWidth: tabWidth)
    anchor = (segment > 0 ? CGFloat(wrap?.indent ?? 0) : 0) + head.width
    let units = text.units(in: range)
    stops = cache.stops(
      LineShaper.display(LineShaper.Source(head: units, length: units.count)), tabWidth: tabWidth)
  }

  /// 未確定の中（両端を含む）の位置の x（行の左端から）。外なら nil。
  func x(of offset: Int) -> CGFloat? {
    guard offset >= range.location, offset <= NSMaxRange(range) else { return nil }
    return anchor + stops.carets.x(offset - range.location)
  }

  /// x（行の左端から）を含む未確定の字の位置。未確定の字の上でなければ nil。
  func offset(containingX x: CGFloat) -> Int? {
    guard x >= anchor, x - anchor < stops.width, let glyph = stops.glyph(atX: x - anchor)
    else { return nil }
    return range.location + stops.offsets[glyph]
  }
}
