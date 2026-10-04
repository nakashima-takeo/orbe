import CoreText
import Foundation
import OrbeEditorCore

/// 行の横位置の問い合わせ（↑↓の覚えた位置・クリック・ドラッグ）。位置は行頭からの UTF-16 の距離、x は行頭からの pt。
protocol LineGeometry {
  /// 行 `row` の位置 `column` の x。
  func x(ofColumn column: Int, row: Int) -> CGFloat
  /// 行 `row` の中で x にいちばん近い書記素の境（行の中身の外なら端）。
  func column(atX x: CGFloat, row: Int) -> Int
}

/// 組んだ行の字の位置を覚える入れ物（main。面ごと）。鍵は行の中身とタブの刻みで、本文の版に依らない——打鍵の前後で変わら
/// ない行は組み直さない。main が問う行は少ない（キャレットの行・↑↓の先・ポインタの下）ので、少しだけ覚え、溢れたら最も
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
    let source: LineShaper.Source
    let tabWidth: CGFloat
  }

  static let capacity = 16
  private var entries: [Key: (stops: Stops, used: UInt64)] = [:]
  private var clock: UInt64 = 0
  private let font: CTFont

  init(font: CTFont) {
    self.font = font
  }

  func stops(_ source: LineShaper.Source, tabWidth: CGFloat) -> Stops {
    clock += 1
    let key = Key(source: source, tabWidth: tabWidth)
    if let index = entries.index(forKey: key) {
      entries.values[index].used = clock
      return entries.values[index].stops
    }
    let shaped = LineShaper.shape(source, font: font, tabWidth: tabWidth)
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

/// 描画と同じ組版の規則（`LineShaper` と `CaretMap`）で答える、本文の写しの行の横位置。
struct ShapedLineGeometry: LineGeometry {
  let text: TextRope
  let cache: LineStopsCache
  let tabWidth: CGFloat

  func x(ofColumn column: Int, row: Int) -> CGFloat {
    cache.stops(LineShaper.source(row: row, in: text).source, tabWidth: tabWidth).carets.x(column)
  }

  /// x にいちばん近い位置（`CTLineGetStringIndexForPosition`。右から左の字の並びでも見た目に合う）を、書記素の境へ寄せる
  /// （組版の字の単位と OS の書記素が違えば、x の近い方の端）。行の左より左は行頭、右より右は描かない部分を含めた行の終わり。
  func column(atX x: CGFloat, row: Int) -> Int {
    let (source, start) = LineShaper.source(row: row, in: text)
    let stops = cache.stops(source, tabWidth: tabWidth)
    let carets = stops.carets
    guard x >= 0 else { return 0 }
    guard x <= carets.width else { return source.length }
    let column = max(0, CTLineGetStringIndexForPosition(stops.line, CGPoint(x: x, y: 0)))
    let cluster = text.grapheme(containing: start + column)
    guard cluster.location < start + column else { return column }
    let left = cluster.location - start
    let right = min(NSMaxRange(cluster) - start, source.length)
    return abs(x - carets.x(left)) <= abs(carets.x(right) - x) ? left : right
  }
}

/// 変換中の未確定の文字の横位置（IME が問う文字の矩形と点の下の字）。未確定の先頭の x は変換の前の本文の行から出す——変換中は
/// 未確定より前の中身が変わらないので、中身を鍵に覚えた組版に当たり、行を組むのは変換ごとに 1 回。未確定の中は、その x に
/// 未確定の文字列だけを組んだ x を足す（打鍵ごとに組むのは未確定の長さだけ）。境目の字詰め・合字・右から左の字・タブの
/// 位置で描画とわずかにずれうるが、候補窓の位置には効かない。
struct MarkedLineGeometry {
  /// 未確定のうち、先頭の行にある部分（文書の座標）。
  let range: NSRange
  let row: Int
  private let anchor: CGFloat
  private let stops: LineStopsCache.Stops

  /// 未確定の先頭より前の中身が変換の前のままでなければ（IME が未確定の内側を指して先頭が後ろへずれた）nil。
  init?(_ composition: Composition, text: TextRope, cache: LineStopsCache, tabWidth: CGFloat) {
    let marked = composition.range
    guard marked.location <= composition.changes.edits.first?.range.location ?? marked.location
    else { return nil }
    row = text.row(containing: marked.location)
    let start = text.lineStart(row)
    let end = min(NSMaxRange(marked), NSMaxRange(text.contentRange(ofRow: row)))
    range = NSRange(location: marked.location, length: max(0, end - marked.location))
    anchor = ShapedLineGeometry(text: composition.textBefore, cache: cache, tabWidth: tabWidth)
      .x(ofColumn: marked.location - start, row: row)
    let units = text.units(in: range)
    stops = cache.stops(LineShaper.Source(head: units, length: units.count), tabWidth: tabWidth)
  }

  /// 未確定の中（両端を含む）の位置の x（行頭から）。外なら nil。
  func x(of offset: Int) -> CGFloat? {
    guard offset >= range.location, offset <= NSMaxRange(range) else { return nil }
    return anchor + stops.carets.x(offset - range.location)
  }

  /// x（行頭から）を含む未確定の字の位置。未確定の字の上でなければ nil。
  func offset(containingX x: CGFloat) -> Int? {
    guard x >= anchor, x - anchor < stops.width, let glyph = stops.glyph(atX: x - anchor)
    else { return nil }
    return range.location + stops.offsets[glyph]
  }
}
