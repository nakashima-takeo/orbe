import Foundation

/// 行の区間——行頭・行の中身の長さ（改行と行末の `\r` を除く）・次の行頭（最終行なら本文の終わり）。
struct LineSpan {
  let start: Int
  let length: Int
  let end: Int
}

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

  /// 行に掛かる選択（行の終わりの改行まで含む）。
  mutating func next(in line: LineSpan) -> ArraySlice<NSRange> {
    while index < selections.count, NSMaxRange(selections[index]) <= line.start { index += 1 }
    var end = index
    while end < selections.count, selections[end].location < max(line.end, line.start + 1) {
      end += 1
    }
    return selections[index..<end]
  }
}

/// 選択の地とキャレット。どちらの x も、字を描いた行の組版から引く（`CaretX`）ので、描いた字と食い違わない。
extension FrameBuilder {
  /// 選択と行の交わりを行の高さいっぱいの矩形で塗る。選択が行の改行を含めば、行末から半角 1 字ぶん伸ばす。
  func drawSelection(
    _ selection: NSRange, _ line: LaidOutLine, _ span: LineSpan, rowTop: Double, _ c: Context
  ) {
    let g = c.g
    let from = max(0, selection.location - span.start)
    let x0 = from == 0 ? 0 : line.x(ofColumn: from)
    let x1 =
      NSMaxRange(selection) > span.start + span.length
      ? line.x(ofColumn: span.length) + c.config.cell
      : line.x(ofColumn: NSMaxRange(selection) - span.start)
    guard x1 > x0 else { return }
    let originX = g.column - g.scrollX
    let left = (originX + Double(x0) * g.scale).rounded()
    let right = (originX + Double(x1) * g.scale).rounded()
    let bottom = rowTop + g.lineHeight.rounded()
    let ink = c.focused ? c.palette.selection : c.palette.inactiveSelection
    underShapes.append(
      ShapeInstance(
        rect: SIMD4(Float(left), Float(rowTop), Float(right - left), Float(bottom - rowTop)),
        color: ink.packed, radius: 0, kind: 0))
  }

  /// キャレット——見え方の幅と高さで、行の中で縦に中央へ置き、x は装置の画素に揃える。
  func drawCaret(at column: Int, _ line: LaidOutLine, rowTop: Double, _ c: Context) {
    let g = c.g
    let size = c.config.caretSize
    let x = (g.column - g.scrollX + Double(line.x(ofColumn: column)) * g.scale).rounded()
    let width = max(1, (Double(size.width) * g.scale).rounded())
    let height = (Double(size.height) * g.scale).rounded()
    let top = (rowTop + (g.lineHeight - height) / 2).rounded()
    overShapes.append(
      ShapeInstance(
        rect: SIMD4(Float(x), Float(top), Float(width), Float(height)),
        color: c.palette.caret.packed, radius: 0, kind: 0))
  }
}

extension LaidOutLine {
  /// 行の中の位置の x（pt）。
  func x(ofColumn column: Int) -> CGFloat {
    CaretX.x(ofColumn: column, offsets: offsets, xs: xs, width: width)
  }
}
