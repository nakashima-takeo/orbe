import Foundation

/// baseline と本文の行差分の 1 区間（`@@ -oldStart,oldCount +newStart,newCount @@` と同じ形。行は 1 始まり）。
/// 追加は `oldCount == 0` で `oldStart` は追加位置の直前の行、削除は `newCount == 0` で `newStart` は
/// 削除位置の直前の行（どちらも先頭なら 0）。
public struct LineHunk: Equatable, Sendable {
  public let oldStart: Int
  public let oldCount: Int
  public let newStart: Int
  public let newCount: Int

  public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
    self.oldStart = oldStart
    self.oldCount = oldCount
    self.newStart = newStart
    self.newCount = newCount
  }
}

/// 行差分の純関数。行は `\n` で割り（`\r` は行の中身に残す）、末尾の改行の有無も行の違いとして扱う。
public enum LineDiff {
  /// 差分を取る手間の上限。超えれば、共通の先頭・末尾を落とした残り全体を 1 つの変更区間にする（時間を有界にする）。
  public enum Limit: Equatable, Sendable {
    /// 残りの行数（両側の和）の上限——数えるだけで決まり、超えれば差分を取らない（打鍵ごとに取り直すガター）。
    case lines(Int)
    /// 編集の数（削除と追加の行数の和）の上限——Myers の時間を決める量で、残りが大きくても離れた少しの変更は行ごとに
    /// 取る（diff）。編集の数は前進だけの Myers で上限まで数え、超えた時点で打ち切る。
    case edits(Int)
  }

  /// ガターの上限（残りの行数）。
  public static let maximumComparedLines = 1_000
  public static let gutter = Limit.lines(maximumComparedLines)

  /// 本文の写しは、差分を取る間だけ連続した UTF-16 の列に写す（Myers が行を任意の順に引くため。取り終えたら手放す）。
  public static func hunks(base: String, current: TextRope, limit: Limit = gutter) -> [LineHunk] {
    hunks(ContiguousArray(base.utf16), current.contiguousUnits(), limit: limit)
  }

  /// 2 つの写しの行差分（`old` が底）。
  public static func hunks(old: TextRope, new: TextRope, limit: Limit) -> [LineHunk] {
    hunks(old.contiguousUnits(), new.contiguousUnits(), limit: limit)
  }

  private static func hunks(
    _ baseUnits: ContiguousArray<UInt16>, _ currentUnits: ContiguousArray<UInt16>, limit: Limit
  ) -> [LineHunk] {
    let old = lines(of: baseUnits)
    let new = lines(of: currentUnits)
    let (prefix, suffix) = commonEnds(old, new)
    let oldRest = old[prefix..<(old.count - suffix)]
    let newRest = new[prefix..<(new.count - suffix)]
    guard !oldRest.isEmpty || !newRest.isEmpty else { return [] }
    let whole = [
      hunk(oldStart: prefix, oldCount: oldRest.count, newStart: prefix, newCount: newRest.count)
    ]
    if case .lines(let maximum) = limit, oldRest.count + newRest.count > maximum { return whole }
    let (oldIDs, newIDs) = identities(oldRest, newRest)
    if case .edits(let maximum) = limit, !withinEdits(oldIDs, newIDs, maximum) { return whole }
    let difference = newIDs.difference(from: oldIDs)
    var removed = [Bool](repeating: false, count: oldRest.count)
    for case .remove(let offset, _, _) in difference.removals { removed[offset] = true }
    var inserted = [Bool](repeating: false, count: newRest.count)
    for case .insert(let offset, _, _) in difference.insertions { inserted[offset] = true }
    return collect(removed: removed, inserted: inserted, offset: prefix)
  }

  /// 行を番号に置き換える（同じ行は同じ番号）——差分の比べは番号どうしで済む。
  private static func identities(
    _ old: ArraySlice<Line>, _ new: ArraySlice<Line>
  ) -> (old: [Int], new: [Int]) {
    var table: [Line: Int] = [:]
    let id = { (line: Line) -> Int in
      if let known = table[line] { return known }
      table[line] = table.count
      return table.count - 1
    }
    return (old.map(id), new.map(id))
  }

  /// 編集の数が `maximum` 以下か。前進だけの Myers（対角線ごとに届いた最も遠い位置だけを持つ）で、編集の数を 1 ずつ
  /// 増やしながら両端の終わりに届くまで進め、`maximum` を越えたら打ち切る。時間は O((N+M)·maximum)、記憶は O(maximum)。
  static func withinEdits(_ old: [Int], _ new: [Int], _ maximum: Int) -> Bool {
    let (n, m) = (old.count, new.count)
    let bound = min(maximum, n + m)
    let offset = bound + 1
    var reach = [Int](repeating: 0, count: 2 * bound + 3)
    for d in 0...bound {
      for k in stride(from: -d, through: d, by: 2) {
        var x =
          k == -d || (k != d && reach[offset + k - 1] < reach[offset + k + 1])
          ? reach[offset + k + 1] : reach[offset + k - 1] + 1
        var y = x - k
        while x < n, y < m, old[x] == new[y] {
          x += 1
          y += 1
        }
        reach[offset + k] = x
        if x >= n, y >= m { return true }
      }
    }
    return false
  }

  /// 共通の先頭と末尾の行数（重ならないように末尾は残りの中で数える）。
  private static func commonEnds(_ old: [Line], _ new: [Line]) -> (prefix: Int, suffix: Int) {
    var prefix = 0
    while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < old.count - prefix, suffix < new.count - prefix,
      old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
    {
      suffix += 1
    }
    return (prefix, suffix)
  }

  /// 削除と挿入の印を両側で同時に歩き、隣り合う削除と挿入を 1 つの区間に畳む。
  private static func collect(removed: [Bool], inserted: [Bool], offset: Int) -> [LineHunk] {
    var hunks: [LineHunk] = []
    var i = 0
    var j = 0
    while i < removed.count || j < inserted.count {
      let oldStart = i
      let newStart = j
      while (i < removed.count && removed[i]) || (j < inserted.count && inserted[j]) {
        while i < removed.count, removed[i] { i += 1 }
        while j < inserted.count, inserted[j] { j += 1 }
      }
      if i > oldStart || j > newStart {
        hunks.append(
          hunk(
            oldStart: offset + oldStart, oldCount: i - oldStart, newStart: offset + newStart,
            newCount: j - newStart))
      } else {
        i += 1
        j += 1
      }
    }
    return hunks
  }

  /// 0 始まりの位置と件数から 1 始まりの区間へ。件数 0 の側は「直前の行」を指す。
  private static func hunk(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) -> LineHunk {
    LineHunk(
      oldStart: oldCount == 0 ? oldStart : oldStart + 1, oldCount: oldCount,
      newStart: newCount == 0 ? newStart : newStart + 1, newCount: newCount)
  }

  /// 行の中身と、改行で終わっているか。最後の行だけ改行を欠きうる。行の同一性は UTF-16 の単位の列——`String ==` の
  /// 正準等価（NFC と NFD を同じとみなす）ではなく、git が違うと言う行をここも違うと言う。
  private struct Line: Hashable {
    let body: ArraySlice<UInt16>
    let terminated: Bool

    static func == (lhs: Line, rhs: Line) -> Bool {
      lhs.terminated == rhs.terminated && lhs.body.elementsEqual(rhs.body)
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(terminated)
      for unit in body { hasher.combine(unit) }
    }
  }

  private static func lines(of units: ContiguousArray<UInt16>) -> [Line] {
    var result: [Line] = []
    var start = 0
    for (index, unit) in units.enumerated() where unit == 0x0A {
      result.append(Line(body: ArraySlice(units[start..<index]), terminated: true))
      start = index + 1
    }
    if start < units.count {
      result.append(Line(body: ArraySlice(units[start...]), terminated: false))
    }
    return result
  }
}
