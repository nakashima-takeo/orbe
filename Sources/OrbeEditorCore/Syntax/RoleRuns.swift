import Foundation

/// 文書全体を覆う役割の並び——「役割（または役割なし）と長さ」の連なりの列を、本文のロープと同じ B 木に載せたもの。
/// 長さの和は本文の長さと等しい。値として写すのは O(1) で、面・ミニマップ・裏の仕事がロックなしで読める。まだ作り直して
/// いない範囲はこの型に入れない（裏の仕事が別に持つ）——ここにあるのは、最後に作った役割を編集に合わせてずらしたもの。
public struct RoleRuns: Sendable {
  struct Run: TreeElement, Equatable {
    var role: SyntaxRole?
    var length: Int

    var summary: Length { Length(value: length) }
  }

  struct Length: TreeSummary {
    var value: Int

    static let zero = Length(value: 0)

    static func + (lhs: Length, rhs: Length) -> Length { Length(value: lhs.value + rhs.value) }
  }

  /// 連なりの番号の区間と、その先頭のオフセットと、連なり。
  private struct Window {
    let indices: Range<Int>
    let start: Int
    let runs: [Run]
  }

  private var runs: SummaryTree<Run>

  /// 長さ `length` の、全体が役割なしの並び。
  public init(length: Int) {
    runs = SummaryTree(length > 0 ? [Run(role: nil, length: length)] : [])
  }

  public var length: Int { runs.summary.value }

  /// `range` の中の役割の区間——重ならない昇順で、`range` の中に閉じる。役割の無い字は含まない。
  public func roles(in range: NSRange) -> [HighlightSpan] {
    let start = max(0, range.location)
    let end = min(NSMaxRange(range), length)
    guard start < end else { return [] }
    let (index, before) = runs.locate(start, by: \.value)
    var result: [HighlightSpan] = []
    var runStart = before.value
    for run in runs.elements(from: index) {
      guard runStart < end else { break }
      if let role = run.role {
        let from = max(runStart, start)
        let to = min(runStart + run.length, end)
        result.append(HighlightSpan(range: NSRange(location: from, length: to - from), role: role))
      }
      runStart += run.length
    }
    return result
  }

  /// 編集に合わせてずらす。消した区間は縮め、挿入は挿入点を含む連なり（境なら前の連なり）を伸ばす——打ち込み中の語は
  /// 前の色を引き継ぐ。main の即時の更新と、届いた古い結果の写しは、この 1 つの規則を使う。
  public mutating func apply(_ edit: TextEdit) {
    let start = min(edit.range.location, length)
    let end = min(NSMaxRange(edit.range), length)
    guard !runs.isEmpty else {
      if edit.replacementLength > 0 {
        runs = SummaryTree([Run(role: nil, length: edit.replacementLength)])
      }
      return
    }
    let window = window(covering: start > 0 ? start - 1 : 0, end)
    let (before, after) = Self.pieces(of: window, outside: start, end)
    let role = start > 0 ? before.last?.role : after.first?.role
    let local = before + [Run(role: role, length: edit.replacementLength)] + after
    runs.replaceSubrange(window.indices, with: Self.coalesced(local))
  }

  /// `range` の役割を `spans`（`range` の中の役割の区間。重ならない昇順）で置き換え、役割が変わった字を返す。区間の外の
  /// 字は変えない。
  @discardableResult
  public mutating func replace(_ range: NSRange, with spans: [HighlightSpan]) -> IndexSet {
    let start = max(0, range.location)
    let end = min(NSMaxRange(range), length)
    guard start < end else { return IndexSet() }
    let window = window(covering: start, end)
    let (before, after) = Self.pieces(of: window, outside: start, end)
    var middle: [Run] = []
    var cursor = start
    for span in spans {
      let from = max(span.range.location, cursor)
      let to = min(NSMaxRange(span.range), end)
      guard from < to else { continue }
      if from > cursor { middle.append(Run(role: nil, length: from - cursor)) }
      middle.append(Run(role: span.role, length: to - from))
      cursor = to
    }
    if end > cursor { middle.append(Run(role: nil, length: end - cursor)) }
    let changed = Self.differences(Self.inside(window, start, end), middle, from: start)
    runs.replaceSubrange(window.indices, with: Self.coalesced(before + middle + after))
    return changed
  }

  /// `[start, end)`（空なら `start` の位置）に掛かる連なりに、両隣を 1 つずつ足した窓（隣と同じ役割になれば繋ぐため）。
  private func window(covering start: Int, _ end: Int) -> Window {
    var first = runs.locate(start, by: \.value).index
    var last = end > start ? runs.locate(end - 1, by: \.value).index : first
    first = max(0, min(first, runs.count - 1) - 1)
    last = min(runs.count - 1, last + 1)
    let begin = runs.prefix(upTo: first).value
    let local = Array(runs.elements(from: first).prefix(last - first + 1))
    return Window(indices: first..<(last + 1), start: begin, runs: local)
  }

  /// 窓の連なりのうち `[start, end)` の前と後ろに残る部分。
  private static func pieces(
    of window: Window, outside start: Int, _ end: Int
  ) -> (before: [Run], after: [Run]) {
    var before: [Run] = []
    var after: [Run] = []
    var position = window.start
    for run in window.runs {
      let head = min(position + run.length, start) - position
      if head > 0 { before.append(Run(role: run.role, length: head)) }
      let tail = position + run.length - max(position, end)
      if tail > 0 { after.append(Run(role: run.role, length: tail)) }
      position += run.length
    }
    return (before, after)
  }

  /// 窓の連なりのうち `[start, end)` の中の部分。
  private static func inside(_ window: Window, _ start: Int, _ end: Int) -> [Run] {
    var result: [Run] = []
    var position = window.start
    for run in window.runs {
      let overlap = min(position + run.length, end) - max(position, start)
      if overlap > 0 { result.append(Run(role: run.role, length: overlap)) }
      position += run.length
    }
    return result
  }

  /// 同じ長さを覆う 2 つの連なりの列で、役割が違う字（`start` から数える）。
  private static func differences(_ old: [Run], _ new: [Run], from start: Int) -> IndexSet {
    var result = IndexSet()
    var position = start
    var (i, j, usedOld, usedNew) = (0, 0, 0, 0)
    while i < old.count, j < new.count {
      let step = min(old[i].length - usedOld, new[j].length - usedNew)
      if old[i].role != new[j].role { result.insert(integersIn: position..<(position + step)) }
      position += step
      usedOld += step
      usedNew += step
      if usedOld == old[i].length { (i, usedOld) = (i + 1, 0) }
      if usedNew == new[j].length { (j, usedNew) = (j + 1, 0) }
    }
    return result
  }

  /// 長さ 0 の連なりを落とし、隣り合う同じ役割を繋ぐ。
  private static func coalesced(_ runs: [Run]) -> [Run] {
    var result: [Run] = []
    for run in runs where run.length > 0 {
      if let last = result.last, last.role == run.role {
        result[result.count - 1].length += run.length
      } else {
        result.append(run)
      }
    }
    return result
  }
}
