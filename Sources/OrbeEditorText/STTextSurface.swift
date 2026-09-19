import AppKit
import OrbeEditorCore
import STTextView

/// `TextSurface` の STTextView 実装。スクロールビューにテキストビューを載せ、ガター・rendering
/// attribute・delegate・焦点・viewport をこの契約へ写す。undo は STTextView が自前で持つ（打鍵を
/// まとめる coalescing はビュー内部の undo manager にしか無い）。
///
/// 行の装備は受動的な overlay 2 枚で描く（ガターの印・本文のインデント線／丸点／URL 下線）。上流に行ごとの
/// 描画の拡張点が無いので、公開の view と TextKit 2 の API だけで載せる。どちらも寸法は viewport
/// （文書の全高にすると数万行で巨大な tiled layer になる）で、layout の収束とスクロールのたびに置き直す
/// ——片方だけでは速いスクロールで印が遅れ、編集で古くなる。
@MainActor
final class STTextSurface: NSObject, TextSurface {
  /// 上端の余白を持つ器。スクロールビューの contentInsets は使わない——横に浮くガター（floating
  /// subview）が inset を無視して行番号だけ下へずれる（STTextView が FB21059465 として回避している）。
  private let container = SurfaceContainerView()
  private let scrollView: NSScrollView
  private let textView: SurfaceTextView
  private let marksView: LineMarksView
  private let decorationView: LineDecorationView
  private var scrollObserver: NSObjectProtocol?

  var view: NSView { container }
  var responder: NSView { textView }
  weak var delegate: TextSurfaceDelegate?
  private(set) var visibleRange = NSRange(location: 0, length: 0)

  private let style: TextSurfaceStyle

  var onOpenLink: ((URL) -> Void)? {
    get { textView.onOpenLink }
    set { textView.onOpenLink = newValue }
  }

  init(style: TextSurfaceStyle, text: String) {
    scrollView = SurfaceTextView.scrollableTextView()
    // swiftlint:disable:next force_cast
    textView = scrollView.documentView as! SurfaceTextView
    self.style = style
    marksView = LineMarksView(textView: textView, style: style.marks)
    decorationView = LineDecorationView(
      textView: textView, style: style.decorations, textColor: style.textColor)
    super.init()
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
        layoutOverlays()
        delegate?.surfaceDidLayoutViewport(self)
      })
    apply(style)
    // 本文の overlay は contentView の下（本文・キャレット・選択の下に出る）。ガターの overlay は
    // ガターの subview で、印の列はガターの右端に錨を置く（上流は桁が増えるとガターを右へ伸ばす）。
    textView.addSubview(decorationView, positioned: .below, relativeTo: nil)
    textView.gutterView?.addSubview(marksView)
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.layoutOverlays() }
    }
    textView.text = text
    decorationView.indentUnit = IndentUnit.detect(in: text)
  }

  deinit {
    if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
  }

  var text: String { textView.text ?? "" }

  private var length: Int {
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

  func setLineMarks(_ spans: LineMarkSpans) {
    marksView.spans = spans
  }

  /// overlay 2 枚を viewport の矩形に置き直して描き直す。ガターの座標は文書の y と同じ（上流は行番号を
  /// 文書の y に置く）ので、どちらも y は可視矩形の上端。
  private func layoutOverlays() {
    let visible = textView.visibleRect
    let gutterWidth = textView.gutterView?.frame.width ?? 0
    decorationView.frame = NSRect(
      x: gutterWidth, y: visible.minY, width: max(0, visible.width - gutterWidth),
      height: visible.height)
    decorationView.needsDisplay = true
    if let gutter = textView.gutterView {
      marksView.frame = NSRect(
        x: gutter.bounds.width - style.marks.gutterWidth, y: visible.minY,
        width: style.marks.gutterWidth, height: visible.height)
      marksView.needsDisplay = true
    }
    textView.window?.invalidateCursorRects(for: textView)
  }

  /// STTextView の置換は undo 登録と `didChangeTextIn` を 1 回ずつ通す（`text` の代入は undo 登録を
  /// 切るので使わない）。置換後の選択は本文の外を指しうるので、元のキャレット位置を新しい長さに収めて置く。
  ///
  /// 変換中（marked text）は置換の**前**に畳む。STTextView 2.4.1 時点: 本文の置換で marked range を捨てず、
  /// 古い本文を指したまま残った range を次の変換操作で force-unwrap する（本文が短くなればクラッシュ、
  /// 長ければ無関係な位置が削れる）。畳むのは 2 つで 1 組——input context に `discardMarkedText()` で
  /// 変換セッションを捨てさせ（これだけでは `hasMarkedText` が消えない）、クライアント側の marked range は
  /// `unmarkText()` で消す。同じ force-unwrap は undo / redo で本文が動くときにも残る（上流の欠陥。ここでは
  /// 塞いでいない）。
  func replaceAll(with text: String) {
    textView.inputContext?.discardMarkedText()
    textView.unmarkText()
    let caret = textView.textSelection.location
    textView.replaceCharacters(in: textView.textLayoutManager.documentRange, with: text)
    textView.textSelection = NSRange(location: min(caret, length), length: 0)
    decorationView.indentUnit = IndentUnit.detect(in: text)
  }

  private func apply(_ style: TextSurfaceStyle) {
    textView.font = style.font
    textView.textColor = style.textColor
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = style.lineHeight / Self.naturalLineHeight(of: style.font)
    textView.defaultParagraphStyle = paragraph
    textView.insertionPointColor = style.caretColor
    textView.caretSize = style.caretSize
    container.topInset = style.topInset
    textView.showsLineNumbers = true
    if let gutter = textView.gutterView {
      gutter.font = style.gutterFont
      gutter.textColor = style.gutterTextColor
      // 行番号は幅 `gutterWidth` の中に右寄せで収まり、その右に印の列が続く。
      gutter.insets = STRulerInsets(
        leading: 0, trailing: style.gutterTrailingInset + style.marks.gutterWidth)
      gutter.minimumThickness = style.gutterWidth + style.marks.gutterWidth
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

/// 上端の余白を空けてスクロールビューを置く器。器の高さが変わるたびに置き直す（autoresizing は
/// 起点が .zero だと余白を保てず、面が器より余白の分だけ長くなって最下行が切れる）。
private final class SurfaceContainerView: NSView {
  var topInset: CGFloat = 0 {
    didSet { needsLayout = true }
  }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    for subview in subviews {
      subview.frame = NSRect(
        x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
    }
  }
}

extension STTextSurface: @preconcurrency STTextViewDelegate {
  func textView(
    _ textView: STTextView, didChangeTextIn affectedCharRange: NSTextRange,
    replacementString: String
  ) {
    let range = NSRange(affectedCharRange, in: textView.textContentManager)
    decorationView.needsDisplay = true
    marksView.needsDisplay = true
    delegate?.surface(
      self, didChange: TextEdit(range: range, replacementLength: replacementString.utf16.count))
  }

  func textViewInsertionPointView(_ textView: STTextView, frame: CGRect)
    -> (any STInsertionPointIndicatorProtocol)?
  {
    CaretIndicatorView(frame: frame, size: style.caretSize, color: style.caretColor)
  }
}

/// first responder の出入りを契約へ上げ、URL の ⌘クリックと ⌘押下中の指カーソルを持つ STTextView。上流の
/// `mouseDown` は shift・control・option を読み ⌘ は読まないので、⌘付きのクリックだけを先取りしても衝突しない。
/// 当たりは描画と同じ geometry（`VisibleLines`）で解く。
private final class SurfaceTextView: STTextView {
  var onFocusChange: ((Bool) -> Void)?
  var onOpenLink: ((URL) -> Void)?
  var caretSize = CGSize(width: 1, height: 14)

  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
      event.clickCount == 1,
      let url = VisibleLines(textView: self).link(at: containerPoint(event.locationInWindow))
    {
      onOpenLink?(url)
      return
    }
    super.mouseDown(with: event)
  }

  /// 指カーソルは ⌘ を押している間だけ。上流はスクロール・編集でカーソル矩形を捨てないので、面が layout の
  /// たびに捨て直す。
  override func resetCursorRects() {
    super.resetCursorRects()
    guard NSEvent.modifierFlags.contains(.command) else { return }
    let gutterWidth = gutterView?.frame.width ?? 0
    let geometry = VisibleLines(textView: self)
    for line in geometry.lines(in: visibleRect.offsetBy(dx: -gutterWidth, dy: 0)) {
      for link in geometry.links(in: line) {
        addCursorRect(link.frame.offsetBy(dx: gutterWidth, dy: 0), cursor: .pointingHand)
      }
    }
  }

  override func flagsChanged(with event: NSEvent) {
    window?.invalidateCursorRects(for: self)
    super.flagsChanged(with: event)
  }

  /// 窓の点を text container 基準へ（本文の矩形はガターの幅ぶん右）。
  private func containerPoint(_ locationInWindow: NSPoint) -> CGPoint {
    let point = convert(locationInWindow, from: nil)
    return CGPoint(x: point.x - (gutterView?.frame.width ?? 0), y: point.y)
  }

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
