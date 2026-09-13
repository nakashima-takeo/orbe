import AppKit
import OrbeEditorCore
import STTextView

/// `TextSurface` の STTextView 実装。スクロールビューにテキストビューを載せ、ガター・rendering
/// attribute・delegate・焦点・viewport をこの契約へ写す。undo は STTextView が自前で持つ（打鍵を
/// まとめる coalescing はビュー内部の undo manager にしか無い）。
@MainActor
final class STTextSurface: NSObject, TextSurface {
  /// 上端の余白を持つ器。スクロールビューの contentInsets は使わない——横に浮くガター（floating
  /// subview）が inset を無視して行番号だけ下へずれる（STTextView が FB21059465 として回避している）。
  private let container = FlippedView()
  private let scrollView: NSScrollView
  private let textView: SurfaceTextView

  var view: NSView { container }
  var responder: NSView { textView }
  weak var delegate: TextSurfaceDelegate?
  private(set) var visibleRange = NSRange(location: 0, length: 0)

  var style: TextSurfaceStyle {
    didSet { apply(style) }
  }

  init(style: TextSurfaceStyle, text: String) {
    scrollView = SurfaceTextView.scrollableTextView()
    // swiftlint:disable:next force_cast
    textView = scrollView.documentView as! SurfaceTextView
    self.style = style
    super.init()
    scrollView.autoresizingMask = [.width, .height]
    container.addSubview(scrollView)
    // clear にすると gutter も clear になり、NSVisualEffectView の地が敷かれない（器の veil が透ける）。
    textView.backgroundColor = .clear
    // 本文はガターの右端から始める（既定の 5pt の余白を持たない）。
    textView.textContainer.lineFragmentPadding = 0
    textView.highlightSelectedLine = false
    textView.showsInvisibleCharacters = false
    textView.textDelegate = self
    textView.onFocusChange = { [weak self] focused in
      guard let self else { return }
      delegate?.surface(self, focusDidChange: focused)
    }
    textView.addPlugin(
      ViewportPlugin { [weak self] range in
        guard let self else { return }
        visibleRange = range.map { NSRange($0, in: self.textView.textContentManager) } ?? NSRange()
        delegate?.surfaceDidLayoutViewport(self)
      })
    apply(style)
    textView.text = text
  }

  var text: String { textView.text ?? "" }

  var length: Int {
    NSRange(textView.textContentManager.documentRange, in: textView.textContentManager).length
  }

  func substring(in range: NSRange) -> String {
    guard let textRange = NSTextRange(range, in: textView.textContentManager) else { return "" }
    return textView.textContentManager.attributedString(in: textRange)?.string ?? ""
  }

  func applyHighlights(_ spans: [HighlightSpan], in ranges: IndexSet) {
    let length = self.length
    for range in ranges.rangeView {
      let clamped = NSRange(range).clamped(to: length)
      if clamped.length > 0 { textView.removeRenderingAttribute(.foregroundColor, range: clamped) }
    }
    for span in spans {
      let clamped = span.range.clamped(to: length)
      guard clamped.length > 0, let color = style.roleColors[span.role] else { continue }
      textView.addRenderingAttributes([.foregroundColor: color], range: clamped)
    }
  }

  func markUndoBoundary() {
    textView.breakUndoCoalescing()
  }

  private func apply(_ style: TextSurfaceStyle) {
    textView.font = style.font
    textView.textColor = style.textColor
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = style.lineHeight / Self.naturalLineHeight(of: style.font)
    textView.defaultParagraphStyle = paragraph
    textView.insertionPointColor = style.caretColor
    textView.caretSize = style.caretSize
    scrollView.frame = container.bounds.insetBy(top: style.topInset)
    textView.showsLineNumbers = true
    if let gutter = textView.gutterView {
      gutter.font = style.gutterFont
      gutter.textColor = style.gutterTextColor
      gutter.insets = STRulerInsets(leading: 0, trailing: style.gutterTrailingInset)
      gutter.minimumThickness = style.gutterWidth
      gutter.drawSeparator = false
      gutter.highlightSelectedLine = false
    }
  }

  /// フォントの自然な行高（TextKit が行フラグメントに与える、丸めた高さ）。行高の固定値をこれで割った
  /// 倍率を渡す。
  private static func naturalLineHeight(of font: NSFont) -> CGFloat {
    NSLayoutManager().defaultLineHeight(for: font)
  }
}

private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

extension NSRect {
  fileprivate func insetBy(top: CGFloat) -> NSRect {
    NSRect(x: minX, y: minY + top, width: width, height: max(0, height - top))
  }
}

extension STTextSurface: @preconcurrency STTextViewDelegate {
  func textView(
    _ textView: STTextView, didChangeTextIn affectedCharRange: NSTextRange,
    replacementString: String
  ) {
    let range = NSRange(affectedCharRange, in: textView.textContentManager)
    delegate?.surface(
      self, didChange: TextEdit(range: range, replacementLength: replacementString.utf16.count))
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    delegate?.surfaceDidChangeSelection(self)
  }

  func textViewInsertionPointView(_ textView: STTextView, frame: CGRect)
    -> (any STInsertionPointIndicatorProtocol)?
  {
    CaretIndicatorView(frame: frame, size: style.caretSize, color: style.caretColor)
  }
}

/// first responder の出入りを契約へ上げるための STTextView。
private final class SurfaceTextView: STTextView {
  var onFocusChange: ((Bool) -> Void)?
  var caretSize = CGSize(width: 1, height: 14)

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { onFocusChange?(true) }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result { onFocusChange?(false) }
    return result
  }
}

/// viewport のレイアウト完了を受けるプラグイン。
private struct ViewportPlugin: STPlugin {
  let onLayout: (NSTextRange?) -> Void

  func setUp(context: any Context) {
    context.events.onDidLayoutViewport(onLayout)
  }
}

extension NSRange {
  fileprivate func clamped(to length: Int) -> NSRange {
    let start = min(max(0, location), length)
    let end = min(max(start, NSMaxRange(self)), length)
    return NSRange(location: start, length: end - start)
  }
}
