import AppKit
import QuartzCore

/// 新しい面の view。`CAMetalLayer` を裏打ちの層に持つ layer-backed の view で、描き直しの方針は `.never`——画面には層の
/// 中身（描画スレッドが出した drawable）だけが出て、AppKit はライブリサイズ中も含めて `draw(_:)` を呼ばない。
/// `cacheDisplay`（gallery・flow の撮影）では `draw(_:)` が呼ばれるので、描画スレッドが同じ 1 コマを画面外に描いた絵を
/// 描く——撮り方を変えずに新しい面を撮れる。
///
/// 出来事の入口。キーは `interpretKeyEvents` で macOS のキー割り当て（利用者の DefaultKeyBinding を含む）に通し、届いた
/// 標準のセレクタを編集のコマンドへ写す（→ `MetalTextView+Commands`）。マウスは `MouseSelection` が持つ。
final class MetalTextView: NSView {
  weak var surface: MetalTextSurface? {
    didSet { pointer.surface = surface }
  }
  private var observers: [NSObjectProtocol] = []
  let pointer = MouseSelection()

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
    // 字の縁は Core Graphics と同じく色空間の値のまま（線形にせず）合成するので、_srgb の形式にしない。
    layer.pixelFormat = .bgra8Unorm
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

  /// 窓の覆われ方（見えているか）と key の出入り（焦点）、システムの色の変化（アクセント色が選択の色を変える）を見る。押して
  /// いる間に窓から外れると mouse-up は届かない（文書の切り替えが面を外す）ので、ここでマウスの操作を終える。
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    guard let newWindow else {
      pointer.cancel()
      return
    }
    let names: [Notification.Name] = [
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
    ]
    let changed: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated {
        self?.stateDidChange()
        self?.focusStateDidChange()
      }
    }
    observers = names.map {
      NotificationCenter.default.addObserver(
        forName: $0, object: newWindow, queue: nil, using: changed)
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.surface?.appearanceDidChange() }
      })
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { surface?.attachDisplayLink(to: self) }
    stateDidChange()
    focusStateDidChange()
  }

  /// 焦点（first responder で、窓が key）を面へ写す。
  func focusStateDidChange() {
    guard let window else {
      surface?.updateFocus(false)
      return
    }
    surface?.updateFocus(window.firstResponder === self && window.isKeyWindow)
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

  /// 大きさ・倍率・描く色空間・見えているかを drawable と面へ写す。
  ///
  /// 描く色空間は窓の色空間（既定は窓が載る画面の色空間）にする。AppKit は今の面をこの色空間で描くので、同じ色空間で色を
  /// 解き、字の縁を合成し、絵文字を描けば、画面で今の面と同じに見える（別の色空間で描いて層の色合わせに任せると、透ける
  /// 字の縁と絵文字の色がずれる）。窓が別の色空間の画面へ移れば `viewDidChangeBackingProperties` で描き直す。
  private func stateDidChange() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let space =
      window?.colorSpace?.cgColorSpace.flatMap { $0.model == .rgb ? $0 : nil }
      ?? FrameMaterial.defaultSpace
    if let metalLayer {
      metalLayer.contentsScale = scale
      metalLayer.colorspace = space
      metalLayer.drawableSize = CGSize(
        width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }
    let visible =
      window.map { !isHiddenOrHasHiddenAncestor && $0.occlusionState.contains(.visible) } ?? false
    surface?.viewStateDidChange(size: bounds.size, scale: scale, space: space, visible: visible)
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
    surface?.transact { pointer.mouseDown(event, in: self) }
  }

  override func mouseDragged(with event: NSEvent) {
    surface?.transact { pointer.mouseDragged(event, in: self) }
  }

  override func mouseUp(with event: NSEvent) {
    surface?.transact { pointer.mouseUp(event, in: self) }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func cursorUpdate(with event: NSEvent) {
    pointer.updateCursor(at: event.locationInWindow, flags: event.modifierFlags, in: self)
  }

  override func mouseMoved(with event: NSEvent) {
    pointer.updateCursor(at: event.locationInWindow, flags: event.modifierFlags, in: self)
  }

  override func flagsChanged(with event: NSEvent) {
    guard let window else { return super.flagsChanged(with: event) }
    pointer.updateCursor(
      at: window.mouseLocationOutsideOfEventStream, flags: event.modifierFlags, in: self)
    super.flagsChanged(with: event)
  }

  /// 打鍵を macOS のキー割り当てに通す。1 打鍵を 1 つの取引にする——セレクタが 2 つ届く打鍵（⌥↓・⌃O・利用者の
  /// DefaultKeyBinding の連続セレクタ）も、途中の状態のコマを出さない。打鍵の時刻は取引が材料へ添える（打鍵→画面の遅れ）。
  override func keyDown(with event: NSEvent) {
    surface?.transact(keystroke: event.timestamp) { interpretKeyEvents([event]) }
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      surface?.focusDidChange(true)
      focusStateDidChange()
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      surface?.focusDidChange(false)
      surface?.updateFocus(false)
    }
    return result
  }
}
