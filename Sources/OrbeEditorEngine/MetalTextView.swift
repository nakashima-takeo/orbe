import AppKit
import QuartzCore

/// 新しい面の view。`CAMetalLayer` を裏打ちの層に持つ layer-backed の view で、描き直しの方針は `.never`——画面には層の
/// 中身（描画スレッドが出した drawable）だけが出て、AppKit はライブリサイズ中も含めて `draw(_:)` を呼ばない。
/// `cacheDisplay`（gallery・flow の撮影）では `draw(_:)` が呼ばれるので、描画スレッドが同じ 1 コマを画面外に描いた絵を
/// 描く——撮り方を変えずに新しい面を撮れる。
///
/// 出来事の入口。キーは `interpretKeyEvents` で IME と macOS のキー割り当て（利用者の DefaultKeyBinding を含む）に通し、
/// IME の呼び出しは面の編集係の IME の入口へ（→ `MetalTextView+Input`）、届いた標準のセレクタは編集のコマンドへ写す
/// （→ `MetalTextView+Commands`）。マウスは `MouseSelection` が持ち、変換中はまず IME へ渡す。クリップボード・サービス・
/// 右クリックは `MetalTextView+Pasteboard`、ドラッグ＆ドロップは `MetalTextView+Drag`。
final class MetalTextView: TextSurfaceInputView {
  weak var surface: MetalTextSurface? {
    didSet {
      pointer.surface = surface
      overview.surface = surface
    }
  }
  private var observers: [NSObjectProtocol] = []
  let pointer = MouseSelection()
  /// 俯瞰の押下・ドラッグ・ホバー。
  let overview = OverviewPointer()
  /// 入力の仕組みとの窓口（面が持つ）。テストは偽の IME に差し替える。
  lazy var textInputContext: NSTextInputContext? = NSTextInputContext(client: self)
  /// 写す・貼るペーストボード（既定は一般）。テストは名前つきの専用のものに差し替える。
  var pasteboard = NSPasteboard.general
  /// この面から始めた本文のドラッグで運んでいる範囲（ドラッグの間だけ）。
  var draggedRange: NSRange?
  /// ドラッグ中の自動スクロールの前の刻みの時刻。
  var dropScrollTime: CFTimeInterval?
  /// 置いた落とす位置の印。
  var shownDrop: Int?
  /// サービスに平文を送り・受けられると、アプリで 1 回だけ届け出た。
  @MainActor private static var registeredServices = false

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    // 大きさが変わった直後のコマは伸ばさず左上寄せで出し（AppKit が反転を考えて層の contentsGravity へ写す）、縮んだ
    // ときの古い大きな drawable を面の外（隣のミニマップ・ペイン）へはみ出させない。
    layerContentsPlacement = .topLeft
    clipsToBounds = true
    let overviewHits = OverviewHitView()
    overviewHits.autoresizingMask = [.width, .height]
    addSubview(overviewHits)
    registerForDraggedTypes([.string, .fileURL])
    if !Self.registeredServices {
      Self.registeredServices = true
      NSApp?.registerServicesMenuSendTypes([.string], returnTypes: [.string])
    }
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
  override var inputContext: NSTextInputContext? { textInputContext }
  override var composing: Bool { surface?.editor.isComposing ?? false }

  /// IME が ⌘ キーの間に確定と次の未確定を続けて返しても、描くのは 1 状態だけ。
  override func offerKeyEquivalentToInputMethod(_ event: NSEvent) -> Bool {
    guard composing, let surface else { return false }
    var used = false
    surface.input { used = super.offerKeyEquivalentToInputMethod(event) }
    return used
  }

  // MARK: - 大きさ・倍率・見えているか

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    stateDidChange()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    stateDidChange()
  }

  /// 窓の覆われ方（見えているか）と key の出入り（焦点）、システムの色の変化（アクセント色が選択の色を変える）、点滅しない
  /// 挿入ポイントの設定を見る。押して
  /// いる間に窓から外れると mouse-up は届かない（文書の切り替えが面を外す）ので、ここでマウスの操作を終える。
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    guard let newWindow else {
      pointer.cancel()
      surface?.inputScope { overview.cancel() }
      surface?.editor.finishComposition(.commit)
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
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.reduceMotionDidChange() }
      })
    if let blinking = CaretBlinking.didChangeNotification {
      let changed: @Sendable (Notification) -> Void = { [weak self] _ in
        MainActor.assumeIsolated { self?.surface?.setCaretBlinks(CaretBlinking.systemPreference) }
      }
      observers.append(
        NotificationCenter.default.addObserver(
          forName: blinking, object: nil, queue: .main, using: changed))
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { surface?.attachDisplayLink(to: self) }
    reduceMotionDidChange()
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

  /// 変換中はまず IME へ渡す（IME が使わなければ、クリックの入口が変換を確定する）。俯瞰の上の押下は俯瞰が受ける
  /// （テキストの選択・ドラッグ＆ドロップは始まらない。窓からは焦点を取らない子 `OverviewHitView` を経て届く）。
  override func mouseDown(with event: NSEvent) {
    if composing, inputContext?.handleEvent(event) == true { return }
    let point = convert(event.locationInWindow, from: nil)
    surface?.input {
      if overview.mouseDown(at: point) { return }
      pointer.mouseDown(event, in: self)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    if composing, inputContext?.handleEvent(event) == true { return }
    let point = convert(event.locationInWindow, from: nil)
    surface?.input {
      if overview.mouseDragged(to: point) { return }
      pointer.mouseDragged(event, in: self)
    }
  }

  override func mouseUp(with event: NSEvent) {
    if composing, inputContext?.handleEvent(event) == true { return }
    let point = convert(event.locationInWindow, from: nil)
    surface?.input {
      if overview.mouseUp(at: point) { return }
      pointer.mouseUp(event, in: self)
    }
  }

  /// ポインタの形と、本体の上のポインタ（つまみの見え隠れと帯・つまみの濃さ）。ドラッグ中も出入りを受ける——つまみを
  /// 押したまま本体の外で離せば、つまみが消える。
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [
          .cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
          .enabledDuringMouseDrag,
        ],
        owner: self))
  }

  override func cursorUpdate(with event: NSEvent) {
    pointer.updateCursor(at: event.locationInWindow, flags: event.modifierFlags, in: self)
  }

  override func mouseMoved(with event: NSEvent) {
    pointer.updateCursor(at: event.locationInWindow, flags: event.modifierFlags, in: self)
    hover(event, inside: true)
  }

  override func mouseEntered(with event: NSEvent) {
    hover(event, inside: true)
  }

  override func mouseExited(with event: NSEvent) {
    hover(event, inside: false)
  }

  private func hover(_ event: NSEvent, inside: Bool) {
    let point = convert(event.locationInWindow, from: nil)
    surface?.inputScope { overview.pointerMoved(to: point, inside: inside) }
  }

  /// 動きを減らす設定を俯瞰へ写す。
  private func reduceMotionDidChange() {
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    surface?.inputScope { overview.setReduceMotion(reduce) }
  }

  override func flagsChanged(with event: NSEvent) {
    guard let window else { return super.flagsChanged(with: event) }
    pointer.updateCursor(
      at: window.mouseLocationOutsideOfEventStream, flags: event.modifierFlags, in: self)
    super.flagsChanged(with: event)
  }

  /// 打鍵を IME と macOS のキー割り当てに通す。1 打鍵を 1 つの取引にし、処理の終わりで出す——セレクタが 2 つ届く打鍵（⌥↓・⌃O・利用者の
  /// DefaultKeyBinding の連続セレクタ）も、IME が「確定 → 次の未確定」を続けて呼ぶ打鍵も、呼び出しごとの状態はその場で
  /// 更新し、描くのは打鍵の後の 1 状態だけ。打鍵の時刻は取引が材料へ添える（打鍵→画面の遅れ）。
  override func keyDown(with event: NSEvent) {
    surface?.input(keystroke: event.timestamp) { interpretKeyEvents([event]) }
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      surface?.focusDidChange(true)
      focusStateDidChange()
    }
    return result
  }

  /// 焦点を失う前に変換を確定する（窓が key でなくなるだけなら変換は続く）。
  override func resignFirstResponder() -> Bool {
    surface?.editor.finishComposition(.commit)
    let result = super.resignFirstResponder()
    if result {
      surface?.focusDidChange(false)
      surface?.updateFocus(false)
    }
    return result
  }
}
