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

  /// ハンクを編集の後の行へずらす。編集より後ろの行は、編集で増減した行の数だけ動く。行頭が消えた行の端は、編集の
  /// 終わりに寄せる。
  public func track(_ hunks: [LineHunk]) -> [LineHunk] {
    let delta = newEnd.row - oldEnd.row
    guard delta != 0 else { return hunks }
    // 境 b は「0 始まりの行 b の上」。
    func boundary(_ b: Int) -> Int {
      if b <= start.row { return b }
      if b > oldEnd.row { return b + delta }
      return newEnd.row + (newEnd.column > 0 ? 1 : 0)
    }
    return hunks.map { hunk in
      guard hunk.newCount > 0 else {
        return LineHunk(
          oldStart: hunk.oldStart, oldCount: hunk.oldCount, newStart: boundary(hunk.newStart),
          newCount: 0)
      }
      let first = boundary(hunk.newStart - 1)
      let end = max(first + 1, boundary(hunk.newStart - 1 + hunk.newCount))
      return LineHunk(
        oldStart: hunk.oldStart, oldCount: hunk.oldCount, newStart: first + 1,
        newCount: end - first)
    }
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

  public mutating func append(
    _ edit: TextEdit, start: TextPoint, oldEnd: TextPoint, newEnd: TextPoint
  )
    -> VersionedEdit
  {
    version += 1
    let record = VersionedEdit(
      version: version, edit: edit, start: start, oldEnd: oldEnd, newEnd: newEnd)
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
