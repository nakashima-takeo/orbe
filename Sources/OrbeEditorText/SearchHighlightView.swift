import AppKit
import OrbeEditorCore
import STTextView

/// ファイル内検索の一致の地——テキスト view の `contentView` の下（装備の overlay の上）に、可視行と交差する一致の
/// 矩形を角丸で塗る。現在の一致は上に載る選択の地が覆う。当たりを持たず、寸法は viewport で、位置は面が
/// スクロールと layout のたびに置き直す。bounds は text container 基準なので、segment の矩形をそのまま描く。
final class SearchHighlightView: NSView {
  private weak var textView: STTextView?
  private let color: NSColor
  private let radius: CGFloat
  /// 一致（昇順・重ならない。UTF-16）。
  var ranges: [NSRange] = [] {
    didSet { needsDisplay = true }
  }

  init(textView: STTextView, color: NSColor, radius: CGFloat) {
    self.textView = textView
    self.color = color
    self.radius = radius
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let textView, !ranges.isEmpty else { return }
    let lines = VisibleLines(textView: textView).lines(in: bounds)
    guard let first = lines.first, let last = lines.last else { return }
    let visibleEnd = NSMaxRange(last.range)
    let start = ranges.partitioningIndex { NSMaxRange($0) > first.range.location }
    let manager = textView.textLayoutManager
    color.setFill()
    for range in ranges[start...] {
      guard range.location < visibleEnd else { break }
      guard let textRange = NSTextRange(range, in: textView.textContentManager) else { continue }
      manager.enumerateTextSegments(in: textRange, type: .standard) { _, rect, _, _ in
        NSBezierPath(
          roundedRect: backingAlignedRect(rect, options: .alignAllEdgesNearest), xRadius: radius,
          yRadius: radius
        ).fill()
        return true
      }
    }
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
