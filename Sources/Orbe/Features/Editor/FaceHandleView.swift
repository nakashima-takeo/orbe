import AppKit

/// 取っ手: 片面が隠れているときは隠れた側の縁に重なる引き手、分割中は継ぎ目（面と面の間そのもの。縦中央に 3 つの点）
/// を描く。形と frame は器が決める。引き手の重なった範囲の押す・引く・ポインタの形は取っ手が持ち、スクロールは器を
/// 通して下の面へ渡す。ホバーは乗っている間と、引いている間に効く。
///
/// 押せるのは引き手と、間の 3 つの点の周りだけ。そこで押せばすぐ「掴んだ」を伝え、動かさずに離せば「押した」を伝える。
/// 間の他の部分は閾値を越えて動くまで器に何も伝えない——押して離しても配置も焦点も変わらない。
final class FaceHandleView: NSView {
  var look: FaceGeometry.HandleLook = .notch(.editor) {
    didSet {
      guard look != oldValue else { return }
      hovering = pointerIsOver || grab?.moved == true
      needsDisplay = true
      updateShadowShape()
      setShadow(visible: showsShadow, duration: 0)
      animateOpacity(from: 0, to: restAlpha, duration: Theme.Motion.faceHandleLook)
      refreshPointer()
    }
  }
  /// 掴んだ。引数は掴んだ点の x（器の座標）。
  var onGrab: ((CGFloat) -> Void)?
  /// 引いている。引数はポインタの x（器の座標）。
  var onDrag: ((CGFloat) -> Void)?
  /// 押した（動かさずに離した）。
  var onClick: (() -> Void)?
  /// 引いた末に離した。
  var onRelease: (() -> Void)?
  var onScroll: ((NSEvent) -> Void)?

  private struct Grab {
    let x0: CGFloat
    let pressable: Bool
    var moved = false
  }
  private var grab: Grab?
  private var hovering = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.shadowRadius = Theme.Layout.faceNotchShadowRadius
    layer?.shadowOpacity = 0
    alphaValue = restAlpha
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  private var isNotch: Bool {
    if case .notch = look { return true }
    return false
  }

  private var restAlpha: CGFloat {
    isNotch && !hovering ? Theme.Opacity.faceNotchRest : 1
  }

  private var showsShadow: Bool { isNotch && hovering }

  /// 継ぎ目のうち押せる範囲（縦中央、3 つの点の周り）。
  private var pressRect: NSRect {
    let height = Theme.Layout.faceSeamPress
    return NSRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)
  }

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    let moved = newOrigin != frame.origin
    super.setFrameOrigin(newOrigin)
    if moved { refreshPointer() }
  }

  override func setFrameSize(_ newSize: NSSize) {
    let resized = newSize != frame.size
    super.setFrameSize(newSize)
    guard resized else { return }
    needsDisplay = true
    updateShadowShape()
    refreshPointer()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
    updateShadowShape()
  }

  // MARK: - ポインタ

  /// 窓の hit-test がポインタの点で取っ手に解けるか（重なる chrome の下では持たない）。
  private var pointerIsOver: Bool {
    guard let window else { return false }
    return window.contentView?.hitTest(window.mouseLocationOutsideOfEventStream) === self
  }

  private var cursor: NSCursor {
    if grab?.moved == true { return .resizeLeftRight }
    return isNotch ? .pointingHand : .resizeLeftRight
  }

  override func cursorUpdate(with event: NSEvent) {
    cursor.set()
  }

  override func mouseEntered(with event: NSEvent) {
    setHovering(true)
  }

  override func mouseExited(with event: NSEvent) {
    setHovering(grab?.moved == true)
  }

  /// 見え方・frame・掴みの終わりのたび、ホバーとカーソルを取り直す——ポインタの下で形や位置が変わっても
  /// enter や cursorUpdate は来ない。
  private func refreshPointer() {
    let over = pointerIsOver
    setHovering(over || grab?.moved == true)
    if over || grab?.moved == true { cursor.set() }
  }

  private func setHovering(_ value: Bool) {
    guard value != hovering else { return }
    hovering = value
    let duration = reduceMotion ? 0 : Theme.Motion.quick
    if duration > 0 {
      let fade = CATransition()
      fade.type = .fade
      fade.duration = duration
      layer?.add(fade, forKey: "hover")
    }
    needsDisplay = true
    setShadow(visible: showsShadow, duration: duration)
    animateOpacity(from: nil, to: restAlpha, duration: duration)
  }

  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  // MARK: - 層の不透明度と影

  /// 不透明度を `to` にする。`from` が nil なら今見えている値から動かす。
  private func animateOpacity(from: CGFloat?, to: CGFloat, duration: Double) {
    let shown = CGFloat(layer?.presentation()?.opacity ?? Float(alphaValue))
    alphaValue = to
    guard let layer, duration > 0, !reduceMotion else {
      layer?.removeAnimation(forKey: "opacity")
      return
    }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from ?? shown
    animation.toValue = to
    animation.duration = duration
    animation.timingFunction = CAMediaTimingFunction(name: .default)
    layer.add(animation, forKey: "opacity")
  }

  private func setShadow(visible: Bool, duration: Double) {
    guard let layer else { return }
    let shown = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
    layer.shadowOpacity = visible ? 1 : 0
    guard duration > 0 else {
      layer.removeAnimation(forKey: "shadow")
      return
    }
    let animation = CABasicAnimation(keyPath: "shadowOpacity")
    animation.fromValue = shown
    animation.toValue = layer.shadowOpacity
    animation.duration = duration
    layer.add(animation, forKey: "shadow")
  }

  /// 影は引き手の形の外へ落ちるので、view の bounds で切れない層の影で描く。
  private func updateShadowShape() {
    guard let layer else { return }
    guard case .notch(let face) = look else {
      layer.shadowPath = nil
      return
    }
    let edgeOnLeft = face == .editor
    layer.shadowPath =
      Self.notchOutline(
        bounds, radius: Theme.Radius.faceNotch, edgeOnLeft: edgeOnLeft, closed: true
      )
      .cgPath
    let offset = Theme.Layout.faceNotchShadowOffset
    layer.shadowOffset = CGSize(width: edgeOnLeft ? offset : -offset, height: 0)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer.shadowColor = Theme.Color.faceNotchShadow.cgColor
    }
  }

  // MARK: - 描画

  override func draw(_ dirtyRect: NSRect) {
    switch look {
    case .notch(let face): drawNotch(face)
    case .seam: drawSeam()
    }
  }

  private func drawNotch(_ face: Face) {
    let editor = face == .editor
    let key = editor ? Theme.Color.faceEditor : Theme.Color.faceTerminal
    let radius = Theme.Radius.faceNotch
    let fill =
      hovering
      ? (editor ? Theme.Color.faceNotchEditorHover : Theme.Color.faceNotchTerminalHover)
      : key.withAlphaComponent(Theme.Opacity.faceNotchFill)
    fill.setFill()
    Self.notchOutline(bounds, radius: radius, edgeOnLeft: editor, closed: true).fill()
    // 縁側の辺には枠を引かないので、縁側は内側へ寄せない。
    let inset = Theme.Stroke.hairline / 2
    var rim = bounds.insetBy(dx: 0, dy: inset)
    rim.size.width -= inset
    if !editor { rim.origin.x += inset }
    let border = Self.notchOutline(rim, radius: radius - inset, edgeOnLeft: editor, closed: false)
    border.lineWidth = Theme.Stroke.hairline
    key.withAlphaComponent(
      hovering ? Theme.Opacity.faceNotchBorderHover : Theme.Opacity.faceNotchBorder
    ).setStroke()
    border.stroke()
    let glyph =
      hovering ? (editor ? Theme.Color.faceEditorBright : Theme.Color.faceTerminalBright) : key
    drawGlyph(for: face, color: glyph)
  }

  private func drawSeam() {
    if hovering {
      Theme.Color.surface1.setFill()
      bounds.fill(using: .sourceOver)
    }
    let size = Theme.Layout.faceSeamDot
    let pitch = size + Theme.Layout.faceSeamDotSpacing
    let radius = Theme.Radius.faceSeamDot
    let color =
      hovering
      ? Theme.Color.faceSeamDotHover
      : Theme.Color.faceTerminal.withAlphaComponent(Theme.Opacity.faceSeamDot)
    color.setFill()
    for step in -1...1 {
      let dot = NSRect(
        x: bounds.midX - size / 2, y: bounds.midY - size / 2 + CGFloat(step) * pitch,
        width: size, height: size)
      NSBezierPath(roundedRect: dot, xRadius: radius, yRadius: radius).fill()
    }
  }

  /// 縁側の 2 角は直角、反対側の 2 角は丸めた引き手の輪郭。`closed` でなければ縁側の辺を引かない。
  private static func notchOutline(
    _ r: NSRect, radius: CGFloat, edgeOnLeft: Bool, closed: Bool
  ) -> NSBezierPath {
    let edgeX = edgeOnLeft ? r.minX : r.maxX
    let farX = edgeOnLeft ? r.maxX : r.minX
    let p = NSBezierPath()
    p.move(to: NSPoint(x: edgeX, y: r.minY))
    p.appendArc(from: NSPoint(x: farX, y: r.minY), to: NSPoint(x: farX, y: r.maxY), radius: radius)
    p.appendArc(from: NSPoint(x: farX, y: r.maxY), to: NSPoint(x: edgeX, y: r.maxY), radius: radius)
    p.line(to: NSPoint(x: edgeX, y: r.maxY))
    if closed { p.close() }
    return p
  }

  /// 見本 `parts.tsx` のグリフ（viewBox 18・stroke 1.8）を `faceNotchGlyph` に写す。
  private func drawGlyph(for face: Face, color: NSColor) {
    let size = Theme.Layout.faceNotchGlyph
    let scale = size / 18
    let origin = NSPoint(x: bounds.midX - size / 2, y: bounds.midY - size / 2)
    var scaled = AffineTransform(scale: scale)
    scaled.append(AffineTransform(translationByX: origin.x, byY: origin.y))
    let copy = NSBezierPath()
    copy.append(face == .editor ? Self.fileGlyph : Self.terminalGlyph)
    copy.transform(using: scaled)
    copy.lineWidth = 1.8 * scale
    if face == .terminal {
      copy.lineCapStyle = .round
      copy.lineJoinStyle = .round
    }
    color.setStroke()
    copy.stroke()
  }

  /// ファイル形（右上を折ったページ）。
  private static let fileGlyph: NSBezierPath = {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 10.5, y: 2.5))
    p.appendArc(from: NSPoint(x: 4.5, y: 2.5), to: NSPoint(x: 4.5, y: 14.5), radius: 1)
    p.appendArc(from: NSPoint(x: 4.5, y: 15.5), to: NSPoint(x: 13.5, y: 15.5), radius: 1)
    p.appendArc(from: NSPoint(x: 13.5, y: 15.5), to: NSPoint(x: 13.5, y: 5.5), radius: 1)
    p.line(to: NSPoint(x: 13.5, y: 5.5))
    p.close()
    p.move(to: NSPoint(x: 10.5, y: 2.5))
    p.line(to: NSPoint(x: 10.5, y: 5.5))
    p.line(to: NSPoint(x: 13.5, y: 5.5))
    return p
  }()

  /// 窓と ❯_（T2）。
  private static let terminalGlyph: NSBezierPath = {
    let p = NSBezierPath(
      roundedRect: NSRect(x: 2.5, y: 3.5, width: 13, height: 11), xRadius: 1, yRadius: 1)
    p.move(to: NSPoint(x: 5.5, y: 7))
    p.line(to: NSPoint(x: 7.5, y: 8.75))
    p.line(to: NSPoint(x: 5.5, y: 10.5))
    p.move(to: NSPoint(x: 9.5, y: 11))
    p.line(to: NSPoint(x: 12.5, y: 11))
    return p
  }()

  // MARK: - マウス

  private func x(in event: NSEvent) -> CGFloat {
    guard let superview else { return 0 }
    return superview.convert(event.locationInWindow, from: nil).x
  }

  private func isPressable(_ event: NSEvent) -> Bool {
    isNotch || pressRect.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseDown(with event: NSEvent) {
    let x0 = x(in: event)
    let pressable = isPressable(event)
    grab = Grab(x0: x0, pressable: pressable)
    if pressable { onGrab?(x0) }
  }

  override func mouseDragged(with event: NSEvent) {
    guard var g = grab else { return }
    let x = x(in: event)
    if !g.moved {
      guard abs(x - g.x0) >= FaceGeometry.dragThreshold else { return }
      g.moved = true
      grab = g
      if !g.pressable { onGrab?(g.x0) }
    }
    NSCursor.resizeLeftRight.set()
    onDrag?(x)
  }

  override func mouseUp(with event: NSEvent) {
    guard let g = grab else { return }
    grab = nil
    if g.moved {
      onRelease?()
    } else if g.pressable {
      onClick?()
    }
    refreshPointer()
  }

  override func scrollWheel(with event: NSEvent) {
    onScroll?(event)
  }
}
