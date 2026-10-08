import CoreGraphics
import OrbeEditorCore

/// 行番号の列と git の印の配置。番号は列ごとに右寄せで、字の見た目の中央（ascent と descent の中点）を行の縦の中央に
/// 置く（文書の行の番号は文書の行ごと、2 列の面の左の列は区間のもう一方の番号と差し込んだ行の番号）。git の印は番号の列の
/// 右の印の列に、追加・変更は行の高さのバー（続く同じ印の
/// 行は 1 本に繋げ、差し込みの塊で区切る）、削除はその境（文書の行の上端か、本文の末尾の行の下端）に右向きの三角。
extension FrameBuilder {
  /// 番号 `number` を、右端が行番号の列の右端から `inset`（pt）の所に来るよう置く。
  func drawNumber(_ number: Int, rowTop: Double, inset: CGFloat, font: UInt16, _ c: Context) {
    let g = c.g
    let config = c.config
    let trailing = Double(inset) * g.scale
    let width = Double(config.numberWidth(number).rounded(.up)) * g.scale
    let center = rowTop + g.lineHeight / 2
    let baseline = center + Double(config.gutterAscent - config.gutterDescent) / 2 * g.scale
    var digits: [Int] = []
    var n = number
    repeat {
      digits.append(n % 10)
      n /= 10
    } while n > 0
    var x = g.column - trailing - width
    for digit in digits.reversed() {
      place(
        Glyph(font: font, glyph: config.digitGlyphs[digit], x: x, baseline: baseline),
        c.palette.gutterText, .gutter, c)
      x += Double(config.digitAdvances[digit]) * g.scale
    }
  }

  func drawMarks(_ marks: RowMarks, rows: ClosedRange<Int>, _ c: Context) {
    let g = c.g
    let config = c.config
    let palette = c.palette
    let x0 = g.column - Double(c.gutter.numbersInset) * g.scale
    let barX = (x0 + Double(config.marks.barInset) * g.scale).rounded()
    let barWidth = (Double(config.marks.barWidth) * g.scale).rounded()
    var index = Self.firstIndex(marks.bars.count) {
      marks.bars[$0].rows.upperBound >= rows.lowerBound
    }
    while index < marks.bars.count, marks.bars[index].rows.lowerBound <= rows.upperBound {
      var bar = marks.bars[index]
      index += 1
      while index < marks.bars.count, marks.bars[index].kind == bar.kind,
        marks.bars[index].rows.lowerBound == bar.rows.upperBound + 1
      {
        bar.rows = bar.rows.lowerBound...marks.bars[index].rows.upperBound
        index += 1
      }
      let ink = bar.kind == .added ? palette.added : palette.modified
      for piece in Self.pieces(bar.rows, g.rows) {
        let top = g.rowTop(piece.lowerBound)
        let bottom = g.rowBottom(piece.upperBound)
        shapes.append(
          ShapeInstance(
            rect: SIMD4(Float(barX), Float(top), Float(barWidth), Float(bottom - top)),
            color: ink.packed, radius: Float(Double(config.marks.barRadius) * g.scale), kind: 0))
      }
    }
    let size = Double(config.marks.triangleSize) * g.scale
    var deletion = Self.firstIndex(marks.deletions.count) {
      marks.deletions[$0].row >= rows.lowerBound - 1
    }
    while deletion < marks.deletions.count, marks.deletions[deletion].row <= rows.upperBound + 1 {
      let mark = marks.deletions[deletion]
      deletion += 1
      let y =
        mark.atBottom
        ? g.rows.y(ofLine: mark.row, scale: g.scale) + g.lineHeight
        : g.rows.y(ofLine: mark.row, scale: g.scale)
      let center = g.top + max(y.rounded(), size / 2) - g.scrollY
      shapes.append(
        ShapeInstance(
          rect: SIMD4(Float(barX), Float(center - size / 2), Float(size), Float(size)),
          color: palette.removed.packed, radius: 0, kind: 1))
    }
  }

  /// 行の区間 `rows` を、間にある差し込みの塊の境で区切った区間の列。
  private static func pieces(_ rows: ClosedRange<Int>, _ layout: RowLayout) -> [ClosedRange<Int>] {
    var result: [ClosedRange<Int>] = []
    var start = rows.lowerBound
    var index = layout.blocks(above: start)
    while index < layout.count, layout.boundaries[index] <= rows.upperBound {
      let boundary = layout.boundaries[index]
      result.append(start...(boundary - 1))
      start = boundary
      index = layout.blocks(above: boundary)
    }
    result.append(start...rows.upperBound)
    return result
  }

  /// `0..<count` の中で `isAtOrAfter` が成り立つ最初の位置（成り立つ位置は後ろに続く）。
  private static func firstIndex(_ count: Int, _ isAtOrAfter: (Int) -> Bool) -> Int {
    var low = 0
    var high = count
    while low < high {
      let mid = (low + high) / 2
      if isAtOrAfter(mid) { high = mid } else { low = mid + 1 }
    }
    return low
  }
}
