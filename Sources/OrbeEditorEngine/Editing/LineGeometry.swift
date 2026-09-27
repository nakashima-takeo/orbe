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
