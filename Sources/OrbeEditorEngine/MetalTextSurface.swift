import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// `TextSurface` の Metal 実装（main 側）。本文を持たず、文書の写し（本文・役割・版）を契約の口（`surfaceContent`）で
/// 引いて描く側。main がするのは「出来事をスクロールの状態の箱に書く」「写しと見え方を描く材料の箱に置く」だけで、組版も
/// 描画も描画スレッドが行う。写しは自分の欄に持たず、要るとき（`viewport` の計算・行の印の行への写像）は箱から読む。
///
/// 今は読むだけ——打鍵・選択の描画・キャレット・IME・⌘クリック・強調の地・コピー・アクセシビリティは持たない。選択と強調は
/// 値を受け取るだけで描かない。
@MainActor
final class MetalTextSurface: TextSurface {
  private static var nextID = 0

  let id: Int
  let config: SurfaceConfig
  let material = MaterialBox()
  let scroll: ScrollBox
  private let style: TextSurfaceStyle
  private let textView = MetalTextView()

  var view: NSView { textView }
  var responder: NSView { textView }
  weak var delegate: TextSurfaceDelegate? {
    didSet { pullContent() }
  }
  var onOpenLink: ((URL) -> Void)?
  private(set) var viewport = TextViewport.empty
  var selectedRange = NSRange(location: 0, length: 0) {
    didSet {
      if selectedRange != oldValue { delegate?.surfaceDidChangeSelection(self) }
    }
  }
  var caretLocation: Int { NSMaxRange(selectedRange) }
  /// 面の大きさ（pt）。
  private var size = CGSize.zero

  init(style: TextSurfaceStyle, options: MetalTextSurfaceOptions) {
    Self.nextID += 1
    id = Self.nextID
    self.style = style
    config = SurfaceConfig(
      style: style, fontSmoothing: options.fontSmoothing, omittedLabel: options.omittedLabel)
    scroll = ScrollBox(elastic: options.elasticScroll)
    textView.surface = self
    let id = id
    let material = material
    let scroll = scroll
    let config = config
    let notify: @Sendable () -> Void = { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.scrollDidAdvance() }
      }
    }
    RenderThread.shared.perform { renderer in
      renderer.attach(id: id, material: material, scroll: scroll, config: config, notify: notify)
    }
    appearanceDidChange()
  }

  deinit {
    let id = id
    RenderThread.shared.perform { $0.detach(id) }
  }

  // MARK: - 写しと材料

  /// 文書の写しを引いて箱に置く（結ばれたとき・役割が変わったとき・自分が出した編集から戻ったとき）。`remeasure` なら
  /// 最も長い行をこの写しで測り直す。
  private func pullContent(marks spans: LineMarkSpans? = nil, remeasure: Bool = false) {
    guard let delegate else { return }
    let content = delegate.surfaceContent(self)
    if remeasure { scroll.remeasure(from: content.version) }
    let marks = spans.map { RowMarks($0, in: content.text) }
    material.update {
      $0.content = content
      if let marks { $0.marks = marks }
    }
    updateLimits()
    wake()
    refreshViewport()
  }

  func rolesDidChange(_ ranges: IndexSet) {
    pullContent()
  }

  /// 印は文書がオフセットで押してくる。引いた写しで行へ写してから箱に置く。
  func setLineMarks(_ spans: LineMarkSpans) {
    pullContent(marks: spans)
  }

  func setIndentUnit(_ unit: Int) {
    material.update { $0.tabColumns = unit }
    wake()
  }

  func setHighlights(_ ranges: [NSRange], for kind: TextHighlightKind) {}

  func markUndoBoundary() {}

  /// 本文を丸ごと置き換える編集を文書へ渡し、戻ったら写しを引く。最も長い行は、新しい写しを描いたコマで測り直す
  /// （横の位置はそれまで保ち、新しい幅の範囲に収める）。
  func replaceAll(with text: String) {
    guard let delegate, let content = material.read().content else { return }
    let caret = selectedRange.location
    delegate.surface(
      self,
      didChange: TextEdit(
        range: NSRange(location: 0, length: content.text.length), replacement: text))
    pullContent(remeasure: true)
    let length = material.read().content?.text.length ?? 0
    selectedRange = NSRange(location: min(caret, length), length: 0)
  }

  /// 外観で色を解き直して置く。
  func appearanceDidChange() {
    let palette = FramePalette(
      style: style, appearance: textView.effectiveAppearance, fontSmoothing: config.fontSmoothing)
    material.update { $0.palette = palette }
    wake()
  }

  /// view の大きさ・倍率・見えているかが変わった。
  func viewStateDidChange(size: CGSize, scale: CGFloat, visible: Bool) {
    self.size = size
    material.update {
      $0.size = size
      $0.scale = scale
      $0.visible = visible
    }
    updateLimits()
    wake()
    refreshViewport()
  }

  /// view が窓に載った。view の display link を描画スレッドの run loop に載せる（初めて載ったときだけ）。
  func attachDisplayLink(to view: MetalTextView) {
    guard !hasDisplayLink, let layer = view.metalLayer else { return }
    hasDisplayLink = true
    let link = Transfer(
      value: view.displayLink(
        target: DisplayLinkTarget(id: id), selector: #selector(DisplayLinkTarget.step(_:))))
    let target = Transfer(value: layer)
    let id = id
    RenderThread.shared.perform { renderer in
      renderer.bind(
        id, target: LayerTarget(layer: target.value), clock: DisplayLinkClock(link: link.value))
    }
  }

  private var hasDisplayLink = false

  private func wake() {
    let id = id
    RenderThread.shared.perform { $0.wake(id) }
  }

  private func updateLimits() {
    let lineCount = material.read().content?.text.lineCount ?? 1
    let viewport = SIMD2(
      Double(size.width - config.columnWidth(lineCount: lineCount)),
      Double(size.height - config.topInset))
    let lineHeight = Double(config.lineHeight)
    let cell = Double(config.cell)
    scroll.updateLimits {
      $0.lineCount = lineCount
      $0.lineHeight = lineHeight
      $0.viewport = viewport
      $0.cell = cell
    }
  }

  // MARK: - スクロール

  func scrollWheel(_ event: NSEvent) {
    scroll(ScrollInput(event))
  }

  /// スクロールの出来事を箱に書き、描画スレッドを起こし、見えている範囲をその場で知らせる。
  func scroll(_ input: ScrollInput) {
    guard scroll.apply(input) else { return }
    wake()
    refreshViewport()
  }

  /// 描画スレッドだけが変える位置と範囲（端への戻り・組んだ行で伸びた横の範囲）が変わった。
  private func scrollDidAdvance() {
    refreshViewport()
  }

  func scroll(toTop offset: Int, hiddenFraction: CGFloat) {
    guard let text = material.read().content?.text else { return }
    let row = text.row(containing: offset)
    let fraction = Double(min(max(0, hiddenFraction), 1))
    let now = scroll.peek(at: CACurrentMediaTime()).position
    place(SIMD2(now.x, (Double(row) + fraction) * Double(config.lineHeight)))
  }

  /// 行を見えている高さの中央へ置き、それから列が横に見えるところまで寄せる。
  func scrollToCenter(_ offset: Int) {
    guard let text = material.read().content?.text else { return }
    let location = min(max(0, offset), text.length)
    let row = text.row(containing: location)
    let lineHeight = Double(config.lineHeight)
    let (now, limits) = scroll.peek(at: CACurrentMediaTime())
    place(SIMD2(now.x, Double(row) * lineHeight + lineHeight / 2 - limits.viewport.y / 2))
    scrollToVisible(NSRange(location: location, length: 0))
  }

  /// 区間が見えるところまで最小限スクロールする（縦に見えていれば縦は動かず、横に隠れていれば横だけ寄る）。
  func scrollToVisible(_ range: NSRange) {
    guard let content = material.read().content else { return }
    let text = content.text
    let rows = text.rows(of: range)
    let lineHeight = Double(config.lineHeight)
    let (now, limits) = scroll.peek(at: CACurrentMediaTime())
    let visible = limits.viewport
    var p = now
    let top = Double(rows.lowerBound) * lineHeight
    let bottom = Double(rows.upperBound + 1) * lineHeight
    if top < p.y || bottom - top > visible.y {
      p.y = top
    } else if bottom > p.y + visible.y {
      p.y = bottom - visible.y
    }
    let (source, start) = LineShaper.source(row: rows.lowerBound, in: text)
    let tabWidth = config.tabWidth(columns: material.read().tabColumns)
    let shaped = LineShaper.shape(source, font: config.font, tabWidth: tabWidth)
    scroll.noteLine(width: Double(shaped.width))
    let x0 = Double(
      LineShaper.x(
        ofOffset: range.location - start, in: source, font: config.font, tabWidth: tabWidth))
    let x1 =
      rows.lowerBound == rows.upperBound
      ? Double(
        LineShaper.x(
          ofOffset: NSMaxRange(range) - start, in: source, font: config.font, tabWidth: tabWidth))
      : x0
    if x0 < p.x || x1 - x0 > visible.x {
      p.x = x0
    } else if x1 > p.x + visible.x {
      p.x = x1 - visible.x
    }
    place(p)
  }

  /// その場で位置を置く（アニメーションしない）。
  private func place(_ p: SIMD2<Double>) {
    scroll.place(p)
    wake()
    refreshViewport()
  }

  /// 見えている範囲を出し直し、変わっていれば文書へ知らせる（同期）。
  private func refreshViewport() {
    let (position, limits) = scroll.peek(at: CACurrentMediaTime())
    guard let current = measureViewport(position: position, limits: limits), current != viewport
    else { return }
    viewport = current
    delegate?.surfaceDidChangeViewport(self)
  }

  /// 見えている範囲。行は y = 行 × 行高で並び、端を越えて見せている分は端で数える。見えている高さが無ければ nil。
  private func measureViewport(position: SIMD2<Double>, limits: ScrollPhysics.Limits)
    -> TextViewport?
  {
    guard limits.viewport.y > 0, let text = material.read().content?.text else { return nil }
    let lineHeight = limits.lineHeight
    let maximum = limits.maximum
    let x = min(max(0, position.x), maximum.x)
    let y = min(max(0, position.y), maximum.y)
    let row = min(Int((y / lineHeight).rounded(.down)), text.lineCount - 1)
    let hidden = min(max((y - Double(row) * lineHeight) / lineHeight, 0), 1)
    let cell = Double(config.cell)
    return TextViewport(
      firstVisible: text.lineStart(row), hiddenFraction: CGFloat(hidden),
      visibleLines: CGFloat(limits.viewport.y / lineHeight),
      clipsRight: x < maximum.x - 0.5 / Double(textView.window?.backingScaleFactor ?? 2),
      hiddenColumns: CGFloat(x / cell), visibleColumns: CGFloat(max(0, limits.viewport.x) / cell))
  }

  // MARK: - 焦点と撮影

  func focusDidChange(_ focused: Bool) {
    delegate?.surface(self, focusDidChange: focused)
  }

  /// 今の位置の 1 コマを画面外に描いた絵（撮影）。描画スレッドの仕事の完了を待つ。
  func snapshot() -> CGImage? {
    let id = id
    return RenderThread.shared.performAndWait { Transfer(value: $0.snapshot(id)) }.value
  }
}
