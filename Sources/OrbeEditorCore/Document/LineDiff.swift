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

  /// 0 始まりの半開の範囲から（空の範囲は、その境の上）。
  public init(old: Range<Int>, new: Range<Int>) {
    self.init(
      oldStart: old.isEmpty ? old.lowerBound : old.lowerBound + 1, oldCount: old.count,
      newStart: new.isEmpty ? new.lowerBound : new.lowerBound + 1, newCount: new.count)
  }

  /// 古い側の行（0 始まりの半開。件数 0 なら、その境の空の範囲）。
  public var oldLines: Range<Int> {
    let first = oldCount > 0 ? oldStart - 1 : oldStart
    return first..<(first + oldCount)
  }

  /// 新しい側の行（0 始まりの半開。件数 0 なら、その境の空の範囲）。
  public var newLines: Range<Int> {
    let first = newCount > 0 ? newStart - 1 : newStart
    return first..<(first + newCount)
  }
}

/// 行差分の純関数。行はエディターの行——`\n` で割り（`\r` は行の中身に残す）、改行で終わる本文は末尾に空の行を持ち、
/// 空の本文は空の行 1 つ（行の数は `TextRope.lineCount` と常に等しい）。末尾の改行を足す・消すのは、空の行の追加・削除に
/// なる。改行で終わる本文どうしなら、末尾の空の行は両側で揃う。片側が空の本文なら、共通の端の外を 1 つの区間にする（空の
/// 本文の 1 行を、本文の途中の空の行に対応させない）。
///
/// 区間の列の形: 昇順・重ならない（区間の間に文脈の行を挟む）・両側とも本文の中（件数 0 の側の境は `0...行数`）・区間の
/// 外の行は両側で 1 対 1 で同じ中身。最小とは限らない（上限を越えた残りは 1 区間）。編集でずらしたハンク
/// （`VersionedEdit.track`）も同じ形を保つ。
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
    if base.isEmpty { return againstEmpty(Ends(current), isNew: true) }
    if current.length == 0 { return againstEmpty(Ends(base), isNew: false) }
    return hunks(ContiguousArray(base.utf16), current.contiguousUnits(), limit: limit)
  }

  /// 2 つの写しの行差分（`old` が底）。
  public static func hunks(old: TextRope, new: TextRope, limit: Limit) -> [LineHunk] {
    if old.length == 0 { return againstEmpty(Ends(new), isNew: true) }
    if new.length == 0 { return againstEmpty(Ends(old), isNew: false) }
    return hunks(old.contiguousUnits(), new.contiguousUnits(), limit: limit)
  }

  /// 本文の端——先頭と末尾の単位と、行の数（空の本文には無い）。
  private struct Ends {
    let first: UInt16
    let last: UInt16
    let lineCount: Int

    init?(_ text: TextRope) {
      guard text.length > 0 else { return nil }
      first = text.units(in: NSRange(location: 0, length: 1))[0]
      last = text.units(in: NSRange(location: text.length - 1, length: 1))[0]
      lineCount = text.lineCount
    }

    init?(_ text: String) {
      let units = text.utf16
      guard !units.isEmpty else { return nil }
      first = units[units.startIndex]
      last = units[units.index(before: units.endIndex)]
      lineCount = units.reduce(1) { $1 == LineDiff.newline ? $0 + 1 : $0 }
    }
  }

  private static let newline: UInt16 = 0x0A

  /// 空の本文と空でない本文の行差分を、行を割らずに端の行だけで決める（本文が写しなら、空の本文との diff を本文の
  /// 大きさに依らない手間で出す）。空の本文の 1 行は、本文の先頭か末尾の空の行とだけ対応させる（途中の空の行には
  /// 結ばない）。`isNew` なら本文が新しい側（両側とも空なら区間は無い）。
  private static func againstEmpty(_ text: Ends?, isNew: Bool) -> [LineHunk] {
    guard let text else { return [] }
    let firstIsEmpty = text.first == newline
    let shared = firstIsEmpty || text.last == newline ? 1 : 0
    let start = firstIsEmpty ? 1 : 0
    let emptyRest = 1 - shared
    let textRest = text.lineCount - shared
    return [
      isNew
        ? hunk(oldStart: start, oldCount: emptyRest, newStart: start, newCount: textRest)
        : hunk(oldStart: start, oldCount: textRest, newStart: start, newCount: emptyRest)
    ]
  }

  private static func hunks(
    _ baseUnits: ContiguousArray<UInt16>, _ currentUnits: ContiguousArray<UInt16>, limit: Limit
  ) -> [LineHunk] {
    let old = lines(of: baseUnits)
    let new = lines(of: currentUnits)
    let bothEndInNewline = baseUnits.last == newline && currentUnits.last == newline
    let (prefix, suffix) = commonEnds(old, new, tail: bothEndInNewline ? 1 : 0)
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
  private static func withinEdits(_ old: [Int], _ new: [Int], _ maximum: Int) -> Bool {
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

  /// 共通の先頭と末尾の行数（重ならないように末尾は残りの中で数える）。末尾の `tail` 行は先に共通の末尾として取り置く
  /// ——改行で終わる本文どうしの末尾の空の行を、先頭から数えた一致が先に食わない（末尾に空の行で始まる塊を足したとき、
  /// 足した塊が「追加」に、末尾の空の行が文脈になる）。
  private static func commonEnds(
    _ old: [Line], _ new: [Line], tail: Int
  ) -> (prefix: Int, suffix: Int) {
    var prefix = 0
    while prefix < old.count - tail, prefix < new.count - tail, old[prefix] == new[prefix] {
      prefix += 1
    }
    var suffix = tail
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

  /// 0 始まりの位置と件数から。
  private static func hunk(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) -> LineHunk {
    LineHunk(old: oldStart..<(oldStart + oldCount), new: newStart..<(newStart + newCount))
  }

  /// 行の中身（改行を含まない）。行の同一性は UTF-16 の単位の列——`String ==` の正準等価（NFC と NFD を同じとみなす）では
  /// なく、git が違うと言う行をここも違うと言う。
  private typealias Line = ArraySlice<UInt16>

  private static func lines(of units: ContiguousArray<UInt16>) -> [Line] {
    var result: [Line] = []
    var start = 0
    for (index, unit) in units.enumerated() where unit == newline {
      result.append(units[start..<index])
      start = index + 1
    }
    result.append(units[start...])
    return result
  }
}
