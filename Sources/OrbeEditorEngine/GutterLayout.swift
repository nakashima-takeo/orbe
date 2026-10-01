import OrbeEditorCore

/// 行番号の列と git の印の配置。行番号は右寄せで、字の見た目の中央（ascent と descent の中点）を行の
/// 縦の中央に置く。git の印は行番号の右の印の列に、追加・変更は行の高さのバー（続く同じ印の行は 1 本に繋げる）、削除は
/// その境に右向きの三角。
extension FrameBuilder {
  func drawNumber(_ number: Int, rowTop: Double, font: UInt16, _ c: Context) {
    let g = c.g
    let config = c.config
    let trailing = Double(config.gutterTrailingInset + config.marks.gutterWidth) * g.scale
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
    let x0 = g.column - Double(config.marks.gutterWidth) * g.scale
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
      let top = g.rowTop(bar.rows.lowerBound)
      let bottom = g.rowTop(bar.rows.upperBound + 1)
      let ink = bar.kind == .added ? palette.added : palette.modified
      shapes.append(
        ShapeInstance(
          rect: SIMD4(Float(barX), Float(top), Float(barWidth), Float(bottom - top)),
          color: ink.packed, radius: Float(Double(config.marks.barRadius) * g.scale), kind: 0))
    }
    let size = Double(config.marks.triangleSize) * g.scale
    var deletion = Self.firstIndex(marks.deletions.count) {
      marks.deletions[$0].row >= rows.lowerBound - 1
    }
    while deletion < marks.deletions.count, marks.deletions[deletion].row <= rows.upperBound + 1 {
      let mark = marks.deletions[deletion]
      deletion += 1
      let y = Double(mark.row + (mark.atBottom ? 1 : 0)) * g.lineHeight
      let center = g.top + max(y.rounded(), size / 2) - g.scrollY
      shapes.append(
        ShapeInstance(
          rect: SIMD4(Float(barX), Float(center - size / 2), Float(size), Float(size)),
          color: palette.removed.packed, radius: 0, kind: 1))
    }
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
