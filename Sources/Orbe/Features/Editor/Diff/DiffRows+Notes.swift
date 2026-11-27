import Foundation
import OrbeEditorCore

/// 並びに混ぜる注記（PR の diff のコメントの層が渡す）——行の下に置く絵の差し込み、コメントできる行のまとまり、地を替える
/// 行の範囲。行はどれもその側の版の行（0 始まり）。
extension DiffRows {
  /// diff のどちらの側の行か。
  enum Version: Hashable {
    case old
    case new
  }

  struct Notes {
    /// 行の下に置く絵の差し込み。同じ行の差し込みは、列の順に上から並ぶ。
    var zones: [Zone] = []
    /// コメントできる行のまとまり。まとまりの行に行の頭の印を出し、まとまりの番号を印の組にする。
    var hunks = CommentHunks()
    /// 地を替える行の範囲（列の順に当て、同じ行に掛かれば後の範囲が勝つ）。
    var overrides: [Override] = []
  }

  /// 地を替える行の範囲 1 つ——範囲と、替える地の種類。
  struct Override {
    let range: DiffLineRange
    let kind: OverrideKind
  }

  /// 替える地の種類——スレッドのある行か、書いている欄の範囲か。
  enum OverrideKind {
    case thread
    case draft

    /// 行の上書きの番号（→ `DiffStyle`）。
    var style: Int { self == .thread ? DiffStyle.threadOverride : DiffStyle.draftOverride }
  }

  /// コメントできる行のまとまり 1 つ——古い側と新しい側の、その側の版の行（0 始まり）の半開区間。
  struct CommentHunk: Equatable {
    let old: Range<Int>
    let new: Range<Int>
  }

  /// コメントできる行のまとまり（手元の git が出す、変更とその前後 3 行の区間。GitHub の PR の diff の区間と同じもの）の列
  /// ——まとまりごとに、古い側と新しい側の、その側の版の行（0 始まり）の半開区間（どちらかが空のこともある）。どちらの側も、
  /// 区間は昇順で重ならない。列の中の番号が、並びの印の組になる。
  struct CommentHunks: Equatable {
    var items: [CommentHunk] = []

    /// 側 `version` の行 `line` を含むまとまりの番号（無ければ nil）。
    func index(of line: Int, _ version: Version) -> Int? {
      let side = { (hunk: CommentHunk) in version == .old ? hunk.old : hunk.new }
      var (low, high) = (0, items.count)
      while low < high {
        let mid = (low + high) / 2
        let range = side(items[mid])
        if range.isEmpty ? range.lowerBound <= line : range.upperBound <= line {
          low = mid + 1
        } else {
          high = mid
        }
      }
      while low < items.count, side(items[low]).isEmpty { low += 1 }
      return low < items.count && side(items[low]).contains(line) ? low : nil
    }

    /// 範囲 `range` の両端が、同じまとまりに入るか。
    func holds(_ range: DiffLineRange) -> Bool {
      guard let found = index(of: range.end.line, range.end.version) else { return false }
      return index(of: range.first.line, range.first.version) == found
    }

    /// 側 `version` の、空でない区間とまとまりの番号の列（昇順）。
    func ranges(_ version: Version) -> [(range: Range<Int>, index: Int)] {
      items.enumerated().compactMap { index, hunk in
        let range = version == .old ? hunk.old : hunk.new
        return range.isEmpty ? nil : (range, index)
      }
    }
  }

  /// 行 `line` の下に置く絵の差し込み。
  struct Zone {
    let version: Version
    let line: Int
    let zone: any SurfaceZone
  }

  /// 差し込みを置く所——境 `boundary` の、差し込んだ行（削除行か詰め物）の塊のうち先頭から `depth` 行の後（0 なら塊より上）。
  struct Slot: Hashable {
    let boundary: Int
    let depth: Int
  }

  /// 片側の行の、行差分の中での位置。
  enum Row {
    /// 区間 `hunk` のその側の `k` 番目の行（古い側なら削除行、新しい側なら追加の行）。
    case changed(LineHunk, Int)
    /// 区間の外の行。対応する反対側の行 `line`。
    case context(Int)
  }

  /// 古い側の行 `line` が、どの区間の何番目の削除行か、区間の外なら対応する新しい側の行。
  static func row(ofOld line: Int, _ hunks: [LineHunk]) -> Row {
    row(of: line, hunks, \.oldLines, \.newLines)
  }

  /// 新しい側の行 `line` が、どの区間の何番目の追加の行か、区間の外なら対応する古い側の行。
  private static func row(ofNew line: Int, _ hunks: [LineHunk]) -> Row {
    row(of: line, hunks, \.newLines, \.oldLines)
  }

  /// 側 `own` の行 `line` の、行差分 `hunks` の中での位置（反対側は `other`）。区間の列は両側とも昇順なので、`line` 以前に
  /// 始まる最後の区間を二分探索で引く。
  private static func row(
    of line: Int, _ hunks: [LineHunk], _ own: KeyPath<LineHunk, Range<Int>>,
    _ other: KeyPath<LineHunk, Range<Int>>
  ) -> Row {
    var (low, high) = (0, hunks.count)
    while low < high {
      let mid = (low + high) / 2
      if hunks[mid][keyPath: own].lowerBound <= line { low = mid + 1 } else { high = mid }
    }
    guard low > 0 else { return .context(line) }
    let hunk = hunks[low - 1]
    let lines = hunk[keyPath: own]
    if line < lines.upperBound { return .changed(hunk, line - lines.lowerBound) }
    return .context(line + hunk[keyPath: other].upperBound - lines.upperBound)
  }

  /// 並列で、行 `zone.line` の絵を置く所（その側）と、相手と同じ高さの空きを置く所（反対側）。区間の `k` 段目は左の古い側の
  /// `k` 番目の行と右の新しい側の `k` 番目の行に揃い、短い側の段は区間の後ろの詰め物になる。行が面の外なら nil。
  static func sideSlots(_ zone: Zone, _ hunks: [LineHunk], old: Side, new: Side) -> (
    own: Slot, other: Slot
  )? {
    let own = Slot(boundary: zone.line + 1, depth: 0)
    switch zone.version {
    case .old:
      guard zone.line < old.lines else { return nil }
      switch row(ofOld: zone.line, hunks) {
      case .changed(let hunk, let k):
        return (own, slot(afterRow: k, of: hunk.newLines))
      case .context(let line):
        return line < new.lines ? (own, Slot(boundary: line + 1, depth: 0)) : nil
      }
    case .new:
      guard zone.line < new.lines else { return nil }
      switch row(ofNew: zone.line, hunks) {
      case .changed(let hunk, let k):
        return (own, slot(afterRow: k, of: hunk.oldLines))
      case .context(let line):
        return line < old.lines ? (own, Slot(boundary: line + 1, depth: 0)) : nil
      }
    }
  }

  /// 区間の `k` 段目の後の、片側 `lines` の所——その側に `k` 番目の行があればその行の後、無ければ区間の後ろの詰め物の
  /// `k − 行数 + 1` 行目の後。
  private static func slot(afterRow k: Int, of lines: Range<Int>) -> Slot {
    k < lines.count
      ? Slot(boundary: lines.lowerBound + k + 1, depth: 0)
      : Slot(boundary: lines.upperBound, depth: k - lines.count + 1)
  }

  /// 境ごとに置く差し込みを積み、差し込んだ行の塊と混ぜて境の昇順の列にする。
  struct Slots {
    private var items: [Int: [(depth: Int, content: RowInsertion.Content)]] = [:]

    mutating func add(_ content: RowInsertion.Content, at slot: Slot) {
      items[slot.boundary, default: []].append((slot.depth, content))
    }

    /// 境ごとの差し込んだ行の塊 `runs` に、積んだ差し込みを割り込ませた列。同じ所の差し込みは積んだ順。
    func insertions(runs: [Int: [InsertedLine]]) -> [RowInsertion] {
      var result: [RowInsertion] = []
      for boundary in Set(runs.keys).union(items.keys).sorted() {
        let run = runs[boundary] ?? []
        var cursor = 0
        let placed = (items[boundary] ?? []).enumerated().sorted {
          ($0.element.depth, $0.offset) < ($1.element.depth, $1.offset)
        }
        for (_, item) in placed {
          let depth = min(item.depth, run.count)
          if depth > cursor {
            result.append(RowInsertion(line: boundary, content: .lines(Array(run[cursor..<depth]))))
            cursor = depth
          }
          result.append(RowInsertion(line: boundary, content: item.content))
        }
        if cursor < run.count {
          result.append(RowInsertion(line: boundary, content: .lines(Array(run[cursor...]))))
        }
      }
      return result
    }
  }

  /// 範囲 `range` が覆う行（側ごとの半開区間）。同じ側の範囲はその側の始まり〜終わり、側をまたぐ範囲はインラインの並びの順で
  /// 始まりから終わりまでの間に出る行（→ `inlineLines`）。行差分 `hunks` は、範囲の行を数えた版の、両側の本文の行差分。
  static func coveredLines(of range: DiffLineRange, _ hunks: [LineHunk]) -> (
    old: Range<Int>, new: Range<Int>
  ) {
    let first = range.first
    guard first.version == range.end.version else { return inlineLines(of: range, hunks) }
    let lines = min(first.line, range.end.line)..<(max(first.line, range.end.line) + 1)
    return first.version == .old ? (lines, 0..<0) : (0..<0, lines)
  }

  /// 範囲 `range` の始まりから終わりまでの、インラインの並びの順で間に出る行（両端を含む。側ごとの半開区間）。並びの順では、
  /// 文脈の行が 1 行で両側の番号を持ち、変更区間では削除行の後に追加の行が来る。古い側の文脈の行は、対応する新しい側の行の所に
  /// 出る。
  static func inlineLines(of range: DiffLineRange, _ hunks: [LineHunk]) -> (
    old: Range<Int>, new: Range<Int>
  ) {
    let ends = [order(of: range.first, hunks), order(of: range.end, hunks)].sorted()
    let (from, to) = (ends[0], ends[1])
    let new = from.line..<max(from.line, to.kind == 1 ? to.line + 1 : to.line)
    // 最後の区間より後の古い側の行 o は、新しい側の行 o + shift の所に出る。だから、to より後に出る古い側の行は、二分探索の
    // 上限 bound より前に必ず在る。
    let shift = hunks.reduce(0) { $0 + $1.newLines.count - $1.oldLines.count }
    let bound = max(0, hunks.last?.oldLines.upperBound ?? 0, to.line - shift + 1)
    let old = { (line: Int) in order(of: DiffLine(version: .old, line: line), hunks) }
    let firstOld = searchOld(bound) { old($0) >= from }
    let pastOld = searchOld(bound) { old($0) > to }
    return (firstOld..<max(firstOld, pastOld), new)
  }

  /// インラインの並びの順の位置——新しい側の行 n は (n, 1, 0)、区間の k 番目の削除行は (区間の新しい側の始まり, 0, k)。
  private struct InlineOrder: Comparable {
    let line: Int
    let kind: Int
    let row: Int

    static func < (a: InlineOrder, b: InlineOrder) -> Bool {
      (a.line, a.kind, a.row) < (b.line, b.kind, b.row)
    }
  }

  private static func order(of line: DiffLine, _ hunks: [LineHunk]) -> InlineOrder {
    guard line.version == .old else { return InlineOrder(line: line.line, kind: 1, row: 0) }
    switch row(ofOld: line.line, hunks) {
    case .changed(let hunk, let k):
      return InlineOrder(line: hunk.newLines.lowerBound, kind: 0, row: k)
    case .context(let new): return InlineOrder(line: new, kind: 1, row: 0)
    }
  }

  /// 古い側の行 `0..<count` のうち、`isPast` が成り立つ最初の行（成り立つ行は後ろに続く。無ければ `count`）。
  private static func searchOld(_ count: Int, _ isPast: (Int) -> Bool) -> Int {
    var (low, high) = (0, max(0, count))
    while low < high {
      let mid = (low + high) / 2
      if isPast(mid) { high = mid } else { low = mid + 1 }
    }
    return low
  }

  /// 地を替える範囲 `overrides` の、その側の行の区間と行の上書きの番号（列の順）。`covered` は範囲ごとに行に解いた区間（側ごと。
  /// `overrides` と同じ順）。
  static func resolve(
    _ overrides: [Override], _ covered: [(old: Range<Int>, new: Range<Int>)],
    side version: Version
  ) -> [(range: Range<Int>, style: Int)] {
    zip(overrides, covered).compactMap { override, lines in
      let range = version == .old ? lines.old : lines.new
      return range.isEmpty ? nil : (range, override.kind.style)
    }
  }

  /// 行 `line` に掛かる、地を替える範囲の最後のものの上書きの番号（無ければ nil）。
  static func override(of line: Int, in overrides: [(range: Range<Int>, style: Int)]) -> Int? {
    overrides.last { $0.range.contains(line) }?.style
  }

  /// 文書の行の区間を、まとまりの区間 `hunks`（その側の区間とまとまりの番号）の端と地を替える範囲 `overrides`（その側の区間と
  /// 行の上書きの番号）の端で割る。割った区間は元の区間の型ともう一方の番号を引き継ぎ、まとまりの区間に入る区間はその番号を
  /// 印の組にし、地を替える範囲に入る区間はその上書きを持つ。どちらも無ければ元の列のまま。
  static func refine(
    _ spans: [LineSpan], lines: Int, hunks: [(range: Range<Int>, index: Int)],
    overrides: [(range: Range<Int>, style: Int)]
  ) -> [LineSpan] {
    guard !hunks.isEmpty || !overrides.isEmpty else { return spans }
    var cuts = Set(spans.map(\.line))
    for hunk in hunks { cuts.formUnion([hunk.range.lowerBound, hunk.range.upperBound]) }
    for override in overrides {
      cuts.formUnion([override.range.lowerBound, override.range.upperBound])
    }
    var result: [LineSpan] = []
    var owner = -1
    var next = 0
    for start in cuts.filter({ $0 >= 0 && $0 < lines }).sorted() {
      while owner + 1 < spans.count, spans[owner + 1].line <= start { owner += 1 }
      while next < hunks.count, hunks[next].range.upperBound <= start { next += 1 }
      let base = owner >= 0 ? spans[owner] : LineSpan(line: start)
      result.append(
        LineSpan(
          line: start, style: base.style,
          otherNumber: base.otherNumber.map { $0 + start - base.line },
          markGroup: next < hunks.count && hunks[next].range.contains(start)
            ? hunks[next].index : nil,
          override: override(of: start, in: overrides)))
    }
    return result
  }
}
