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
  /// 共通の先頭・末尾を落とした後、差分を取る残りの行数（両側の和）の上限。超える大きな入れ替えは
  /// 残り全体を 1 つの変更区間にする（Myers は差分の大きさに二乗で効くため、上限で時間を有界にする）。
  public static let maximumComparedLines = 1_000

  public static func hunks(base: String, current: String) -> [LineHunk] {
    let old = lines(of: base)
    let new = lines(of: current)
    let (prefix, suffix) = commonEnds(old, new)
    let oldRest = old[prefix..<(old.count - suffix)]
    let newRest = new[prefix..<(new.count - suffix)]
    guard !oldRest.isEmpty || !newRest.isEmpty else { return [] }
    guard oldRest.count + newRest.count <= maximumComparedLines else {
      return [
        hunk(oldStart: prefix, oldCount: oldRest.count, newStart: prefix, newCount: newRest.count)
      ]
    }
    let difference = newRest.difference(from: oldRest)
    var removed = [Bool](repeating: false, count: oldRest.count)
    for case .remove(let offset, _, _) in difference.removals { removed[offset] = true }
    var inserted = [Bool](repeating: false, count: newRest.count)
    for case .insert(let offset, _, _) in difference.insertions { inserted[offset] = true }
    return collect(removed: removed, inserted: inserted, offset: prefix)
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

  /// 行の中身と、改行で終わっているか。最後の行だけ改行を欠きうる。
  private struct Line: Equatable {
    let body: Substring
    let terminated: Bool
  }

  private static func lines(of text: String) -> [Line] {
    var result: [Line] = []
    let utf8 = text.utf8
    var start = utf8.startIndex
    var index = utf8.startIndex
    while index < utf8.endIndex {
      let next = utf8.index(after: index)
      if utf8[index] == 0x0A {
        result.append(Line(body: text[start..<index], terminated: true))
        start = next
      }
      index = next
    }
    if start < utf8.endIndex { result.append(Line(body: text[start...], terminated: false)) }
    return result
  }
}
