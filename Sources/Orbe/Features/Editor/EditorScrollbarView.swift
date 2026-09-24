import AppKit
import OrbeEditorCore

/// 本体の右端の縦スクロールバー（VS Code と同じ幅 14）。つまみと、その下の印（overview ruler）——git の追加・変更・削除
/// （左レーン）、検索の一致と語の出現（中央レーン）、キャレット（全幅）。焦点の文書 1 つに結ばれ、描くときに文書から読む。
/// 位置と写像は Core の純関数（`ScrollbarGeometry` / `OverviewRuler`）で、ここは面の座標に写すだけ。
///
/// つまみは掴んでドラッグでき、トラックを押すとつまみの中央が押した位置に来るよう飛び、そのまま同じ押下でドラッグに移る。
/// つまみは本体にポインタがある間とドラッグ中は見え、スクロールすると現れて、止まってから 500ms 後に 800ms かけて消える
/// （VS Code の `ScrollableElement`）。印は常に見える。
final class EditorScrollbarView: NSView {
  private let style: ScrollbarStyle
  private(set) weak var document: EditorDocument?
  /// 検索の一致と語の出現（pane が束ねて押す）。
  var decorations = OverviewDecorations.empty {
    didSet { if decorations != oldValue { needsDisplay = true } }
  }
  /// 本体の上にポインタがある（pane の tracking area が置く）。
  var hovering = false {
    didSet {
      guard hovering != oldValue else { return }
      if hovering { reveal() } else { hide() }
    }
  }
  /// スクロールが止まってからつまみを消し始めるまでの予約。
  let hideDelay = EditorDelay()
  private(set) var geometry: ScrollbarGeometry?
  /// つまみが見えている（見える向きのアニメーションに入った）。
  private(set) var isThumbShown = false
  private let thumb = ThumbView()
  private var drag: (startY: CGFloat, geometry: ScrollbarGeometry)?
  private let dragScroll = DragScroll()
  private var tracking: NSTrackingArea?

  init(style: ScrollbarStyle) {
    self.style = style
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    isHidden = true
    thumb.alphaValue = 0
    thumb.color = style.slider
    addSubview(thumb)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  func bind(_ document: EditorDocument?) {
    self.document = document
    drag = nil
    isHidden = document == nil
    refresh()
  }

  /// viewport・選択・ハンク・本文が変わった。
  func refresh() {
    updateGeometry()
    needsDisplay = true
  }

  /// 本文がスクロールした。つまみを見せ、止まれば消す予約をする。
  func didScroll() {
    reveal()
  }

  override func layout() {
    super.layout()
    updateGeometry()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsDisplay = true
  }

  private func updateGeometry() {
    guard let document else { return }
    let (first, visible) = document.viewportLines
    let geometry = ScrollbarGeometry(
      lineCount: document.lineIndex.lineCount, firstLine: first, visibleLines: visible,
      height: bounds.height)
    self.geometry = geometry
    thumb.frame = NSRect(
      x: 0, y: geometry.sliderPosition, width: bounds.width, height: geometry.sliderLength)
    thumb.isHidden = !geometry.isNeeded
    updateThumbColor()
  }

  private func updateThumbColor() {
    thumb.color =
      drag != nil ? style.sliderActive : thumb.isPointerInside ? style.sliderHover : style.slider
  }

  private func reveal() {
    setThumbShown(true)
    guard !hovering, drag == nil else {
      hideDelay.cancel()
      return
    }
    hideDelay.run(after: Theme.Motion.editorScrollbarHideDelay) { [weak self] in self?.hide() }
  }

  private func hide() {
    guard !hovering, drag == nil else { return }
    setThumbShown(false)
  }

  private func setThumbShown(_ shown: Bool) {
    guard shown != isThumbShown else { return }
    isThumbShown = shown
    NSAnimationContext.runAnimationGroup { context in
      context.duration =
        shown ? Theme.Motion.editorSliderFadeIn : Theme.Motion.editorScrollbarFadeOut
      context.timingFunction = CAMediaTimingFunction(name: .linear)
      thumb.animator().alphaValue = shown ? 1 : 0
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

  override func mouseMoved(with event: NSEvent) {
    let y = convert(event.locationInWindow, from: nil).y
    thumb.isPointerInside = geometry?.sliderContains(y: y) == true
    updateThumbColor()
  }

  override func mouseExited(with event: NSEvent) {
    thumb.isPointerInside = false
    updateThumbColor()
  }

  override func scrollWheel(with event: NSEvent) {
    guard let surface = document?.surface else {
      super.scrollWheel(with: event)
      return
    }
    surface.view.scrollWheel(with: event)
  }

  /// つまみの中なら掴む。トラックならつまみの中央がそこへ来るよう飛び、飛んだ後の状態を起点に同じ押下でドラッグへ移る。
  override func mouseDown(with event: NSEvent) {
    guard let document, var geometry, geometry.isNeeded else { return }
    let y = convert(event.locationInWindow, from: nil).y
    if !geometry.sliderContains(y: y) {
      document.scroll(toFirstLine: geometry.firstLine(centeringSliderAt: y))
      updateGeometry()
      geometry = self.geometry ?? geometry
    }
    drag = (y, geometry)
    reveal()
    updateThumbColor()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let document, let drag else { return }
    let y = convert(event.locationInWindow, from: nil).y
    dragScroll.scroll(
      document, toFirstLine: drag.geometry.firstLine(afterDragging: y - drag.startY))
  }

  override func mouseUp(with event: NSEvent) {
    guard drag != nil else { return }
    dragScroll.flush()
    drag = nil
    mouseMoved(with: event)
    hide()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let document else { return }
    let scale = window?.backingScaleFactor ?? 1
    let index = document.lineIndex
    let (_, visible) = document.viewportLines
    let ruler = OverviewRuler(
      lineCount: index.lineCount, visibleLines: visible, height: bounds.height, scale: scale)
    let marks = LineMarks(hunks: document.hunks)
    let rows = { (lines: Range<Int>) in (lines.lowerBound - 1)...(lines.upperBound - 2) }
    let added = marks.runs.filter { $0.kind == .added }.map { rows($0.lines) }
    let modified = marks.runs.filter { $0.kind == .modified }.map { rows($0.lines) }
    let removed = marks.deletionsBelow.map { max(0, $0 - 1)...max(0, $0 - 1) }
    let groups = [
      MarkGroup(rows: added, lane: .left, color: style.added),
      MarkGroup(rows: modified, lane: .left, color: style.modified),
      MarkGroup(rows: removed, lane: .left, color: style.removed),
      MarkGroup(
        rows: decorations.wordOccurrences.map(index.rows(of:)), lane: .center,
        color: style.wordOccurrence),
      MarkGroup(rows: findRows(index: index), lane: .center, color: style.findMatch),
    ]
    for group in groups where !group.rows.isEmpty {
      let lane = OverviewRuler.lane(group.lane, width: bounds.width, scale: scale)
      group.color.setFill()
      for span in ruler.spans(group.rows) {
        fill(x: lane.x, width: lane.width, span: span, scale: scale)
      }
    }
    let caretRow = index.point(at: document.surface.selectedRange.location).row
    let full = OverviewRuler.lane(.full, width: bounds.width, scale: scale)
    style.caret.setFill()
    fill(x: full.x, width: full.width, span: ruler.caret(row: caretRow), scale: scale)
    style.border.setFill()
    NSRect(x: 0, y: 0, width: 1 / scale, height: bounds.height).fill()
    NSRect(x: 1 / scale, y: 0, width: bounds.width - 1 / scale, height: 1 / scale).fill()
  }

  /// 検索の一致の行。多いときは近い行をまとめた近似に、現在の一致を加える。
  private func findRows(index: LineIndex) -> [ClosedRange<Int>] {
    let rows = decorations.findMatches.map(index.rows(of:))
    guard decorations.approximatesFindMatches else { return rows }
    var result = OverviewRuler.approximate(
      rows, lineCount: index.lineCount, height: bounds.height)
    if let current = decorations.currentFindMatch {
      result.append(index.rows(of: current))
      result.sort { $0.lowerBound < $1.lowerBound }
    }
    return result
  }

  private func fill(x: Int, width: Int, span: OverviewRuler.Span, scale: CGFloat) {
    NSRect(
      x: CGFloat(x) / scale, y: CGFloat(span.y1) / scale, width: CGFloat(width) / scale,
      height: CGFloat(span.y2 - span.y1) / scale
    ).fill()
  }
}

/// 同じ色・同じレーンの印の行（VS Code は色ごとにまとめて描き、接するものを結ぶ）。
private struct MarkGroup {
  let rows: [ClosedRange<Int>]
  let lane: OverviewRuler.Lane
  let color: NSColor
}

/// スクロールバーのつまみ。当たりは持たず（押下はスクロールバーが解く）、色はスクロールバーが状態から選ぶ。
private final class ThumbView: NSView {
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
