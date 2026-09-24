import AppKit
import OrbeEditorCore
import STTextView

/// 強調の地（選択文字列の出現・語の出現・検索の一致・現在の一致と、その行全体）。上流の本文の層（`contentView`）の中で
/// 選択の層の直上・文字の層の直下に置かれ、選択の地の上・文字の下に出る。地は行の高さいっぱい・角なし（VS Code と同じ）。
/// 当たりを持たず、寸法は viewport で、位置は面がスクロールと layout のたびに置き直す。bounds は text container 基準
/// （本文の層の座標と同じ）なので、segment の矩形をそのまま描く。
final class TextHighlightView: NSView {
  private weak var textView: STTextView?
  private let style: TextSurfaceStyle.Highlights
  /// 種類ごとの区間（昇順・重ならない。UTF-16）。
  var ranges: [TextHighlightKind: [NSRange]] = [:] {
    didSet { needsDisplay = true }
  }
  /// 面に焦点があるか（選択文字列の出現の濃さが変わる）。
  var isFocused = false {
    didSet { if isFocused != oldValue { needsDisplay = true } }
  }

  init(textView: STTextView, style: TextSurfaceStyle.Highlights) {
    self.textView = textView
    self.style = style
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// 下から 現在の一致の行 → 選択文字列の出現 → 語の出現 → 検索の一致 → 現在の一致。一致が多いとき（ruler が近似に
  /// なる件数を超える）検索の一致は現在の一致の行の直上へ回る（VS Code の zIndex の組が変わる）。
  override func draw(_ dirtyRect: NSRect) {
    guard let textView, ranges.values.contains(where: { !$0.isEmpty }) else { return }
    let geometry = VisibleLines(textView: textView)
    let lines = geometry.lines(in: bounds)
    guard let first = lines.first, let last = lines.last else { return }
    let visible = NSRange(
      location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
    let rows = lines.flatMap(\.rows)
    let findMatches = ranges[.findMatch] ?? []
    let crowded = findMatches.count > OverviewRuler.approximateFindMatchCount
    if let current = ranges[.currentFindMatch]?.first {
      fillLines(of: current, rows: rows, color: style.currentFindLine)
    }
    if crowded { fill(findMatches, in: visible, rows: rows, color: style.findMatch) }
    fill(
      ranges[.selectionOccurrence] ?? [], in: visible, rows: rows,
      color: isFocused ? style.selectionOccurrence : style.selectionOccurrenceInactive)
    fill(ranges[.wordOccurrence] ?? [], in: visible, rows: rows, color: style.wordOccurrence)
    if !crowded { fill(findMatches, in: visible, rows: rows, color: style.findMatch) }
    fill(ranges[.currentFindMatch] ?? [], in: visible, rows: rows, color: style.currentFindMatch)
  }

  /// 可視の段落に掛かる区間を、segment の横幅 × 行片の高さで塗る。
  private func fill(
    _ ranges: [NSRange], in visible: NSRange, rows: [VisibleLine.Row], color: NSColor
  ) {
    guard let textView, !ranges.isEmpty else { return }
    let start = ranges.partitioningIndex { NSMaxRange($0) > visible.location }
    let manager = textView.textLayoutManager
    color.setFill()
    for range in ranges[start...] {
      guard range.location < NSMaxRange(visible) else { break }
      guard let textRange = NSTextRange(range, in: textView.textContentManager) else { continue }
      manager.enumerateTextSegments(in: textRange, type: .standard) { _, rect, _, _ in
        let row = rows.first { $0.frame.minY <= rect.midY && rect.midY < $0.frame.maxY }
        let band = row?.frame ?? rect
        backingAlignedRect(
          NSRect(x: rect.minX, y: band.minY, width: rect.width, height: band.height),
          options: .alignAllEdgesNearest
        ).fill()
        return true
      }
    }
  }

  /// 区間の行全体（viewport の横幅いっぱい）を塗る。
  private func fillLines(of range: NSRange, rows: [VisibleLine.Row], color: NSColor) {
    guard let textView,
      let textRange = NSTextRange(range, in: textView.textContentManager)
    else { return }
    color.setFill()
    func fillLine(_: NSTextRange?, _ rect: CGRect, _: CGFloat, _: NSTextContainer) -> Bool {
      guard let row = rows.first(where: { $0.frame.minY <= rect.midY && rect.midY < $0.frame.maxY })
      else { return true }
      backingAlignedRect(
        NSRect(x: bounds.minX, y: row.frame.minY, width: bounds.width, height: row.frame.height),
        options: .alignAllEdgesNearest
      ).fill()
      return true
    }
    textView.textLayoutManager.enumerateTextSegments(
      in: textRange, type: .standard, using: fillLine)
  }
}

extension Array {
  /// 述語が false → true に切り替わる最初の index（`self` はその述語で分割済み）。全部 false なら `endIndex`。
  fileprivate func partitioningIndex(where belongsInSecond: (Element) -> Bool) -> Int {
    var low = startIndex
    var high = endIndex
    while low < high {
      let mid = (low + high) / 2
      if belongsInSecond(self[mid]) { high = mid } else { low = mid + 1 }
    }
    return low
  }
}
