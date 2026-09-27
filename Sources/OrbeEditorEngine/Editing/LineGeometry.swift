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
/// ない行は組み直さない。
final class LineStopsCache {
  struct Stops {
    let offsets: [Int]
    let xs: [CGFloat]
    let width: CGFloat
  }

  private struct Key: Hashable {
    let source: LineShaper.Source
    let tabWidth: CGFloat
  }

  static let capacity = 64
  private var entries: [Key: Stops] = [:]
  private let font: CTFont

  init(font: CTFont) {
    self.font = font
  }

  func stops(_ source: LineShaper.Source, tabWidth: CGFloat) -> Stops {
    let key = Key(source: source, tabWidth: tabWidth)
    if let stops = entries[key] { return stops }
    let shaped = LineShaper.shape(source, font: font, tabWidth: tabWidth)
    let (offsets, xs) = shaped.stops
    let stops = Stops(offsets: offsets, xs: xs, width: shaped.width)
    if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
    entries[key] = stops
    return stops
  }
}

/// 描画と同じ組版の規則（`LineShaper` と `CaretX`）で答える、本文の写しの行の横位置。
struct ShapedLineGeometry: LineGeometry {
  let text: TextRope
  let cache: LineStopsCache
  let tabWidth: CGFloat

  func x(ofColumn column: Int, row: Int) -> CGFloat {
    let stops = cache.stops(LineShaper.source(row: row, in: text).source, tabWidth: tabWidth)
    return CaretX.x(ofColumn: column, offsets: stops.offsets, xs: stops.xs, width: stops.width)
  }

  func column(atX x: CGFloat, row: Int) -> Int {
    let (source, start) = LineShaper.source(row: row, in: text)
    let stops = cache.stops(source, tabWidth: tabWidth)
    guard x > 0, let glyph = CaretX.glyph(atX: x, xs: stops.xs) else { return 0 }
    guard x < stops.width else { return source.length }
    let cluster = text.grapheme(containing: start + stops.offsets[glyph])
    let left = cluster.location - start
    let right = min(NSMaxRange(cluster) - start, source.length)
    let leftX = CaretX.x(ofColumn: left, offsets: stops.offsets, xs: stops.xs, width: stops.width)
    let rightX = CaretX.x(ofColumn: right, offsets: stops.offsets, xs: stops.xs, width: stops.width)
    return x - leftX <= rightX - x ? left : right
  }
}
