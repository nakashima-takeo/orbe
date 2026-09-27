import Foundation
import TreeSitter

/// 注入の層の並び——束ねない層を開始位置の順に載せた区間の木と、束ねた層の列。区間の木の項目は前の項目の原点からの距離を
/// 持つので、編集より後ろの層は項目 1 つを直すだけでずれ、打鍵 1 回の手間が注入の数に比例しない。要約に部分木の最も遠い
/// 端を持ち、区画と交わる層を枝を刈りながら引く（区画より前から始まって区画まで伸びる層も引ける）。
struct InjectionLayers {
  private var entries = SummaryTree<LayerEntry>([])
  /// 束ねた層（原点は本文の先頭）。
  private(set) var combined: [SyntaxLayer] = []

  /// 区画と交わる層（束ねない層は開始位置の順、その後に束ねた層）。
  func intersecting(_ piece: Range<Int>) -> [Placed] {
    var result: [Placed] = []
    entries.visit(
      entering: { before, span in before.offset + span.reach > piece.lowerBound },
      { _, before, entry in
        let placed = Placed(entry, before)
        guard placed.origin < piece.upperBound else { return false }
        if placed.origin + entry.extent > piece.lowerBound { result.append(placed) }
        return true
      })
    for layer in combined where layer.parts.contains(where: { $0.match.overlaps(piece) }) {
      result.append(Placed(layer: layer, origin: 0, row: 0))
    }
    return result
  }

  /// すべての層（束ねない層は開始位置の順、その後に束ねた層）。
  var all: [Placed] {
    var result: [Placed] = []
    entries.visit(
      entering: { _, _ in true },
      { _, before, entry in
        result.append(Placed(entry, before))
        return true
      })
    return result + combined.map { Placed(layer: $0, origin: 0, row: 0) }
  }

  /// 深さ `depth` の束ねない層のうち、マッチが区画に掛かるもの（開始位置の順）。
  func uncombined(atDepth depth: Int, touching piece: Range<Int>) -> [(index: Int, placed: Placed)]
  {
    var result: [(Int, Placed)] = []
    entries.visit(
      entering: { before, span in before.offset + span.reach > piece.lowerBound },
      { index, before, entry in
        let placed = Placed(entry, before)
        guard placed.origin < piece.upperBound else { return false }
        if entry.layer.depth == depth, placed.globalMatch.touches(piece) {
          result.append((index, placed))
        }
        return true
      })
    return result
  }

  mutating func insert(_ placed: Placed) {
    let (index, before) = entries.locate(placed.origin, by: \.offset)
    let entry = LayerEntry(
      gap: placed.origin - before.offset, rowGap: placed.row - before.rows,
      extent: placed.layer.extent, layer: placed.layer)
    guard index < entries.count else {
      entries.replaceSubrange(index..<index, with: [entry])
      return
    }
    var next = entries[index]
    next.gap -= entry.gap
    next.rowGap -= entry.rowGap
    entries.replaceSubrange(index..<(index + 1), with: [entry, next])
  }

  mutating func remove(at index: Int) {
    let entry = entries[index]
    guard index + 1 < entries.count else {
      entries.replaceSubrange(index..<(index + 1), with: [])
      return
    }
    var next = entries[index + 1]
    next.gap += entry.gap
    next.rowGap += entry.rowGap
    entries.replaceSubrange(index..<(index + 2), with: [next])
  }

  mutating func append(combined layer: SyntaxLayer) {
    combined.append(layer)
  }

  /// 編集 1 つを写す。束ねた層と、編集に掛かる束ねない層の木へは層の座標で写し、後ろの層は原点をずらす。原点をまたぐ編集
  /// （原点が行頭でなくなる）と、マッチを丸ごと消す編集（層を生んだ節が消える）は、その層を子孫ごと外す——空になった
  /// マッチは、文書の末尾にあるとどの区画にも掛からず、問い直しで外れない。束ねた層は丸ごと消えた部分を除き、部分が全部
  /// 消えたら外す。外した範囲（編集の前の本文の上）を返す。
  mutating func apply(_ record: VersionedEdit) -> IndexSet {
    let start = record.edit.range.location
    let end = NSMaxRange(record.edit.range)
    func erased(_ match: Range<Int>) -> Bool {
      start < end && start <= match.lowerBound && match.upperBound <= end
    }
    var doomed: [Placed] = []
    for layer in combined where layer.parts.allSatisfy({ erased($0.match) }) {
      doomed.append(Placed(layer: layer, origin: 0, row: 0))
    }
    entries.visit(
      entering: { before, span in before.offset + span.reach >= start },
      { _, before, entry in
        let placed = Placed(entry, before)
        guard placed.origin <= end else { return false }
        if placed.origin > start || erased(placed.globalMatch) { doomed.append(placed) }
        return true
      })
    let removed = doomed.isEmpty ? IndexSet() : drop(doomed)
    for layer in combined where start <= layer.extent {
      layer.parts.removeAll { erased($0.match) }
      layer.edit(TSInputEdit(record, origin: 0, row: 0))
    }
    var touched: [(index: Int, placed: Placed)] = []
    entries.visit(
      entering: { before, span in before.offset + span.reach >= start },
      { index, before, entry in
        let placed = Placed(entry, before)
        guard placed.origin <= start else { return false }
        touched.append((index, placed))
        return true
      })
    let (next, _) = entries.locate(end, by: \.offset)
    if next < entries.count {
      var entry = entries[next]
      entry.gap += record.edit.replacementLength - record.edit.range.length
      entry.rowGap += record.newEnd.row - record.oldEnd.row
      entries.replaceSubrange(next..<(next + 1), with: [entry])
    }
    for (index, placed) in touched {
      placed.layer.edit(TSInputEdit(record, origin: placed.origin, row: placed.row))
      var entry = entries[index]
      entry.extent = placed.layer.extent
      entries.replaceSubrange(index..<(index + 1), with: [entry])
    }
    return removed
  }

  /// 層を子孫ごと外し、外した範囲（本文の上）を返す。`doomed` は並びから既に外した層でもよい。
  mutating func drop(_ doomed: [Placed]) -> IndexSet {
    let ids = Set(doomed.map { ObjectIdentifier($0.layer) })
    var removed = IndexSet()
    var indices = IndexSet()
    for placed in doomed {
      let lower = placed.origin
      let upper = placed.origin + placed.layer.extent
      removed.formUnion(placed.whole)
      entries.visit(
        entering: { before, span in before.offset + span.reach >= lower },
        { index, before, entry in
          guard before.offset + entry.gap <= upper else { return false }
          if entry.layer.descends(from: ids) { indices.insert(index) }
          return true
        })
    }
    for index in indices.reversed() {
      entries[index].layer.detached = true
      remove(at: index)
    }
    for layer in combined where layer.descends(from: ids) { layer.detached = true }
    combined.removeAll { $0.detached }
    for placed in doomed { placed.layer.detached = true }
    return removed
  }
}

/// 区間の木に載せる、束ねない注入の層 1 つ。
private struct LayerEntry: TreeElement {
  /// 前の項目の原点からの距離（UTF-16）と行の差。先頭の項目は本文の先頭から。
  var gap: Int
  var rowGap: Int
  /// 原点からマッチの終わりまで。
  var extent: Int
  let layer: SyntaxLayer

  var summary: LayerSpan { LayerSpan(offset: gap, rows: rowGap, reach: gap + extent) }
}

/// 区間の木の要約——距離と行の和と、部分木の手前から数えた最も遠い端。
private struct LayerSpan: TreeSummary {
  var offset: Int
  var rows: Int
  var reach: Int

  static let zero = LayerSpan(offset: 0, rows: 0, reach: Int.min / 4)

  static func + (lhs: LayerSpan, rhs: LayerSpan) -> LayerSpan {
    LayerSpan(
      offset: lhs.offset + rhs.offset, rows: lhs.rows + rhs.rows,
      reach: max(lhs.reach, lhs.offset + rhs.reach))
  }
}

extension Placed {
  fileprivate init(_ entry: LayerEntry, _ before: LayerSpan) {
    self.init(
      layer: entry.layer, origin: before.offset + entry.gap, row: before.rows + entry.rowGap)
  }
}
