import AppKit
import QuartzCore

/// 新しい面の view。`CAMetalLayer` を裏打ちの層に持つ layer-backed の view で、描き直しの方針は `.never`——画面には層の
/// 中身（描画スレッドが出した drawable）だけが出て、AppKit はライブリサイズ中も含めて `draw(_:)` を呼ばない。
/// `cacheDisplay`（gallery・flow の撮影）では `draw(_:)` が呼ばれるので、描画スレッドが同じ 1 コマを画面外に描いた絵を
/// 描く——撮り方を変えずに新しい面を撮れる。
///
/// スクロールの出来事の入口で、焦点を取れる。打鍵・クリックは本文を変えない（読むだけ）。
final class MetalTextView: NSView {
  weak var surface: MetalTextSurface?
  private var occlusionObserver: NSObjectProtocol?

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    // 大きさが変わった直後のコマは伸ばさず左上寄せで出し（AppKit が反転を考えて層の contentsGravity へ写す）、縮んだ
    // ときの古い大きな drawable を面の外（隣のミニマップ・ペイン）へはみ出させない。
    layerContentsPlacement = .topLeft
    clipsToBounds = true
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override func makeBackingLayer() -> CALayer {
    let layer = CAMetalLayer()
    layer.device = RenderThread.device
    layer.pixelFormat = .bgra8Unorm
    layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    layer.framebufferOnly = true
    layer.isOpaque = false
    // 描いてから画面に出るまでを短くする（drawable 2 枚）。
    layer.maximumDrawableCount = 2
    layer.needsDisplayOnBoundsChange = false
    return layer
  }

  var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override var acceptsFirstResponder: Bool { true }

  // MARK: - 大きさ・倍率・見えているか

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    stateDidChange()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    stateDidChange()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    occlusionObserver = nil
    guard let newWindow else { return }
    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: newWindow, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.stateDidChange() }
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { surface?.attachDisplayLink(to: self) }
    stateDidChange()
  }

  override func viewDidHide() {
    super.viewDidHide()
    stateDidChange()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    stateDidChange()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    surface?.appearanceDidChange()
  }

  /// 大きさ・倍率・見えているかを drawable と面へ写す。
  private func stateDidChange() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    if let metalLayer {
      metalLayer.contentsScale = scale
      metalLayer.drawableSize = CGSize(
        width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }
    let visible =
      window.map { !isHiddenOrHasHiddenAncestor && $0.occlusionState.contains(.visible) } ?? false
    surface?.viewStateDidChange(size: bounds.size, scale: scale, visible: visible)
  }

  // MARK: - 撮影

  override func draw(_ dirtyRect: NSRect) {
    guard let image = surface?.snapshot() else { return }
    NSImage(cgImage: image, size: bounds.size).draw(
      in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: nil)
  }

  // MARK: - 出来事

  override func scrollWheel(with event: NSEvent) {
    surface?.scrollWheel(event)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  /// 打鍵は本文を変えない。Esc（`cancelOperation`）だけは上の responder へ渡し、載せる側が使えるようにする。
  override func keyDown(with event: NSEvent) {
    interpretKeyEvents([event])
  }

  override func insertText(_ insertString: Any) {}

  override func doCommand(by selector: Selector) {
    guard selector == #selector(cancelOperation(_:)) else { return }
    nextResponder?.tryToPerform(selector, with: nil)
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { surface?.focusDidChange(true) }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result { surface?.focusDidChange(false) }
    return result
  }
}
