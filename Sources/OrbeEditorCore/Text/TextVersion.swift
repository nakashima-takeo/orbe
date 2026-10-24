import Foundation

/// 本文の中の位置を行と桁（UTF-16）で表したもの。
public struct TextPoint: Equatable, Sendable {
  public let row: Int
  public let column: Int

  public init(row: Int, column: Int) {
    self.row = row
    self.column = column
  }
}

/// 編集が中身を変えた行の範囲（0 始まり、半開）。編集の前の本文では `start..<oldEnd`、後の本文では `start..<newEnd`
/// で、範囲の外の行は両側で中身が同じ（前は `oldEnd` 以降が、後は `newEnd` 以降に 1 対 1 で並ぶ）。
public struct EditedRows: Equatable, Sendable {
  public let start: Int
  public let oldEnd: Int
  public let newEnd: Int

  /// 編集の始まり・前の終わり・後の終わりの位置から。行頭から行頭への編集は行ごとの挿入・削除で、終わりの行は変わらない。
  /// `keepsStartRow`（始まりの行の中身を変えないと、編集の前の本文から分かる）なら、始まりの行も範囲に入れない。
  public init(start: TextPoint, oldEnd: TextPoint, newEnd: TextPoint, keepsStartRow: Bool) {
    if start.column == 0, oldEnd.column == 0, newEnd.column == 0 {
      self.start = start.row
      self.oldEnd = oldEnd.row
      self.newEnd = newEnd.row
      return
    }
    self.start = keepsStartRow ? start.row + 1 : start.row
    self.oldEnd = oldEnd.row + 1
    self.newEnd = newEnd.row + 1
  }
}

/// 版を 1 つ進めた編集。行と桁は tree-sitter の編集に、中身を変えた行（`rows`）はハンクのずらしに使う（どちらも編集の
/// 時点の本文でしか出せない）。
public struct VersionedEdit: Sendable {
  /// この編集の後の版。
  public let version: Int
  public let edit: TextEdit
  public let start: TextPoint
  /// 置き換える前の区間の終わり（編集の前の本文）。
  public let oldEnd: TextPoint
  /// 置き換えた区間の終わり（編集の後の本文）。
  public let newEnd: TextPoint
  /// 中身を変えた行。
  public let rows: EditedRows

  /// 当てた順の編集の列（どれもその直前の本文の座標）で、最初の編集の前の本文に対するハンク（`LineDiff` の出力と同じ形）を、
  /// 最後の編集の後の本文に対する同じ形のハンクへ写す。行の数を変える編集ごとに、変えた行を区間に入れ、それと重なる・接する
  /// 区間と 1 つにつなぎ（最小とは限らない）、後ろの区間を行の増減ぶんずらす。行の数を変えない編集は区間を変えない（区間の
  /// 外の行の中身は、裏の結果が届くまで底と違いうる）。
  ///
  /// 区間の列を「今の編集より前」と「掛かる・後ろ」に分けて持ち、後ろのずれはまとめて足すので、手間は編集の数と、続く編集の
  /// 間にある区間の数の和に比例する（束は後ろから当てた並びなので、カーソルが多い打鍵でも区間を 1 回なめるだけ）。
  static func track(_ hunks: [LineHunk], through edits: some Sequence<Self>) -> [LineHunk] {
    var front = hunks
    // 逆順（末尾が最も前）。新しい側は `shift` を足した位置。
    var back: [LineHunk] = []
    var shift = 0
    for edit in edits {
      let rows = edit.rows
      let delta = rows.newEnd - rows.oldEnd
      guard delta != 0 else { continue }
      while let top = back.last, top.newLines.upperBound + shift < rows.start {
        front.append(top.shifted(by: shift))
        back.removeLast()
      }
      while let last = front.last, last.newLines.upperBound >= rows.start {
        back.append(last.shifted(by: -shift))
        front.removeLast()
      }
      // 区間の外の行の、古い側の行 − 新しい側の行。
      let offset = front.last.map { $0.oldLines.upperBound - $0.newLines.upperBound } ?? 0
      var new = rows.start..<rows.oldEnd
      var old = (rows.start + offset)..<(rows.oldEnd + offset)
      if let top = back.last, top.newLines.lowerBound + shift <= rows.oldEnd {
        let first = top.shifted(by: shift)
        var last = first
        while let top = back.last, top.newLines.lowerBound + shift <= rows.oldEnd {
          last = top.shifted(by: shift)
          back.removeLast()
        }
        let lower = first.newLines.lowerBound <= rows.start
        let upper = last.newLines.upperBound >= rows.oldEnd
        let after = last.oldLines.upperBound - last.newLines.upperBound
        let newStart = lower ? first.newLines.lowerBound : rows.start
        let oldStart = lower ? first.oldLines.lowerBound : old.lowerBound
        new = newStart..<(upper ? last.newLines.upperBound : rows.oldEnd)
        old = oldStart..<(upper ? last.oldLines.upperBound : rows.oldEnd + after)
      }
      shift += delta
      let edited = new.lowerBound..<(new.upperBound + delta)
      if !old.isEmpty || !edited.isEmpty {
        back.append(LineHunk(old: old, new: edited).shifted(by: -shift))
      }
    }
    guard !back.isEmpty else { return front }
    return front + back.reversed().map { $0.shifted(by: shift) }
  }
}

extension LineHunk {
  fileprivate func shifted(by delta: Int) -> LineHunk {
    LineHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart + delta, newCount: newCount)
  }
}

/// 本文の版と、まだ届いていない裏の結果を今の版まで写すための編集の記録。記録は、結果を待っている版のうち最も古いもの
/// より後ろだけを持つ。
public struct EditLog: Sendable {
  /// 今の版（編集 1 回で 1 進む）。
  public private(set) var version = 0
  /// 版 `version - edits.count + 1 ... version` の編集。
  private var edits: [VersionedEdit] = []

  public init() {}

  /// `keepsStartRow` は `EditedRows` のとおり。
  public mutating func append(
    _ edit: TextEdit, start: TextPoint, oldEnd: TextPoint, newEnd: TextPoint, keepsStartRow: Bool
  )
    -> VersionedEdit
  {
    version += 1
    let record = VersionedEdit(
      version: version, edit: edit, start: start, oldEnd: oldEnd, newEnd: newEnd,
      rows: EditedRows(start: start, oldEnd: oldEnd, newEnd: newEnd, keepsStartRow: keepsStartRow))
    edits.append(record)
    return record
  }

  /// 版 `version` より後ろの編集。記録を既に捨てた版なら nil（その版の結果は写せない）。
  public func edits(since version: Int) -> ArraySlice<VersionedEdit>? {
    let oldest = self.version - edits.count
    guard version >= oldest, version <= self.version else { return nil }
    return edits[(version - oldest)...]
  }

  /// 版 `version` までの編集を捨てる（その版より古い結果をもう待たない）。
  public mutating func discard(through version: Int) {
    let oldest = self.version - edits.count
    let count = min(max(0, version - oldest), edits.count)
    edits.removeFirst(count)
  }
}
