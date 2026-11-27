import Foundation
import OrbeEditorCore

/// 面自身の編集で、並びの境と区間の始まりをずらす規則（→ `RowLayout.shift`）。
extension RowLayout {
  /// 昇順の列 `lines` の中で `line` 以下のものの数。
  static func count(_ lines: [Int], atOrBelow line: Int) -> Int {
    count(lines.count, atOrBelow: line) { lines[$0] }
  }

  /// 昇順の `count` 個の値（`lineAt` で引く）の中で `line` 以下のものの数。
  static func count(_ count: Int, atOrBelow line: Int, _ lineAt: (Int) -> Int) -> Int {
    var low = 0
    var high = count
    while low < high {
      let mid = (low + high) / 2
      if lineAt(mid) <= line { low = mid + 1 } else { high = mid }
    }
    return low
  }

  /// 境 `boundary`（≥ 1）の付き先——行 boundary−1 の中身の終わり（改行の手前。CRLF なら CR の手前）。
  static func anchor(of boundary: Int, in text: TextRope) -> Int {
    guard boundary < text.lineCount else { return text.length }
    let newline = text.lineStart(boundary) - 1
    guard newline > 0, text.units(in: NSRange(location: newline - 1, length: 1)).first == 0x0D
    else { return newline }
    return newline - 1
  }

  /// 束の行の増減（編集前の本文の座標の区間と、その始まりと終わりの行と、行の数の差）。
  struct LineChange {
    var start: Int
    var end: Int
    var rows: ClosedRange<Int>
    var delta: Int
  }

  /// 行の重なる編集を 1 つにまとめたもの——編集前の本文の行の区間と、最初の編集の始まり（オフセット）と、行の数の差。
  struct LineGroup {
    var rows: ClosedRange<Int>
    var start: Int
    var delta: Int

    /// 昇順の編集 `changes` を、行の重なるものどうしでまとめる。
    static func of(_ changes: [LineChange]) -> [LineGroup] {
      var groups: [LineGroup] = []
      for change in changes {
        if let last = groups.last, change.rows.lowerBound <= last.rows.upperBound {
          groups[groups.count - 1].rows =
            last.rows.lowerBound...max(last.rows.upperBound, change.rows.upperBound)
          groups[groups.count - 1].delta += change.delta
        } else {
          groups.append(LineGroup(rows: change.rows, start: change.start, delta: change.delta))
        }
      }
      return groups
    }
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
      firstRow = changes[0].rows.lowerBound
      lastRow = changes.map(\.rows.upperBound).max() ?? 0
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

  /// 折り返しを待つ行——面自身の編集が掛かった行（編集の後の行の区間で、昇順。折り返していた行は 1 段の行に置き換えて
  /// ある）と、区間ごとの前の折り返しの手がかり（行の数を変えない、行 1 つの編集だけ）と、置き換えで行ごとの折り返しの
  /// 木を変えたか。`shift` が返し、束を当てた後の本文で `rewrap` に渡す。
  struct Unwrapped {
    var lines: [Range<Int>] = []
    var resumes: [LineWrap.Resume?] = []
    var changed = false
  }

  /// `unwrap` の読むだけの半分——編集のまとまりごとに、折り返しを待つ行と前の折り返しの手がかりを `unwrapped` に足し、
  /// 1 段の行に置き換える区間を `edits` に足す。行 1 つで行の数を変えない編集は、その行の折り返しの有無で決める（木を
  /// 1 度だけ引く）。
  func planUnwrap(
    _ changes: [LineChange], in before: TextRope, into unwrapped: inout Unwrapped,
    _ edits: inout [(lines: Range<Int>, with: [WrappedLine?])]
  ) {
    guard let wraps else { return }
    var shifted = 0
    for group in LineGroup.of(changes) {
      let lines = group.rows.lowerBound..<(group.rows.upperBound + 1)
      let count = lines.count + group.delta
      unwrapped.lines.append(lines.lowerBound + shifted..<lines.lowerBound + shifted + count)
      shifted += group.delta
      let single = lines.count == 1 && group.delta == 0
      let old = single ? wraps.wrap(ofLine: lines.lowerBound) : nil
      unwrapped.resumes.append(
        old.map {
          LineWrap.Resume(old: $0, edited: group.start - before.lineStart(lines.lowerBound))
        }
      )
      let plain =
        group.delta == 0
        && (single
          ? old == nil
          : wraps.segments(before: lines.upperBound) - wraps.segments(before: lines.lowerBound)
            == lines.count)
      if !plain { edits.append((lines, [WrappedLine?](repeating: nil, count: count))) }
    }
  }
}
