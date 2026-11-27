import Foundation
import OrbeEditorCore

/// 行差分の区間の列から、diff の面に置く並び（インライン・並列）を作る純関数。行の型は `DiffStyle` の番号で、色を知らない。
///
/// 片側の大きさは行差分が数える行の数で（→ `LineDiff`）、版が有れば面の行の数と同じ。その版に無い側（新しいファイルの
/// 古い側・消したファイルの新しい側）は 0 行で（面が持つ空の行 1 つは数えない）、有る側の全部の行が追加か削除になる（空の
/// 本文は空の行 1 つで、版が無いのとは違う）。区間の列は `LineDiff` の出力の形（昇順・重ならない・両側とも本文の中・
/// 区間の外の行は両側で 1 対 1）を前提にする。
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
    return [LineHunk(old: 0..<old.lines, new: 0..<new.lines)]
  }

  /// インライン——新しい側の面に、区間の削除行を「古い側の行を指す差し込み」として区間の新しい側の始まりの境に置き、追加の
  /// 区間に型「追加」、文脈の区間に旧番号の始まりを渡す（差し込みの出どころは呼び手が添える）。注記（`notes`）があれば、絵の
  /// 差し込みを行の下に置き、コメントできる行に印の組（まとまりの番号。同じまとまりの削除行と新しい側の行は同じ組）を、
  /// 地を替える範囲の行（並びの順で範囲の始まりから終わりまでの間の行の全部）に上書きを付ける——新しい側の行の絵はその行の
  /// 後（次の区間の削除行より上）、古い側の行の絵は、削除行ならその削除行の直後（削除行の塊を割る）、文脈の行なら対応する新しい
  /// 側の行の後。
  static func inline(_ hunks: [LineHunk], new: Side, notes: Notes = Notes()) -> SurfaceRows {
    let lines = { (range: DiffLineRange) in inlineLines(of: range, hunks) }
    let removedOverrides = resolve(notes.overrides, side: .old, lines)
    var spans = Spans(limit: new.lines)
    var runs: [Int: [InsertedLine]] = [:]
    var oldNext = 0
    var newNext = 0
    for hunk in hunks {
      let block = (old: hunk.oldLines, new: hunk.newLines)
      if block.new.lowerBound > newNext { spans.add(newNext, otherNumber: oldNext + 1) }
      if !block.old.isEmpty {
        runs[block.new.lowerBound] = block.old.map { line in
          InsertedLine(
            line: line, style: DiffStyle.removed, markGroup: notes.hunks.index(of: line, .old),
            override: override(of: line, in: removedOverrides))
        }
      }
      if !block.new.isEmpty { spans.add(block.new.lowerBound, style: DiffStyle.added) }
      oldNext = block.old.upperBound
      newNext = block.new.upperBound
    }
    if newNext < new.lines { spans.add(newNext, otherNumber: oldNext + 1) }
    var slots = Slots()
    for zone in notes.zones {
      let slot: Slot?
      switch zone.version {
      case .new: slot = zone.line < new.lines ? Slot(boundary: zone.line + 1, depth: 0) : nil
      case .old:
        switch row(ofOld: zone.line, hunks) {
        case .changed(let hunk, let k):
          slot = Slot(boundary: hunk.newLines.lowerBound, depth: k + 1)
        case .context(let line):
          slot = line < new.lines ? Slot(boundary: line + 1, depth: 0) : nil
        }
      }
      if let slot { slots.add(.zone(zone.zone), at: slot) }
    }
    return SurfaceRows(
      insertions: slots.insertions(runs: runs),
      spans: refine(
        spans.items, lines: new.lines, hunks: notes.hunks.ranges(.new),
        overrides: resolve(notes.overrides, side: .new, lines)))
  }

  /// 並列の左（古い側）と右（新しい側）——文脈は両側とも型なし。区間は両側の同じ行から始め、左は型「削除」、右は型「追加」で、
  /// 削除と追加の数の差だけ短い側の区間の後ろに詰め物（何も指さない差し込み・型「詰め物」）を置く。注記（`notes`）があれば、
  /// 古い側の行の絵は左、新しい側の行の絵は右の、その行の後に置き、反対側の同じ段の後（詰め物の塊の途中を含む）に相手と同じ
  /// 高さの空きを置く。地を替える範囲は、範囲が覆う行（→ `coveredLines`）の古い側を左、新しい側を右の行に付ける。
  static func side(_ hunks: [LineHunk], old: Side, new: Side, notes: Notes = Notes()) -> (
    left: SurfaceRows, right: SurfaceRows
  ) {
    var left = (spans: Spans(limit: old.lines), runs: [Int: [InsertedLine]]())
    var right = (spans: Spans(limit: new.lines), runs: [Int: [InsertedLine]]())
    let pads = { (count: Int) in
      Array(repeating: InsertedLine(style: DiffStyle.pad), count: count)
    }
    for hunk in hunks {
      let block = (old: hunk.oldLines, new: hunk.newLines)
      if !block.old.isEmpty { left.spans.add(block.old.lowerBound, style: DiffStyle.removed) }
      if !block.new.isEmpty { right.spans.add(block.new.lowerBound, style: DiffStyle.added) }
      let difference = block.new.count - block.old.count
      if difference > 0 {
        left.runs[block.old.upperBound] = pads(difference)
      } else if difference < 0 {
        right.runs[block.new.upperBound] = pads(-difference)
      }
      left.spans.add(block.old.upperBound)
      right.spans.add(block.new.upperBound)
    }
    let covered = { (range: DiffLineRange) in coveredLines(of: range, hunks) }
    var slots = (left: Slots(), right: Slots())
    for zone in notes.zones {
      guard let (own, other) = sideSlots(zone, hunks, old: old, new: new) else { continue }
      switch zone.version {
      case .old:
        slots.left.add(.zone(zone.zone), at: own)
        slots.right.add(.gap(zone.zone), at: other)
      case .new:
        slots.right.add(.zone(zone.zone), at: own)
        slots.left.add(.gap(zone.zone), at: other)
      }
    }
    return (
      SurfaceRows(
        insertions: slots.left.insertions(runs: left.runs),
        spans: refine(
          left.spans.items, lines: old.lines, hunks: notes.hunks.ranges(.old),
          overrides: resolve(notes.overrides, side: .old, covered))),
      SurfaceRows(
        insertions: slots.right.insertions(runs: right.runs),
        spans: refine(
          right.spans.items, lines: new.lines, hunks: notes.hunks.ranges(.new),
          overrides: resolve(notes.overrides, side: .new, covered)))
    )
  }

  /// インラインで、新しい側の面の見えている先頭 `top`（差し込んだ行だけを数えた段 → `TextSurface.lineRow(of:)`）から
  /// `count` 段の中に出る古い側の行を含む範囲——先頭の段の次に出る古い側の行から `count` 行（インラインに出る古い側の行は
  /// 単調に増え、1 段に高々 1 行）。
  static func oldLines(from top: LineRow, count: Int, _ hunks: [LineHunk]) -> ClosedRange<Int> {
    let start = anchor(at: top, hunks, side: false).line
    return start...(start + max(0, count))
  }

  /// 縦の並びの中の位置の、古い側に付けた錨——古い側の行 `line`（`0...古い側の行数`）の段と、その上に並ぶ追加の行の段の数
  /// `added`（0 以下。古い側の行に揃わない追加の行を指すとき）。古い側が変わらず新しい側が変わる作り直しで、読んでいた
  /// 位置を引き継ぐ。
  struct Anchor: Equatable {
    let line: Int
    let added: Int
  }

  /// 新しい側の面の位置 `top`（差し込んだ行だけを数えた段 → `TextSurface.lineRow(of:)`）を、行差分 `hunks` の並び（`side`
  /// なら並列の右、そうでなければインライン）で古い側の錨に直す。
  static func anchor(at top: LineRow, _ hunks: [LineHunk], side: Bool) -> Anchor {
    var shift = 0
    for hunk in hunks {
      let (old, new) = (hunk.oldLines, hunk.newLines)
      if side {
        // 区間の段 r は、左の古い行 old.lowerBound + r と右の新しい行 new.lowerBound + r に揃う。右の詰め物は区間の後ろ。
        if top.line == new.upperBound, top.offset < 0, old.count > new.count {
          let row = new.count + max(0, old.count - new.count + top.offset)
          return Anchor(line: old.lowerBound + row, added: 0)
        }
        if top.line < new.lowerBound { break }
        if top.line < new.upperBound {
          let row = top.line - new.lowerBound
          return row < old.count
            ? Anchor(line: old.lowerBound + row, added: 0)
            : Anchor(line: old.upperBound, added: row - new.count)
        }
      } else {
        if top.line < new.lowerBound { break }
        if top.line == new.lowerBound, top.offset < 0, !old.isEmpty {
          return Anchor(line: old.lowerBound + max(0, old.count + top.offset), added: 0)
        }
        if top.line < new.upperBound {
          return Anchor(line: old.upperBound, added: top.line - new.upperBound)
        }
      }
      shift = old.upperBound - new.upperBound
    }
    return Anchor(line: max(0, top.line + shift), added: 0)
  }

  /// 古い側の錨 `anchor` を、行差分 `hunks` の並びの新しい側の面の位置（差し込んだ行だけを数えた段）に戻す
  /// （`anchor(at:_:side:)` の逆）。錨の追加の行が新しい並びに無ければ、同じ区間の頭に寄せる。
  static func lineRow(of anchor: Anchor, _ hunks: [LineHunk], side: Bool) -> LineRow {
    var shift = 0
    for hunk in hunks {
      let (old, new) = (hunk.oldLines, hunk.newLines)
      if anchor.line < old.lowerBound { break }
      if anchor.line < old.upperBound {
        let row = anchor.line - old.lowerBound
        guard side else { return LineRow(line: new.lowerBound, offset: row - old.count) }
        return row < new.count
          ? LineRow(line: new.lowerBound + row)
          : LineRow(line: new.upperBound, offset: row - old.count)
      }
      if anchor.line == old.upperBound, anchor.added < 0, !new.isEmpty {
        let first = side ? new.lowerBound + min(old.count, new.count) : new.lowerBound
        return LineRow(line: max(first, new.upperBound + anchor.added))
      }
      shift = new.upperBound - old.upperBound
    }
    return LineRow(line: max(0, anchor.line + shift))
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
