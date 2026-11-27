import Foundation
import OrbeEditorCore

/// 並びに混ぜる注記（PR の diff のコメントの層が渡す）——行の下に置く絵の差し込み、コメントできる行のまとまり、スレッドのある
/// 行。行はどれもその側の版の行（0 始まり）。
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
    /// スレッドのある行（側ごと）。行の地をスレッドのある行の上書きにする。
    var threads: (old: Set<Int>, new: Set<Int>) = ([], [])
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
    var shift = 0
    for hunk in hunks {
      if line < hunk.oldLines.lowerBound { break }
      if line < hunk.oldLines.upperBound { return .changed(hunk, line - hunk.oldLines.lowerBound) }
      shift = hunk.newLines.upperBound - hunk.oldLines.upperBound
    }
    return .context(line + shift)
  }

  /// 新しい側の行 `line` が、どの区間の何番目の追加の行か、区間の外なら対応する古い側の行。
  private static func row(ofNew line: Int, _ hunks: [LineHunk]) -> Row {
    var shift = 0
    for hunk in hunks {
      if line < hunk.newLines.lowerBound { break }
      if line < hunk.newLines.upperBound { return .changed(hunk, line - hunk.newLines.lowerBound) }
      shift = hunk.oldLines.upperBound - hunk.newLines.upperBound
    }
    return .context(line + shift)
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

  /// 文書の行の区間を、まとまりの区間 `hunks`（その側の区間とまとまりの番号）の端とスレッドのある行で割る。割った区間は元の
  /// 区間の型ともう一方の番号を引き継ぎ、まとまりの区間に入る区間はその番号を印の組にし、スレッドのある行はスレッドのある行の
  /// 上書きを持つ。どちらも無ければ元の列のまま。
  static func refine(
    _ spans: [LineSpan], lines: Int, hunks: [(range: Range<Int>, index: Int)], threads: Set<Int>
  ) -> [LineSpan] {
    guard !hunks.isEmpty || !threads.isEmpty else { return spans }
    var cuts = Set(spans.map(\.line))
    for hunk in hunks { cuts.formUnion([hunk.range.lowerBound, hunk.range.upperBound]) }
    for line in threads { cuts.formUnion([line, line + 1]) }
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
          override: threads.contains(start) ? DiffStyle.threadOverride : nil))
    }
    return result
  }
}
