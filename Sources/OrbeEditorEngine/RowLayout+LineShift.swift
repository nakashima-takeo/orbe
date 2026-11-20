import Foundation
import OrbeEditorCore

/// 面自身の編集で、並びの境と区間の始まりをずらす規則（→ `RowLayout.shift`）。
extension RowLayout {
  /// 束の行の増減（編集前の本文の座標の区間と、行の数の差）。
  struct LineChange {
    var start: Int
    var end: Int
    var delta: Int
  }

  /// 編集の束で、境の昇順の列をずらす規則。
  struct LineShift {
    let changes: [LineChange]
    let before: TextRope
    let total: Int
    let firstRow: Int
    let lastRow: Int

    init(changes: [LineChange], before: TextRope) {
      self.changes = changes
      self.before = before
      total = changes.reduce(0) { $0 + $1.delta }
      firstRow = before.row(containing: changes[0].start)
      lastRow = before.row(containing: changes.map(\.end).max() ?? 0)
    }

    /// 昇順の境の列 `lines` をずらす（値が最初の編集の行以下の境は、付き先が編集より前にあるので動かない）。値の変わった
    /// 境があれば true。
    func apply(to lines: inout [Int]) -> Bool {
      guard let range = moving(lines.count, { lines[$0] }) else { return false }
      for index in range { lines[index] = shifted(lines[index]) }
      return true
    }

    /// 区間の始まりを、境と同じ規則でずらす。値の変わった始まりがあれば true。
    func apply(to spans: inout [LineSpan]) -> Bool {
      guard let range = moving(spans.count, { spans[$0].line }) else { return false }
      for index in range { spans[index].line = shifted(spans[index].line) }
      return true
    }

    /// 昇順の `count` 個の境（`lineAt` で引く）のうち、書き換える添字の範囲。値の変わる境が無ければ nil。読むだけで決めてから
    /// 書く——並びの列は描く材料と共有しているので、書くと列全体がコピーされる。行の数を変えない束では、最後の編集の行より
    /// 後ろの境は動かないので、そこで走査を止める。
    private func moving(_ count: Int, _ lineAt: (Int) -> Int) -> Range<Int>? {
      let start = RowLayout.count(count, atOrBelow: firstRow, lineAt)
      var end = start
      var moves = false
      while end < count {
        let line = lineAt(end)
        if line - 1 > lastRow {
          guard total != 0 else { break }
          return start..<count
        }
        if shifted(line) != line { moves = true }
        end += 1
      }
      return moves ? start..<end : nil
    }

    /// 境 `boundary` の編集の後の値。
    private func shifted(_ boundary: Int) -> Int {
      guard boundary - 1 <= lastRow else { return boundary + total }
      let anchor = RowLayout.anchor(of: boundary, in: before)
      var row = boundary - 1
      var delta = 0
      for change in changes {
        guard change.start < anchor else { break }
        if anchor < change.end {
          row = before.row(containing: change.start)
        } else {
          delta += change.delta
        }
      }
      return row + delta + 1
    }
  }
}
