import Foundation
import OrbeEditorCore

/// 強調の地——Orbe が押した区間（種類ごとに昇順・重ならない。本文のオフセット）。
struct Highlights: Equatable, Sendable {
  var find: [NSRange] = [] {
    didSet { findRevision += 1 }
  }
  var current: [NSRange] = []
  var selection: [NSRange] = []
  var word: [NSRange] = [] {
    didSet { wordRevision += 1 }
  }
  /// 検索の一致・語の出現を置き直した回数（描画スレッドが、変わらない列を刻みごとに比べ直さない）。
  private(set) var findRevision = 0
  private(set) var wordRevision = 0

  subscript(kind: TextHighlightKind) -> [NSRange] {
    get {
      switch kind {
      case .findMatch: find
      case .currentFindMatch: current
      case .selectionOccurrence: selection
      case .wordOccurrence: word
      }
    }
    set {
      switch kind {
      case .findMatch: find = newValue
      case .currentFindMatch: current = newValue
      case .selectionOccurrence: selection = newValue
      case .wordOccurrence: word = newValue
      }
    }
  }

  /// 検索の一致が多い（俯瞰の印が近似になる件数を超える）——重ね順で検索の一致が選択文字列の出現と語の出現の下へ回る
  /// （VS Code の zIndex の組が変わる）。
  var crowded: Bool { find.count > OverviewRuler.approximateFindMatchCount }

  /// 本文の区間 `window` に掛かる区間があるか（掛かる最初の候補だけを見る——一致の多い長い行でも行の一致を数えない）。
  func touches(_ window: Range<Int>) -> Bool {
    [find, current, selection, word].contains {
      let first = Self.first($0, endingAfter: window.lowerBound)
      return first < $0.count && $0[first].location < window.upperBound
    }
  }

  /// 昇順の列 `ranges` のうち、本文の区間 `window` に掛かるもの（二分探索で切る。長い行でも一致の数 × 行の長さにしない）。
  static func slice(_ ranges: [NSRange], _ window: Range<Int>) -> ArraySlice<NSRange> {
    let low = first(ranges, endingAfter: window.lowerBound)
    var end = low
    while end < ranges.count, ranges[end].location < window.upperBound { end += 1 }
    return ranges[low..<end]
  }

  /// 昇順の列 `ranges` で、終わりが `offset` より後ろの最初の区間の番号（二分探索）。
  private static func first(_ ranges: [NSRange], endingAfter offset: Int) -> Int {
    var low = 0
    var high = ranges.count
    while low < high {
      let mid = (low + high) / 2
      if NSMaxRange(ranges[mid]) <= offset { low = mid + 1 } else { high = mid }
    }
    return low
  }
}

/// 強調の地を描く——選択の地の上・字の下に、行の高さいっぱい・角なしで。下から 現在の一致の行全体 → 〔一致が多いとき
/// 検索の一致〕→ 選択文字列の出現（焦点が無ければ薄い）→ 語の出現 → 〔検索の一致〕→ 現在の一致。x は字を描いた行の
/// 組版から引き、長い行は横に見えている字の区間に掛かる区間だけを描く。
extension FrameBuilder {
  func drawHighlights(
    _ row: RowInFrame, _ highlights: Highlights, rowTop: Double, window: ClosedRange<Int>?,
    _ c: Context
  ) {
    let g = c.g
    let bottom = rowTop + g.lineHeight.rounded()
    let line = row.start..<max(row.end, row.start + 1)
    if !Highlights.slice(highlights.current, line).isEmpty {
      highlightShapes.append(
        ShapeInstance(
          rect: SIMD4(
            Float(g.column), Float(rowTop), Float(g.textRight - g.column), Float(bottom - rowTop)),
          color: c.palette.currentFindLine.packed, radius: 0, kind: 0))
    }
    guard let window, let carets = row.laid.carets else { return }
    let visible = (row.start + window.lowerBound)..<(row.start + window.upperBound + 1)
    let occurrence =
      c.focused ? c.palette.selectionOccurrence : c.palette.selectionOccurrenceInactive
    var layers: [([NSRange], FrameColor)] = [
      (highlights.selection, occurrence), (highlights.word, c.palette.wordOccurrence),
    ]
    layers.insert((highlights.find, c.palette.findMatch), at: highlights.crowded ? 0 : 2)
    layers.append((highlights.current, c.palette.currentFindMatch))
    let originX = g.column - g.scrollX
    for (ranges, ink) in layers {
      for range in Highlights.slice(ranges, visible) {
        let from = max(range.location, row.start) - row.start
        let to = min(NSMaxRange(range) - row.start, row.laid.length)
        guard to > from else { continue }
        for segment in carets.segments(from: from, to: to) {
          let left = (originX + Double(segment.lowerBound) * g.scale).rounded()
          let right = (originX + Double(segment.upperBound) * g.scale).rounded()
          guard right > left else { continue }
          highlightShapes.append(
            ShapeInstance(
              rect: SIMD4(Float(left), Float(rowTop), Float(right - left), Float(bottom - rowTop)),
              color: ink.packed, radius: 0, kind: 0))
        }
      }
    }
  }
}
