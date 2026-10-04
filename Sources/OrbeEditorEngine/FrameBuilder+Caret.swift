import Foundation
import OrbeEditorCore

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

/// 1 コマで行に重ねるもの——選択の地・変換中の文字・キャレット・落とす位置の印。上の行から下へ、行ごとに引く。
struct CaretOverlays {
  private let text: TextRope
  private var selections: SelectionCursor
  /// 点滅で見えているコマのキャレット（昇順）と、まだ描いていない最初のキャレット。
  private let carets: [Int]
  private var caretNext = 0
  private let lastRow: Int
  private let marked: MarkedMaterial?
  /// まだ下の行に掛かりうる最初の未確定の範囲。
  private var markedNext = 0
  private let drop: (row: Int, offset: Int)?

  /// 行頭 `start` の行から下へ引く。キャレットは点滅で見えているコマだけ。
  init(_ material: FrameMaterial, caretVisible: Bool, text: TextRope, from start: Int) {
    self.text = text
    selections = SelectionCursor(material.caret.selections, from: start)
    carets = caretVisible ? material.caret.carets : []
    caretNext = Self.firstIndex(in: carets) { $0 >= start }
    lastRow = text.lineCount - 1
    marked = material.caret.marked
    if let ranges = marked?.ranges {
      markedNext = Self.firstIndex(in: ranges) { NSMaxRange($0) >= start }
    }
    drop = material.drop.map { (row: text.row(containing: $0), offset: $0) }
  }

  /// 行 `row`（行頭から次の行頭までの区間 `line`。最終行なら本文の終わりまで）に重ねるもの。
  mutating func next(row: Int, line: Range<Int>) -> RowOverlays {
    let selected = selections.remaining ? Array(selections.next(in: line)) : []
    let marked = markedRanges(onRow: row)
    return RowOverlays(
      content: selected.isEmpty && marked.isEmpty ? nil : text.contentRange(ofRow: row),
      selections: selected,
      carets: carets(onRow: row, line: line),
      marked: marked, appearance: self.marked?.appearance ?? MarkedAppearance(),
      drop: drop?.row == row ? drop.map { $0.offset - line.lowerBound } : nil)
  }

  /// 昇順の列で `isAfter` が初めて真になる位置（無ければ件数）。
  private static func firstIndex<T>(in items: [T], _ isAfter: (T) -> Bool) -> Int {
    var low = 0
    var high = items.count
    while low < high {
      let mid = (low + high) / 2
      if isAfter(items[mid]) { high = mid } else { low = mid + 1 }
    }
    return low
  }

  /// 行 `row`（区間 `line`）のキャレットの行の中の位置（行は下へ進む）。最終行は本文の終わりを含む。
  private mutating func carets(onRow row: Int, line: Range<Int>) -> [Int] {
    var result: [Int] = []
    while caretNext < carets.count, carets[caretNext] < line.lowerBound { caretNext += 1 }
    while caretNext < carets.count,
      carets[caretNext] < line.upperBound
        || (row == lastRow && carets[caretNext] == line.upperBound)
    {
      result.append(carets[caretNext] - line.lowerBound)
      caretNext += 1
    }
    return result
  }

  /// 行 `row` に掛かる未確定の範囲（行は下へ進む）。
  private mutating func markedRanges(onRow row: Int) -> [NSRange] {
    guard let ranges = marked?.ranges else { return [] }
    var result: [NSRange] = []
    var index = markedNext
    while index < ranges.count {
      let rows = text.rows(of: ranges[index])
      if rows.upperBound < row {
        index += 1
        markedNext = index
        continue
      }
      if rows.lowerBound > row { break }
      result.append(ranges[index])
      index += 1
    }
    return result
  }
}

/// 1 行に重ねるもの。キャレットと落とす位置は行の中の位置。
struct RowOverlays {
  /// 行の中身の区間（改行と行末の `\r` を除く）。選択か変換中の文字が掛かる行だけ。
  let content: NSRange?
  let selections: [NSRange]
  let carets: [Int]
  /// 行に掛かる未確定の範囲と、その見た目（文節の範囲は未確定の先頭から）。
  let marked: [NSRange]
  let appearance: MarkedAppearance
  let drop: Int?

  /// 位置と x の対応（組版の `CaretMap`）が要るか。
  var needsCarets: Bool {
    !selections.isEmpty || !carets.isEmpty || !marked.isEmpty || drop != nil
  }
}

/// 選択の地とキャレット。どちらの x も、字を描いた行の組版の位置と x の対応（`CaretMap`）から引くので、描いた字と食い違わ
/// ない。
extension FrameBuilder {
  /// 行に重ねるものを描く（地は字の下、下線・キャレット・印は字の上の層へ積む）。
  func drawOverlays(_ overlay: RowOverlays, _ line: LaidOutLine, rowTop: Double, _ c: Context) {
    if let content = overlay.content {
      for selection in overlay.selections {
        drawSelection(selection, line, content: content, rowTop: rowTop, c)
      }
      for range in overlay.marked {
        drawMarked((range, overlay.appearance), line, content: content, rowTop: rowTop, c)
      }
    }
    for column in overlay.carets { drawCaret(at: column, line, rowTop: rowTop, c) }
    if let column = overlay.drop { drawDropIndicator(at: column, line, rowTop: rowTop, c) }
  }

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

/// 変換中の文字と落とす位置の印。どれも本文と同じ 1 コマに描く。
extension FrameBuilder {
  /// 変換中の文字を行に描く。文節ごとに角の丸い下線（IME が選んでいる文節は本文の色、他は灰色。太さは同じで、文節の境を
  /// 少し空ける）。属性の無い文字列は既定の未確定の地で塗る。IME が下線や地の色を指定したら従う。
  func drawMarked(
    _ marked: (range: NSRange, appearance: MarkedAppearance), _ line: LaidOutLine,
    content: NSRange, rowTop: Double, _ c: Context
  ) {
    let (range, appearance) = marked
    guard let carets = line.carets else { return }
    let g = c.g
    let baseline = rowTop + (Double(c.config.baseline) * g.scale).rounded()
    let bottom = rowTop + g.lineHeight.rounded()
    if appearance.filled {
      for (x0, x1) in extents(range, carets, content, c) {
        underShapes.append(
          ShapeInstance(
            rect: SIMD4(Float(x0), Float(rowTop), Float(x1 - x0), Float(bottom - rowTop)),
            color: c.palette.markedBackground.packed, radius: 0, kind: 0))
      }
    }
    let thickness = max(1, (1.5 * g.scale).rounded())
    let inset = g.scale.rounded()
    let top = (baseline + 1.5 * g.scale).rounded()
    for clause in appearance.clauses {
      let ink =
        clause.underline
        ?? (clause.active ? c.palette.text.color : c.palette.markedUnderline).packed
      let clauseRange = NSRange(
        location: range.location + clause.range.location, length: clause.range.length)
      for (x0, x1) in extents(clauseRange, carets, content, c) {
        if let background = clause.background {
          underShapes.append(
            ShapeInstance(
              rect: SIMD4(Float(x0), Float(rowTop), Float(x1 - x0), Float(bottom - rowTop)),
              color: background, radius: 0, kind: 0))
        }
        let left = x0 + inset
        let right = max(left + thickness, x1 - inset)
        overShapes.append(
          ShapeInstance(
            rect: SIMD4(Float(left), Float(top), Float(right - left), Float(thickness)),
            color: ink, radius: Float(thickness / 2), kind: 0))
      }
    }
  }

  /// 範囲と行の交わりの見た目の区間の左右の端（px。右から左の字を挟めば複数）。
  private func extents(_ range: NSRange, _ carets: CaretMap, _ content: NSRange, _ c: Context)
    -> [(Double, Double)]
  {
    let from = max(range.location, content.location) - content.location
    let to = min(NSMaxRange(range), NSMaxRange(content)) - content.location
    guard to > from else { return [] }
    let originX = c.g.column - c.g.scrollX
    return carets.segments(from: from, to: to).map {
      (
        (originX + Double($0.lowerBound) * c.g.scale).rounded(),
        (originX + Double($0.upperBound) * c.g.scale).rounded()
      )
    }
  }

  /// 落とす位置の印——その位置に 2pt 幅の点線（VS Code の `dnd-target`）。色はキャレットの色。
  func drawDropIndicator(at column: Int, _ line: LaidOutLine, rowTop: Double, _ c: Context) {
    guard let carets = line.carets else { return }
    let g = c.g
    let dot = max(1, (2 * g.scale).rounded())
    let x = (g.column - g.scrollX + Double(carets.x(column)) * g.scale).rounded() - dot / 2
    var y = rowTop
    while y < rowTop + g.lineHeight {
      overShapes.append(
        ShapeInstance(
          rect: SIMD4(Float(x), Float(y), Float(dot), Float(min(dot, rowTop + g.lineHeight - y))),
          color: c.palette.caret.packed, radius: 0, kind: 0))
      y += dot * 2
    }
  }
}
