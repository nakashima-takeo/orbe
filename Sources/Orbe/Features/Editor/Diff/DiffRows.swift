import Foundation
import OrbeEditorCore

/// 行差分の区間の列から、diff の面に置く並び（インライン・並列）を作る純関数。行の型は `DiffStyle` の番号で、色を知らない。
///
/// 片側の大きさは面の行の数で、行差分が数える行の数と同じ（→ `LineDiff`）。その版に無い側（新しいファイルの古い側・消した
/// ファイルの新しい側）は 0 行で、有る側の全部の行が追加か削除になる（空の本文は空の行 1 つで、版が無いのとは違う）。区間の
/// 外の行は両側で 1 対 1 に揃う。
enum DiffRows {
  /// 片側の大きさ（面の行の数。版が無ければ 0）。
  struct Side: Equatable {
    let lines: Int

    /// 写し `text` の大きさ（nil は版が無い）。
    init(_ text: TextRope?) {
      lines = text?.lineCount ?? 0
    }

    /// 版が無い。
    var isAbsent: Bool { lines == 0 }
  }

  /// 古い側と新しい側の行差分（nil は版が無い側）。片側が無ければ行差分を取らず、無い側 0 行・有る側の全部の行の区間 1 つ
  /// にする（本文を割らないので、大きなファイルでも手間は端の数だけ）。
  static func hunks(old: TextRope?, new: TextRope?, limit: LineDiff.Limit) -> [LineHunk] {
    if let old, let new { return LineDiff.hunks(old: old, new: new, limit: limit) }
    let (old, new) = (Side(old), Side(new))
    guard !old.isAbsent || !new.isAbsent else { return [] }
    return [
      LineHunk(
        oldStart: old.isAbsent ? 0 : 1, oldCount: old.lines, newStart: new.isAbsent ? 0 : 1,
        newCount: new.lines)
    ]
  }

  /// 区間 1 つの 0 始まりの範囲。
  private struct Block {
    let old: Range<Int>
    let new: Range<Int>

    init(_ hunk: LineHunk) {
      let oldFirst = hunk.oldCount > 0 ? hunk.oldStart - 1 : hunk.oldStart
      let newFirst = hunk.newCount > 0 ? hunk.newStart - 1 : hunk.newStart
      old = oldFirst..<(oldFirst + hunk.oldCount)
      new = newFirst..<(newFirst + hunk.newCount)
    }
  }

  /// インライン——新しい側の面に、区間の削除行を「古い側の行を指す差し込み」として区間の新しい側の始まりの境に置き、追加の
  /// 区間に型「追加」、文脈の区間に旧番号の始まりを渡す（差し込みの出どころは呼び手が添える）。
  static func inline(_ hunks: [LineHunk], new: Side) -> SurfaceRows {
    var spans = Spans(limit: new.lines)
    var insertions: [RowInsertion] = []
    var oldNext = 0
    var newNext = 0
    for block in hunks.map(Block.init) {
      if block.new.lowerBound > newNext { spans.add(newNext, otherNumber: oldNext + 1) }
      if !block.old.isEmpty {
        insertions.append(
          RowInsertion(
            line: block.new.lowerBound,
            content: .lines(block.old.map { InsertedLine(line: $0, style: DiffStyle.removed) })))
      }
      if !block.new.isEmpty { spans.add(block.new.lowerBound, style: DiffStyle.added) }
      oldNext = block.old.upperBound
      newNext = block.new.upperBound
    }
    if newNext < new.lines { spans.add(newNext, otherNumber: oldNext + 1) }
    return SurfaceRows(insertions: insertions, spans: spans.items)
  }

  /// 並列の左（古い側）と右（新しい側）——文脈は両側とも型なし。区間は両側の同じ行から始め、左は型「削除」、右は型「追加」で、
  /// 削除と追加の数の差だけ短い側の区間の後ろに詰め物（何も指さない差し込み・型「詰め物」）を置く。
  static func side(_ hunks: [LineHunk], old: Side, new: Side) -> (
    left: SurfaceRows, right: SurfaceRows
  ) {
    var left = (spans: Spans(limit: old.lines), insertions: [RowInsertion]())
    var right = (spans: Spans(limit: new.lines), insertions: [RowInsertion]())
    let pads = { (count: Int) in
      Array(repeating: InsertedLine(style: DiffStyle.pad), count: count)
    }
    for block in hunks.map(Block.init) {
      if !block.old.isEmpty { left.spans.add(block.old.lowerBound, style: DiffStyle.removed) }
      if !block.new.isEmpty { right.spans.add(block.new.lowerBound, style: DiffStyle.added) }
      let difference = block.new.count - block.old.count
      if difference > 0 {
        left.insertions.append(
          RowInsertion(line: block.old.upperBound, content: .lines(pads(difference))))
      } else if difference < 0 {
        right.insertions.append(
          RowInsertion(line: block.new.upperBound, content: .lines(pads(-difference))))
      }
      left.spans.add(block.old.upperBound)
      right.spans.add(block.new.upperBound)
    }
    return (
      SurfaceRows(insertions: left.insertions, spans: left.spans.items),
      SurfaceRows(insertions: right.insertions, spans: right.spans.items)
    )
  }

  /// 新しい側の行 `line` に揃う古い側の行（区間の中なら、区間の古い側の同じ段か、区間の古い側の最後）。
  static func oldLine(forNew line: Int, _ hunks: [LineHunk]) -> Int {
    var shift = 0
    for block in hunks.map(Block.init) {
      if line < block.new.lowerBound { break }
      if line < block.new.upperBound {
        return block.old.lowerBound + min(line - block.new.lowerBound, max(0, block.old.count - 1))
      }
      shift = block.old.upperBound - block.new.upperBound
    }
    return max(0, line + shift)
  }

  /// 区間の始まりの昇順の列。同じ行に重ねて置けば後の方を残し、面の行の外（`limit` 以上）は置かない。
  private struct Spans {
    let limit: Int
    private(set) var items: [LineSpan] = []

    init(limit: Int) {
      self.limit = limit
    }

    mutating func add(_ line: Int, style: Int? = nil, otherNumber: Int? = nil) {
      guard line < limit else { return }
      let span = LineSpan(line: line, style: style, otherNumber: otherNumber)
      if items.last?.line == line {
        items[items.count - 1] = span
      } else {
        items.append(span)
      }
    }
  }
}
