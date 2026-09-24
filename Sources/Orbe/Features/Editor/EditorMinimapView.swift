import AppKit
import OrbeEditorCore

/// 本体の右のミニマップ——文書の字の形を 1 行 2pt・1 字 1pt に縮めて構文の色で描き、見えている範囲の帯を重ねる
/// （VS Code の既定: proportional・帯はホバーで現れる・字を描く）。焦点の文書 1 つに結ばれ、描くときに文書から読む
/// （行数・viewport・選択・ハンク・役割の区間・インデント単位）。「何をどこに描くか」は Core の純関数（`MinimapLayout` /
/// `MinimapLine`）で、ここは面の座標とデバイス px に写すだけ。
///
/// 字はチャンクの画像で覚える（`MinimapChunks`）。帯を掴んでドラッグすると本文が追従し、帯の外を押すとその行が本文の
/// 中央に来る。
final class EditorMinimapView: NSView {
  let style: MinimapStyle
  private(set) weak var document: EditorDocument?
  /// 検索の一致と語の出現（pane が束ねて押す）。
  var decorations = OverviewDecorations.empty {
    didSet { if decorations != oldValue { needsDisplay = true } }
  }
  /// 最後に出した配置（描く・押下を解く・次の配置の揺れ止め）。
  private(set) var placement: MinimapLayout?
  private let slider = SliderView()
  private let chunks: MinimapChunks
  private var hovering = false
  private var drag: (startY: CGFloat, layout: MinimapLayout)?
  private let dragScroll = DragScroll()
  private var tracking: NSTrackingArea?

  /// 覚えているチャンク（テストが捨て方を見る）。
  var cachedChunks: Set<Int> { chunks.cached }
  /// 帯が見えているか（ホバー中かドラッグ中で、帯が要る）。
  var isSliderShown: Bool { (hovering || drag != nil) && placement?.sliderNeeded == true }

  init(style: MinimapStyle) {
    self.style = style
    chunks = MinimapChunks(style: style)
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    // チャンクの画像は列の外（上の骨）へはみ出して置かれる（描き始めの行がチャンクの途中にある）。
    clipsToBounds = true
    isHidden = true
    slider.alphaValue = 0
    addSubview(slider)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  /// 焦点の文書に結ぶ（nil なら隠す）。
  func bind(_ document: EditorDocument?) {
    self.document = document
    chunks.reset(lineCount: document?.lineIndex.lineCount ?? 0)
    placement = nil
    drag = nil
    isHidden = document == nil
    refresh()
  }

  /// viewport・選択・ハンクが変わった。
  func refresh() {
    updateLayout()
    needsDisplay = true
  }

  /// 本文が変わった。変わった行のチャンクを捨てる（→ `MinimapChunks`）。
  func textDidChange(_ change: TextChange) {
    guard let document else { return }
    chunks.textDidChange(change, index: document.lineIndex)
    refresh()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
    updateSlider()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    updateLayout()
  }

  var scale: Int { (window?.backingScaleFactor ?? 1) >= 2 ? 2 : 1 }

  /// 配置を出し直す（直前の配置を揺れ止めに使う——VS Code は直前に描いた配置を渡す）。
  private func updateLayout() {
    guard let document else { return }
    let (first, visible) = document.viewportLines
    placement = MinimapLayout(
      lineCount: document.lineIndex.lineCount, firstLine: first, visibleLines: visible,
      height: bounds.height, previous: placement)
    updateSlider()
  }

  private func updateSlider() {
    guard let layout = placement else { return }
    slider.frame = NSRect(
      x: 0, y: layout.sliderTop, width: bounds.width, height: layout.sliderHeight)
    slider.color =
      drag != nil
      ? style.sliderActive
      : slider.isPointerInside ? style.sliderHover : style.slider
    let shown: CGFloat = isSliderShown ? 1 : 0
    guard slider.alphaValue != shown else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Theme.Motion.editorSliderFadeIn
      context.timingFunction = CAMediaTimingFunction(name: .linear)
      slider.animator().alphaValue = shown
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    mouseMoved(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    slider.isPointerInside = false
    updateSlider()
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    slider.isPointerInside = placement?.sliderContains(y: point.y) == true
    updateSlider()
  }

  /// 俯瞰の上のホイール／トラックパッドは本文のスクロールへそのまま渡す（右端の列がスクロールの死角にならない）。
  override func scrollWheel(with event: NSEvent) {
    guard let scroll = document?.surface.responder.enclosingScrollView else {
      super.scrollWheel(with: event)
      return
    }
    scroll.scrollWheel(with: event)
  }

  /// 帯の中なら掴んでドラッグを始め、帯の外ならその行を本文の中央へ（ドラッグは続かない）。
  override func mouseDown(with event: NSEvent) {
    guard let document, let layout = placement else { return }
    let point = convert(event.locationInWindow, from: nil)
    if layout.sliderContains(y: point.y) {
      drag = (point.y, layout)
      updateSlider()
      return
    }
    let line = layout.line(atY: point.y)
    document.surface.scrollToCenter(document.lineIndex.start(ofRow: line))
  }

  override func mouseDragged(with event: NSEvent) {
    guard let document, let drag else { return }
    let y = convert(event.locationInWindow, from: nil).y
    dragScroll.scroll(document, toFirstLine: drag.layout.firstLine(afterDragging: y - drag.startY))
  }

  override func mouseUp(with event: NSEvent) {
    guard drag != nil else { return }
    dragScroll.flush()
    drag = nil
    mouseMoved(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let document, let layout = placement, let context = NSGraphicsContext.current?.cgContext
    else {
      return
    }
    drawText(layout, document: document, context: context)
    drawDecorations(layout, document: document, context: context)
  }

  /// 字のチャンクを置く（不透明度 0.9。VS Code の canvas の opacity）。
  private func drawText(_ layout: MinimapLayout, document: EditorDocument, context: CGContext) {
    guard !layout.lines.isEmpty else { return }
    let canvas = MinimapChunks.Canvas(
      width: Int(bounds.width * CGFloat(scale)), scale: scale, dark: isDark,
      appearance: effectiveAppearance)
    let first = layout.lines.lowerBound / MinimapChunks.lines
    let last = (layout.lines.upperBound - 1) / MinimapChunks.lines
    chunks.retain(first...last)
    context.saveGState()
    context.setAlpha(style.opacity)
    context.interpolationQuality = .none
    for chunk in first...last {
      guard let image = chunks.image(chunk, document: document, canvas: canvas) else { continue }
      let y = layout.y(ofLine: chunk * MinimapChunks.lines)
      let height = CGFloat(image.height) / CGFloat(scale)
      // flipped の view へ CGImage を上下そのままに描く。
      context.saveGState()
      context.translateBy(x: 0, y: y + height)
      context.scaleBy(x: 1, y: -1)
      context.draw(
        image, in: NSRect(x: 0, y: 0, width: CGFloat(image.width) / CGFloat(scale), height: height))
      context.restoreGState()
    }
    context.restoreGState()
  }

  private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// ミニマップの帯。当たりは持たず（押下はミニマップが解く）、色はミニマップが状態から選ぶ。
private final class SliderView: NSView {
  var color: NSColor = .clear {
    didSet { needsDisplay = true }
  }
  var isPointerInside = false

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    bounds.fill()
  }
}
