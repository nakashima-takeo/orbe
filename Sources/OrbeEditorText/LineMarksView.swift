import AppKit
import OrbeEditorCore
import STTextView

/// ガターの overlay——行番号の右の列に git の印を描く。追加・変更は行の高さの 3px バー（続く行は 1 本に
/// 繋げる）、削除はその境に右向きの三角。当たりを持たず（`hitTest` は nil）、寸法は viewport で、位置は面が
/// スクロールと layout のたびに置き直す。bounds の y は文書（text container）基準なので、geometry の y を
/// そのまま描く。
final class LineMarksView: NSView {
  private weak var textView: STTextView?
  private let style: TextSurfaceStyle.Marks
  var spans = LineMarkSpans.empty {
    didSet { needsDisplay = true }
  }

  init(textView: STTextView, style: TextSurfaceStyle.Marks) {
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

  override func draw(_ dirtyRect: NSRect) {
    guard let textView, !spans.isEmpty else { return }
    let geometry = VisibleLines(textView: textView)
    let lines = geometry.lines(in: CGRect(x: 0, y: bounds.minY, width: 1, height: bounds.height))
    guard !lines.isEmpty else { return }
    drawBars(lines)
    drawDeletions(lines, length: geometry.documentLength)
  }

  /// 続く行の同じ印は 1 本のバーに繋げる。
  private struct Bar {
    let kind: LineMarks.Kind
    let minY: CGFloat
    var maxY: CGFloat
  }

  private func drawBars(_ lines: [VisibleLine]) {
    var bars: [Bar] = []
    for line in lines {
      guard
        let mark = spans.marks.first(where: {
          $0.range.location < NSMaxRange(line.range) && NSMaxRange($0.range) > line.range.location
        })
      else { continue }
      let minY = line.frame.minY
      let maxY = line.bodyMaxY
      if let last = bars.last, last.kind == mark.kind, abs(last.maxY - minY) < 0.5 {
        bars[bars.count - 1].maxY = maxY
      } else {
        bars.append(Bar(kind: mark.kind, minY: minY, maxY: maxY))
      }
    }
    for bar in bars {
      color(of: bar.kind).setFill()
      let rect = backingAlignedRect(
        NSRect(
          x: style.barInset, y: bar.minY, width: style.barWidth,
          height: bar.maxY - bar.minY),
        options: .alignAllEdgesNearest)
      NSBezierPath(roundedRect: rect, xRadius: style.barRadius, yRadius: style.barRadius).fill()
    }
  }

  /// 境の y は次の行の上端。末尾（本文の長さ）は、本文が改行で終われば末尾の空行の上端、終わらなければ
  /// 最後の行の下端。先頭の上（0）は上端から下向きに置く。
  private func drawDeletions(_ lines: [VisibleLine], length: Int) {
    style.removed.setFill()
    let size = style.triangleSize
    for boundary in spans.deletions {
      guard
        let y = lines.lazy.compactMap({ line -> CGFloat? in
          if boundary == line.range.location { return line.frame.minY }
          guard boundary == NSMaxRange(line.range), boundary == length else { return nil }
          return line.extraRow?.frame.minY ?? line.bodyMaxY
        }).first
      else { continue }
      let center = max(y, size / 2)
      let path = NSBezierPath()
      path.move(to: NSPoint(x: style.barInset, y: center - size / 2))
      path.line(to: NSPoint(x: style.barInset + size, y: center))
      path.line(to: NSPoint(x: style.barInset, y: center + size / 2))
      path.close()
      path.fill()
    }
  }

  private func color(of kind: LineMarks.Kind) -> NSColor {
    switch kind {
    case .added: return style.added
    case .modified: return style.modified
    }
  }
}
