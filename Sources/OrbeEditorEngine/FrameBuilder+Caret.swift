import Foundation

/// 昇順の選択の列を、下へ進む行ごとに引く。
struct SelectionCursor {
  private let selections: [NSRange]
  private var index: Int

  init(_ selections: [NSRange], from offset: Int) {
    self.selections = selections
    var low = 0
    var high = selections.count
    while low < high {
      let mid = (low + high) / 2
      if NSMaxRange(selections[mid]) <= offset { low = mid + 1 } else { high = mid }
    }
    index = low
  }

  /// まだ描いていない選択があるか。
  var remaining: Bool { index < selections.count }

  /// 行 `line`（行頭から次の行頭まで。最終行なら本文の終わりまで）に掛かる選択。
  mutating func next(in line: Range<Int>) -> ArraySlice<NSRange> {
    while index < selections.count, NSMaxRange(selections[index]) <= line.lowerBound { index += 1 }
    var end = index
    while end < selections.count,
      selections[end].location < max(line.upperBound, line.lowerBound + 1)
    {
      end += 1
    }
    return selections[index..<end]
  }
}

/// 選択の地とキャレット。どちらの x も、字を描いた行の組版の位置と x の対応（`CaretMap`）から引くので、描いた字と食い違わ
/// ない。
extension FrameBuilder {
  /// 選択と行の交わりを行の高さいっぱいの矩形で塗る。`content` は行の中身の区間（改行と行末の `\r` を除く）。右から左の
  /// 字を挟めば、論理の選択を見た目の区間ごとに分けて塗る。選択が行の改行を含めば、行の右端から半角 1 字ぶん伸ばす。
  func drawSelection(
    _ selection: NSRange, _ line: LaidOutLine, content: NSRange, rowTop: Double, _ c: Context
  ) {
    guard let carets = line.carets else { return }
    let g = c.g
    let from = selection.location - content.location
    let to = NSMaxRange(selection) - content.location
    var segments = carets.segments(from: from, to: min(to, content.length))
    if to > content.length { segments.append(line.width...(line.width + c.config.cell)) }
    let originX = g.column - g.scrollX
    let bottom = rowTop + g.lineHeight.rounded()
    let ink = c.focused ? c.palette.selection : c.palette.inactiveSelection
    var painted: ClosedRange<Double>?
    for segment in segments.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      let left = (originX + Double(segment.lowerBound) * g.scale).rounded()
      let right = (originX + Double(segment.upperBound) * g.scale).rounded()
      if let last = painted, left <= last.upperBound {
        painted = last.lowerBound...max(last.upperBound, right)
        continue
      }
      if let last = painted { paintSelection(last, rowTop: rowTop, bottom: bottom, ink) }
      painted = left...right
    }
    if let last = painted { paintSelection(last, rowTop: rowTop, bottom: bottom, ink) }
  }

  private func paintSelection(
    _ x: ClosedRange<Double>, rowTop: Double, bottom: Double, _ ink: FrameColor
  ) {
    guard x.upperBound > x.lowerBound else { return }
    underShapes.append(
      ShapeInstance(
        rect: SIMD4(
          Float(x.lowerBound), Float(rowTop), Float(x.upperBound - x.lowerBound),
          Float(bottom - rowTop)),
        color: ink.packed, radius: 0, kind: 0))
  }

  /// キャレット——見え方の幅と高さで、行の中で縦に中央へ置き、x は装置の画素に揃える。
  func drawCaret(at column: Int, _ line: LaidOutLine, rowTop: Double, _ c: Context) {
    guard let carets = line.carets else { return }
    let g = c.g
    let size = c.config.caretSize
    let x = (g.column - g.scrollX + Double(carets.x(column)) * g.scale).rounded()
    let width = max(1, (Double(size.width) * g.scale).rounded())
    let height = (Double(size.height) * g.scale).rounded()
    let top = (rowTop + (g.lineHeight - height) / 2).rounded()
    overShapes.append(
      ShapeInstance(
        rect: SIMD4(Float(x), Float(top), Float(width), Float(height)),
        color: c.palette.caret.packed, radius: 0, kind: 0))
  }
}
