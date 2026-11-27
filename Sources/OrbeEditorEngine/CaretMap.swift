import CoreText
import Foundation

/// 行の中の位置と x の対応。描画スレッド（キャレット・選択の地・横の「見えるところまで」）と main（↑↓の横位置）が同じ
/// 対応を使うので、キャレット・選択の地の端が描いた字と食い違わない（クリックの当たりは同じ組版の行から Core Text が引く）。組んだ行の双方向の対応
/// （`CTLineEnumerateCaretOffsets` の字ごとの前と後ろの縁）から作り、右から左の字の並びでも字の見た目の位置に合う。
struct CaretMap: Sendable {
  /// 見た目の順（左から右）の run——元の行の区間と、右から左か。
  struct Run: Sendable {
    let range: Range<Int>
    let rightToLeft: Bool
  }

  /// 位置 i（0...描く単位の数）のキャレットの x。主は i の前の字の後ろの縁（先頭は最初の字の前の縁）、副は i の字の前の
  /// 縁（末尾は最後の字の後ろの縁）——`CTLineGetOffsetForStringIndex` の主と副。書記素の内側の位置は、次の境の x。
  private let primary: [Float]
  private let secondary: [Float]
  let runs: [Run]
  let width: CGFloat

  init(_ line: CTLine, width: CGFloat) {
    let count = CTLineGetStringRange(line).length
    var leading = [Float](repeating: .nan, count: count)
    var trailing = [Float](repeating: .nan, count: count)
    CTLineEnumerateCaretOffsets(line) { offset, index, isLeading, _ in
      guard index >= 0, index < count else { return }
      if isLeading { leading[index] = Float(offset) } else { trailing[index] = Float(offset) }
    }
    var primary = [Float](repeating: .nan, count: count + 1)
    var secondary = [Float](repeating: .nan, count: count + 1)
    for i in 0...count {
      primary[i] = i == 0 ? (count > 0 ? leading[0] : 0) : trailing[i - 1]
      secondary[i] = i == count ? (count > 0 ? trailing[count - 1] : 0) : leading[i]
    }
    var next = Float(width)
    for i in stride(from: count, through: 0, by: -1) {
      if primary[i].isNaN { primary[i] = secondary[i].isNaN ? next : secondary[i] }
      if secondary[i].isNaN { secondary[i] = primary[i] }
      next = primary[i]
    }
    self.primary = primary
    self.secondary = secondary
    runs = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).map { run in
      let range = CTRunGetStringRange(run)
      return Run(
        range: range.location..<range.location + range.length,
        rightToLeft: CTRunGetStatus(run).contains(.rightToLeft))
    }
    self.width = width
  }

  /// 単純な行（`ShapedLine.simple`——等幅のフォントで、ASCII の字かタブが単位ごとに 1 つのグリフで左から並ぶ）の対応を、
  /// グリフの x から作る。字 i の前の縁は i のグリフの x、後ろの縁は次のグリフの x（最後の字は行の幅）で、Core Text の縁と
  /// 同じ。
  init(ascii xs: [CGFloat], width: CGFloat) {
    let edges = xs.map(Float.init) + [Float(width)]
    primary = edges
    secondary = edges
    runs = xs.isEmpty ? [] : [Run(range: 0..<xs.count, rightToLeft: false)]
    self.width = width
  }

  /// 描く単位の数（これより後ろの位置は、描いた部分の右端）。
  var count: Int { primary.count - 1 }

  /// 位置のキャレットの x（主）。
  func x(_ offset: Int) -> CGFloat {
    offset > count ? width : CGFloat(primary[max(0, offset)])
  }

  /// 元の行の区間 `from..<to` を塗る見た目の区間（左から右）。右から左の字を挟めば、論理の 1 区間が見た目では複数に分かれる。
  func segments(from: Int, to: Int) -> [ClosedRange<CGFloat>] {
    let from = max(0, from)
    let to = min(to, count)
    var result: [ClosedRange<CGFloat>] = []
    for run in runs {
      let lower = max(from, run.range.lowerBound)
      let upper = min(to, run.range.upperBound)
      guard lower < upper else { continue }
      let a = CGFloat(secondary[lower])
      let b = CGFloat(primary[upper])
      let segment = min(a, b)...max(a, b)
      if let last = result.last, segment.lowerBound <= last.upperBound {
        result[result.count - 1] = last.lowerBound...max(last.upperBound, segment.upperBound)
      } else {
        result.append(segment)
      }
    }
    return result
  }
}
