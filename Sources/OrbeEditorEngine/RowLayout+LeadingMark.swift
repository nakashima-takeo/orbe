import Foundation
import OrbeEditorCore

/// 行の頭の印を出せる行（→ `SurfacePresentation.leadingMark`）。y から印を出せる行と組を引く所・行の上端と下端・引いて
/// 作る範囲の端を辿る所は、どれもここにある。印の行は、文書の行も差し込んだ行も、行そのもの（段ではない）で数える。
extension RowLayout {
  /// y にある、印を出せる行（`lineCount` 行の文書。出せない行・塊の絵の差し込みと空きの上なら nil）。
  func markSpot(atY y: Double, lineCount: Int) -> LeadingMarkSpot? {
    guard hasLeadingMarks else { return nil }
    switch item(atY: y) {
    case .line(let line, _):
      guard (0..<lineCount).contains(line) else { return nil }
      return spot(of: .document(line), lineCount: lineCount)
    case .block(let index):
      guard case .lines(let lines) = contents[index], !lines.isEmpty else { return nil }
      let offset = min(
        max(0, Int(((y - top(ofBlock: index)) / lineHeight).rounded(.down))), lines.count - 1)
      return spot(of: .inserted(block: index, line: offset), lineCount: lineCount)
    }
  }

  /// 行 `row` の、印を出せる行としての値（印の組が無ければ nil）。
  func spot(of row: LeadingMarkRow, lineCount: Int) -> LeadingMarkSpot? {
    switch row {
    case .document(let line):
      guard (0..<lineCount).contains(line), let group = lineSpan(ofLine: line)?.markGroup else {
        return nil
      }
      return LeadingMarkSpot(row: row, line: .document(line), group: group)
    case .inserted(let block, let offset):
      guard block < contents.count, case .lines(let lines) = contents[block],
        lines.indices.contains(offset), let group = lines[offset].markGroup,
        let source = lines[offset].line
      else { return nil }
      return LeadingMarkSpot(row: row, line: .source(source), group: group)
    }
  }

  /// 行 `row` の上端と下端（`scale` を掛けた単位。文書の行は最後の段の下端まで、差し込んだ行は行 1 つ分）。
  func extent(of row: LeadingMarkRow, scale: Double = 1) -> (top: Double, bottom: Double) {
    switch row {
    case .document(let line):
      return (
        y(ofLine: line, scale: scale),
        y(ofSegment: segments(ofLine: line), line: line, scale: scale)
      )
    case .inserted(let block, let offset):
      let top = top(ofBlock: block, scale: scale) + Double(offset) * lineHeight * scale
      return (top, top + lineHeight * scale)
    }
  }

  /// 行 `a` が、並びの順で行 `b` より前か。
  func precedes(_ a: LeadingMarkRow, _ b: LeadingMarkRow) -> Bool { order(a) < order(b) }

  /// 行 `row` が、並びの順で `first` から `last` まで（両端を含む）の中か。
  func contains(_ row: LeadingMarkRow, from first: LeadingMarkRow, to last: LeadingMarkRow) -> Bool
  {
    let key = order(row)
    return order(first) <= key && key <= order(last)
  }

  /// 印を出せる行 `anchor` から、y にある所（`lineCount` 行の文書）へ向けて並びの順に辿り、`anchor` と同じ組の行のうち最後に
  /// 着いた行。組を持たない行と塊の絵の差し込み・空きは飛び越し、別の組の行の手前で止まる。y が組の外・絵の差し込み・
  /// 詰め物の上なら、そこより `anchor` の側の、同じ組の最後の行。
  func reach(from anchor: LeadingMarkSpot, towardY y: Double, lineCount: Int) -> LeadingMarkRow {
    let target = order(atY: y, lineCount: lineCount)
    let start = order(anchor.row)
    guard target != start else { return anchor.row }
    let down = start < target
    var piece = Piece(anchor.row)
    var last = anchor.row
    while let next = step(piece, down: down, lineCount: lineCount) {
      if down ? order(next.first) > target : order(next.last) < target { break }
      piece = next
      guard let group = group(of: next) else { continue }
      guard group == anchor.group else { break }
      last = down ? next.lastRow(upTo: target) : next.firstRow(downTo: target)
    }
    return last
  }

  // MARK: - 並びの順

  /// 並びの順の位置——文書の行は (行, 1)、塊 `block` の `row` 行目は (塊の境, 0, 塊, 行)。塊の境の行の前に、塊の列の順に
  /// 並ぶ。
  struct MarkOrder: Comparable {
    let line: Int
    let kind: Int
    let block: Int
    let row: Int

    static func < (a: MarkOrder, b: MarkOrder) -> Bool {
      (a.line, a.kind, a.block, a.row) < (b.line, b.kind, b.block, b.row)
    }
  }

  private func order(_ row: LeadingMarkRow) -> MarkOrder {
    switch row {
    case .document(let line): MarkOrder(line: line, kind: 1, block: 0, row: 0)
    case .inserted(let block, let offset):
      MarkOrder(line: boundaries[block], kind: 0, block: block, row: offset)
    }
  }

  /// y にある所の並びの順の位置（文書の行は 0..<`lineCount` に収め、塊の中なら塊の行に収める）。
  private func order(atY y: Double, lineCount: Int) -> MarkOrder {
    switch item(atY: y) {
    case .line(let line, _):
      return order(.document(min(max(0, line), max(0, lineCount - 1))))
    case .block(let index):
      var offset = 0
      if case .lines(let lines) = contents[index], !lines.isEmpty {
        offset = min(
          max(0, Int(((y - top(ofBlock: index)) / lineHeight).rounded(.down))), lines.count - 1)
      }
      return MarkOrder(line: boundaries[index], kind: 0, block: index, row: offset)
    }
  }

  /// 並びの順で隣り合う、組の同じ行のまとまり——文書の行の区間（どの行も同じ区間の中で、間に塊が無い）か、差し込んだ行
  /// 1 つか、行を持たない塊（絵の差し込みか空き）。
  private enum Piece {
    case lines(ClosedRange<Int>)
    case inserted(block: Int, line: Int)
    case block(Int)

    init(_ row: LeadingMarkRow) {
      switch row {
      case .document(let line): self = .lines(line...line)
      case .inserted(let block, let line): self = .inserted(block: block, line: line)
      }
    }

    var first: LeadingMarkRow {
      switch self {
      case .lines(let range): .document(range.lowerBound)
      case .inserted(let block, let line): .inserted(block: block, line: line)
      case .block(let block): .inserted(block: block, line: 0)
      }
    }

    var last: LeadingMarkRow {
      switch self {
      case .lines(let range): .document(range.upperBound)
      case .inserted(let block, let line): .inserted(block: block, line: line)
      case .block(let block): .inserted(block: block, line: 0)
      }
    }

    /// 並びの順の位置 `target` 以前の、まとまりの最後の行（文書の行の区間なら `target` までで切る）。
    func lastRow(upTo target: MarkOrder) -> LeadingMarkRow {
      guard case .lines(let range) = self else { return last }
      let end = target.kind == 1 ? target.line : target.line - 1
      return .document(min(range.upperBound, max(range.lowerBound, end)))
    }

    /// 並びの順の位置 `target` 以後の、まとまりの最初の行。
    func firstRow(downTo target: MarkOrder) -> LeadingMarkRow {
      guard case .lines(let range) = self else { return first }
      return .document(max(range.lowerBound, min(range.upperBound, target.line)))
    }
  }

  private func group(of piece: Piece) -> Int? {
    switch piece {
    case .lines(let range): lineSpan(ofLine: range.lowerBound)?.markGroup
    case .inserted(let block, let line):
      if case .lines(let lines) = contents[block], lines[line].line != nil {
        lines[line].markGroup
      } else {
        nil
      }
    case .block: nil
    }
  }

  /// まとまり `piece` の、並びの順で次（`down`）か前のまとまり（無ければ nil）。
  private func step(_ piece: Piece, down: Bool, lineCount: Int) -> Piece? {
    switch (piece, down) {
    case (.lines(let range), true):
      let index = blocks(above: range.upperBound)
      if index < count, boundaries[index] == range.upperBound + 1 { return head(ofBlock: index) }
      return range.upperBound + 1 < lineCount
        ? lines(from: range.upperBound + 1, down: true, lineCount) : nil
    case (.lines(let range), false):
      let index = blocks(above: range.lowerBound) - 1
      if index >= 0, boundaries[index] == range.lowerBound { return tail(ofBlock: index) }
      return range.lowerBound > 0 ? lines(from: range.lowerBound - 1, down: false, lineCount) : nil
    case (.inserted(let block, let line), true):
      if case .lines(let run) = contents[block], line + 1 < run.count {
        return .inserted(block: block, line: line + 1)
      }
      return after(block: block, lineCount)
    case (.inserted(let block, let line), false):
      if line > 0 { return .inserted(block: block, line: line - 1) }
      return before(block: block, lineCount)
    case (.block(let block), true): return after(block: block, lineCount)
    case (.block(let block), false): return before(block: block, lineCount)
    }
  }

  /// 塊 `block` の次のまとまり（同じ境の次の塊か、境の文書の行）。
  private func after(block: Int, _ lineCount: Int) -> Piece? {
    if block + 1 < count, boundaries[block + 1] == boundaries[block] {
      return head(ofBlock: block + 1)
    }
    let line = boundaries[block]
    return line < lineCount ? lines(from: line, down: true, lineCount) : nil
  }

  /// 塊 `block` の前のまとまり（同じ境の前の塊か、境の前の文書の行）。
  private func before(block: Int, _ lineCount: Int) -> Piece? {
    if block > 0, boundaries[block - 1] == boundaries[block] { return tail(ofBlock: block - 1) }
    let line = boundaries[block] - 1
    return line >= 0 && line < lineCount ? lines(from: line, down: false, lineCount) : nil
  }

  private func head(ofBlock block: Int) -> Piece {
    if case .lines(let run) = contents[block], !run.isEmpty {
      return .inserted(block: block, line: 0)
    }
    return .block(block)
  }

  private func tail(ofBlock block: Int) -> Piece {
    if case .lines(let run) = contents[block], !run.isEmpty {
      return .inserted(block: block, line: run.count - 1)
    }
    return .block(block)
  }

  /// 文書の行 `line` から下（`down`）か上へ、同じ区間の中で間に塊の無い行の区間。
  private func lines(from line: Int, down: Bool, _ lineCount: Int) -> Piece {
    let index = span(containing: line)
    if down {
      let nextSpan =
        index.map { $0 + 1 < spans.count ? spans[$0 + 1].line : Int.max }
        ?? spans.first?.line ?? Int.max
      let nextBlock = blocks(above: line)
      let nextBoundary = nextBlock < count ? boundaries[nextBlock] : Int.max
      return .lines(line...min(lineCount - 1, nextSpan - 1, nextBoundary - 1))
    }
    let spanStart = index.map { spans[$0].line } ?? 0
    let previousBlock = blocks(above: line) - 1
    let previousBoundary = previousBlock >= 0 ? boundaries[previousBlock] : 0
    return .lines(max(0, spanStart, previousBoundary)...line)
  }
}

/// 行の頭の印を描く行——文書の行か、塊 `block` の中の `line` 行目の差し込んだ行。
enum LeadingMarkRow: Equatable, Sendable {
  case document(Int)
  case inserted(block: Int, line: Int)
}

/// 印を出せる行 1 つ——描く行・知らせる行・印の組。
struct LeadingMarkSpot: Equatable, Sendable {
  var row: LeadingMarkRow
  var line: LeadingMarkLine
  var group: Int
}
