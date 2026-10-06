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

  /// 場の選択とキャレット `caret`・落とす位置 `drop` を、行頭 `start` の行から下へ引く。キャレットは場が主で、点滅で
  /// 見えているコマだけ。
  init(_ caret: CaretMaterial, drop: Int?, caretVisible: Bool, text: TextRope, from start: Int) {
    self.text = text
    selections = SelectionCursor(caret.selections, from: start)
    carets = caretVisible && caret.focused ? caret.carets : []
    caretNext = Self.firstIndex(in: carets) { $0 >= start }
    lastRow = text.lineCount - 1
    marked = caret.marked
    if let ranges = marked?.ranges {
      markedNext = Self.firstIndex(in: ranges) { NSMaxRange($0) >= start }
    }
    self.drop = drop.map { (row: text.row(containing: $0), offset: $0) }
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

/// 行に重ねるものを描く筆——場ごとの行頭の x と行の寸法、色。本文と入力欄が同じ描き方を使う。
struct OverlayPen {
  /// 行頭の x（px）。
  var originX: Double
  /// 行の高さと、行の上端から基線まで（px）。
  var lineHeight: Double
  var baseline: Double
  var scale: Double
  /// 改行を含む選択を行の右端から伸ばす幅（pt）。
  var cell: Double
  var caretSize: CGSize
  /// 場が主で、面に焦点がある（選択の地の色）。
  var focused: Bool
  var selection: FrameColor
  var inactiveSelection: FrameColor
  var caret: FrameColor
  /// IME が選んでいる文節の下線の色と、選んでいない文節の下線・属性の無い未確定の地。
  var activeClause: FrameColor
  var markedUnderline: FrameColor
  var markedBackground: FrameColor
}

/// 行に重ねるものの図形——地（選択・未確定の文字の地。字の下）と、上（未確定の文字の下線・キャレット・落とす位置の印）。
/// 本文と入力欄がそれぞれ持つ。
struct OverlayShapes {
  var under: [ShapeInstance] = []
  var over: [ShapeInstance] = []

  mutating func removeAll() {
    under.removeAll(keepingCapacity: true)
    over.removeAll(keepingCapacity: true)
  }
}

/// 選択の地とキャレット。どちらの x も、字を描いた行の組版の位置と x の対応（`CaretMap`）から引くので、描いた字と食い違わ
/// ない。
extension OverlayShapes {
  /// 行に重ねるものを積む。
  mutating func draw(
    _ overlay: RowOverlays, _ line: LaidOutLine, rowTop: Double, _ pen: OverlayPen
  ) {
    if let content = overlay.content {
      for selection in overlay.selections {
        drawSelection(selection, line, content: content, rowTop: rowTop, pen)
      }
      for range in overlay.marked {
        drawMarked((range, overlay.appearance), line, content: content, rowTop: rowTop, pen)
      }
    }
    for column in overlay.carets { drawCaret(at: column, line, rowTop: rowTop, pen) }
    if let column = overlay.drop { drawDropIndicator(at: column, line, rowTop: rowTop, pen) }
  }

  /// 選択と行の交わりを行の高さいっぱいの矩形で塗る。`content` は行の中身の区間（改行と行末の `\r` を除く）。右から左の
  /// 字を挟めば、論理の選択を見た目の区間ごとに分けて塗る。選択が行の改行を含めば、行の右端から半角 1 字ぶん伸ばす。
  mutating func drawSelection(
    _ selection: NSRange, _ line: LaidOutLine, content: NSRange, rowTop: Double, _ pen: OverlayPen
  ) {
    guard let carets = line.carets else { return }
    let from = selection.location - content.location
    let to = NSMaxRange(selection) - content.location
    var segments = carets.segments(from: from, to: min(to, content.length))
    if to > content.length { segments.append(line.width...(line.width + CGFloat(pen.cell))) }
    let bottom = rowTop + pen.lineHeight.rounded()
    let ink = pen.focused ? pen.selection : pen.inactiveSelection
    var painted: ClosedRange<Double>?
    for segment in segments.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      let left = (pen.originX + Double(segment.lowerBound) * pen.scale).rounded()
      let right = (pen.originX + Double(segment.upperBound) * pen.scale).rounded()
      if let last = painted, left <= last.upperBound {
        painted = last.lowerBound...max(last.upperBound, right)
        continue
      }
      if let last = painted { paint(last, rowTop: rowTop, bottom: bottom, ink) }
      painted = left...right
    }
    if let last = painted { paint(last, rowTop: rowTop, bottom: bottom, ink) }
  }

  private mutating func paint(
    _ x: ClosedRange<Double>, rowTop: Double, bottom: Double, _ ink: FrameColor
  ) {
    guard x.upperBound > x.lowerBound else { return }
    under.append(
      ShapeInstance(
        rect: SIMD4(
          Float(x.lowerBound), Float(rowTop), Float(x.upperBound - x.lowerBound),
          Float(bottom - rowTop)),
        color: ink.packed, radius: 0, kind: 0))
  }

  /// キャレット——見え方の幅と高さで、行の中で縦に中央へ置き、x は装置の画素に揃える。
  mutating func drawCaret(at column: Int, _ line: LaidOutLine, rowTop: Double, _ pen: OverlayPen) {
    guard let carets = line.carets else { return }
    let size = pen.caretSize
    let x = (pen.originX + Double(carets.x(column)) * pen.scale).rounded()
    let width = max(1, (Double(size.width) * pen.scale).rounded())
    let height = (Double(size.height) * pen.scale).rounded()
    let top = (rowTop + (pen.lineHeight - height) / 2).rounded()
    over.append(
      ShapeInstance(
        rect: SIMD4(Float(x), Float(top), Float(width), Float(height)),
        color: pen.caret.packed, radius: 0, kind: 0))
  }
}

/// 変換中の文字と落とす位置の印。どれも本文と同じ 1 コマに描く。
extension OverlayShapes {
  /// 変換中の文字を行に描く。文節ごとに角の丸い下線（IME が選んでいる文節は本文の色、他は灰色。太さは同じで、文節の境を
  /// 少し空ける）。属性の無い文字列は既定の未確定の地で塗る。IME が下線や地の色を指定したら従う。
  mutating func drawMarked(
    _ marked: (range: NSRange, appearance: MarkedAppearance), _ line: LaidOutLine,
    content: NSRange, rowTop: Double, _ pen: OverlayPen
  ) {
    let (range, appearance) = marked
    guard let carets = line.carets else { return }
    let scale = pen.scale
    let baseline = rowTop + pen.baseline
    let bottom = rowTop + pen.lineHeight.rounded()
    if appearance.filled {
      for (x0, x1) in Self.extents(range, carets, content, pen) {
        under.append(
          ShapeInstance(
            rect: SIMD4(Float(x0), Float(rowTop), Float(x1 - x0), Float(bottom - rowTop)),
            color: pen.markedBackground.packed, radius: 0, kind: 0))
      }
    }
    let thickness = max(1, (1.5 * scale).rounded())
    let inset = scale.rounded()
    let top = (baseline + 1.5 * scale).rounded()
    for clause in appearance.clauses {
      let ink =
        clause.underline ?? (clause.active ? pen.activeClause : pen.markedUnderline).packed
      let clauseRange = NSRange(
        location: range.location + clause.range.location, length: clause.range.length)
      for (x0, x1) in Self.extents(clauseRange, carets, content, pen) {
        if let background = clause.background {
          under.append(
            ShapeInstance(
              rect: SIMD4(Float(x0), Float(rowTop), Float(x1 - x0), Float(bottom - rowTop)),
              color: background, radius: 0, kind: 0))
        }
        let left = x0 + inset
        let right = max(left + thickness, x1 - inset)
        over.append(
          ShapeInstance(
            rect: SIMD4(Float(left), Float(top), Float(right - left), Float(thickness)),
            color: ink, radius: Float(thickness / 2), kind: 0))
      }
    }
  }

  /// 範囲と行の交わりの見た目の区間の左右の端（px。右から左の字を挟めば複数）。
  private static func extents(
    _ range: NSRange, _ carets: CaretMap, _ content: NSRange, _ pen: OverlayPen
  ) -> [(Double, Double)] {
    let from = max(range.location, content.location) - content.location
    let to = min(NSMaxRange(range), NSMaxRange(content)) - content.location
    guard to > from else { return [] }
    return carets.segments(from: from, to: to).map {
      (
        (pen.originX + Double($0.lowerBound) * pen.scale).rounded(),
        (pen.originX + Double($0.upperBound) * pen.scale).rounded()
      )
    }
  }

  /// 落とす位置の印——その位置に 2pt 幅の点線（VS Code の `dnd-target`）。色はキャレットの色。
  mutating func drawDropIndicator(
    at column: Int, _ line: LaidOutLine, rowTop: Double, _ pen: OverlayPen
  ) {
    guard let carets = line.carets else { return }
    let dot = max(1, (2 * pen.scale).rounded())
    let x = (pen.originX + Double(carets.x(column)) * pen.scale).rounded() - dot / 2
    var y = rowTop
    while y < rowTop + pen.lineHeight {
      over.append(
        ShapeInstance(
          rect: SIMD4(Float(x), Float(y), Float(dot), Float(min(dot, rowTop + pen.lineHeight - y))),
          color: pen.caret.packed, radius: 0, kind: 0))
      y += dot * 2
    }
  }
}
