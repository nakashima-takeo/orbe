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

/// 版を 1 つ進めた編集。行と桁も持つ——tree-sitter の編集と、ハンクのずらしに使う（どちらも編集の時点の本文でしか
/// 出せない）。
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

  /// 編集の前の本文に対するハンク（`LineDiff` の出力と同じ形）を、編集の後の本文に対する同じ形のハンクへ写す。形は、
  /// 昇順・重ならない・両側とも本文の中・区間の外の行は両側で 1 対 1 で同じ中身。変えた行は区間に入り、それと重なる・
  /// 接する区間と 1 つにつなぐ（最小とは限らない）。後ろの区間は行の増減ぶんずれる。行の数が変わらなければそのまま
  /// （行の中だけの編集は、裏の結果が届くまで区間を変えない）。
  public func track(_ hunks: [LineHunk]) -> [LineHunk] {
    let delta = rows.newEnd - rows.oldEnd
    guard delta != 0 else { return hunks }
    var result: [LineHunk] = []
    result.reserveCapacity(hunks.count + 1)
    var index = 0
    // 区間の外の行の、古い側の行 − 新しい側の行。
    var offset = 0
    while index < hunks.count, hunks[index].newLines.upperBound < rows.start {
      result.append(hunks[index])
      offset = hunks[index].oldLines.upperBound - hunks[index].newLines.upperBound
      index += 1
    }
    var new = rows.start..<rows.oldEnd
    var old = (rows.start + offset)..<(rows.oldEnd + offset)
    if index < hunks.count, hunks[index].newLines.lowerBound <= rows.oldEnd {
      let first = hunks[index]
      var last = first
      while index < hunks.count, hunks[index].newLines.lowerBound <= rows.oldEnd {
        last = hunks[index]
        index += 1
      }
      let lower = first.newLines.lowerBound <= rows.start
      let upper = last.newLines.upperBound >= rows.oldEnd
      let after = last.oldLines.upperBound - last.newLines.upperBound
      new =
        (lower ? first.newLines.lowerBound : rows.start)
        ..< (upper ? last.newLines.upperBound : rows.oldEnd)
      old =
        (lower ? first.oldLines.lowerBound : old.lowerBound)
        ..< (upper ? last.oldLines.upperBound : rows.oldEnd + after)
    }
    let edited = new.lowerBound..<(new.upperBound + delta)
    if !old.isEmpty || !edited.isEmpty { result.append(LineHunk(old: old, new: edited)) }
    while index < hunks.count {
      let hunk = hunks[index]
      result.append(
        LineHunk(
          old: hunk.oldLines,
          new: (hunk.newLines.lowerBound + delta)..<(hunk.newLines.upperBound + delta)))
      index += 1
    }
    return result
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
