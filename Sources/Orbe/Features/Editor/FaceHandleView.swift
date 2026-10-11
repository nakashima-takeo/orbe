import AppKit

/// 取っ手: 引き手と継ぎ目を 1 つの物として描く。器が毎フレーム、形の進み具合 `t`（0 = 縁の引き手、1 = 全高の継ぎ目）と
/// 左右（`edgeOnLeft`）、ホバーの進み `hover`（0→1）を書き、取っ手はその値だけから描く——縁から離れるほど高さが伸び、
/// 塗りが継ぎ目の地へ移り、枠と角が消え、グリフが縦棒に替わる。層のアニメーションは使わない（形とホバーは器の時計が進める）。
///
/// 全体が押せる。押せばすぐ「掴んだ」を伝え、閾値を越えて動けば「引いている」、動かさずに離せば「押した」、引いた末に
/// 離せば「離した」を伝える。器が掴みを打ち切ったら（`cancelGrab`）、その後の dragged / up は無視する。引き手が面に
/// 重なった範囲のポインタの形は取っ手が持ち、スクロールは器を通して下の面へ渡す。
final class FaceHandleView: NSView {
  /// 形の進み具合と左右。
  var shape: (edgeOnLeft: Bool, t: CGFloat) = (true, 0) {
    didSet {
      guard shape != oldValue else { return }
      redraw()
    }
  }
  /// ホバーの進み（0 = 普段、1 = ホバー）。
  var hover: CGFloat = 0 {
    didSet {
      guard hover != oldValue else { return }
      redraw()
    }
  }
  /// 継ぎ目の地の veil。設定パレットで不透明度を変えた直後も追従する（観測して再描画）。
  var translucency: ChromeTranslucency? {
    didSet { observeTranslucency() }
  }
  /// 掴んだ。引数は掴んだ点の x（器の座標）。
  var onGrab: ((CGFloat) -> Void)?
  /// 引いている。引数はポインタの x（器の座標）とイベントの時刻。
  var onDrag: ((CGFloat, CFTimeInterval) -> Void)?
  /// 押した（動かさずに離した）。
  var onClick: (() -> Void)?
  /// 引いた末に離した。引数は離した点の x（器の座標）とイベントの時刻。
  var onRelease: ((CGFloat, CFTimeInterval) -> Void)?
  /// ポインタが取っ手の上にあるかが変わった。
  var onPointerOver: ((Bool) -> Void)?
  var onScroll: ((NSEvent) -> Void)?

  private struct Grab {
    let x0: CGFloat
    var moved = false
  }
  private var grab: Grab?
  private(set) var isPointerOver = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.shadowRadius = Theme.Layout.faceNotchShadowRadius
    layer?.shadowOpacity = 0
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
    redraw()
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  /// 縁にいて、引き手として止まっているか（影と指のカーソルはこのときだけ）。
  private var resting: Bool { shape.t < 0.02 }

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    let moved = newOrigin != frame.origin
    super.setFrameOrigin(newOrigin)
    if moved { refreshPointer() }
  }

  override func setFrameSize(_ newSize: NSSize) {
    let resized = newSize != frame.size
    super.setFrameSize(newSize)
    guard resized else { return }
    redraw()
    refreshPointer()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    redraw()
  }

  private func observeTranslucency() {
    guard let translucency else { return }
    withObservationTracking {
      _ = translucency.effectiveOpacity
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        self?.needsDisplay = true
        self?.observeTranslucency()
      }
    }
  }

  /// 形とホバーから、層の不透明度と影を書き、描き直しを求める。
  private func redraw() {
    let ee = shape.t
    let idle = Theme.Opacity.faceNotchRest + (1 - Theme.Opacity.faceNotchRest) * hover
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    alphaValue = idle + (1 - idle) * ee
    updateShadow()
    CATransaction.commit()
    needsDisplay = true
  }

  /// 影は取っ手の形の外へ落ちるので、view の bounds で切れない層の影で描く。縁にいるときだけ、強さはホバーの進み。
  private func updateShadow() {
    guard let layer else { return }
    guard resting else {
      layer.shadowOpacity = 0
      return
    }
    let radius = Theme.Radius.faceNotch * (1 - shape.t)
    layer.shadowPath =
      Self.outline(bounds, radius: radius, edgeOnLeft: shape.edgeOnLeft, closed: true).cgPath
    let offset = Theme.Layout.faceNotchShadowOffset
    layer.shadowOffset = CGSize(width: shape.edgeOnLeft ? offset : -offset, height: 0)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer.shadowColor = Theme.Color.faceNotchShadow.cgColor
    }
    layer.shadowOpacity = Float(hover)
  }

  // MARK: - ポインタ

  /// 窓の hit-test がポインタの点で取っ手に解けるか（重なる chrome の下では持たない）。
  private var pointerIsOver: Bool {
    guard let window else { return false }
    return window.contentView?.hitTest(window.mouseLocationOutsideOfEventStream) === self
  }

  private var cursor: NSCursor {
    if grab?.moved == true || !resting { return .resizeLeftRight }
    return .pointingHand
  }

  override func cursorUpdate(with event: NSEvent) {
    cursor.set()
  }

  override func mouseEntered(with event: NSEvent) {
    setPointerOver(true)
  }

  override func mouseExited(with event: NSEvent) {
    setPointerOver(false)
  }

  /// frame・掴みの終わりのたび、ポインタが上にあるかとカーソルを取り直す——ポインタの下で位置や形が変わっても
  /// enter や cursorUpdate は来ない。
  private func refreshPointer() {
    let over = pointerIsOver
    setPointerOver(over)
    if over || grab?.moved == true { cursor.set() }
  }

  private func setPointerOver(_ value: Bool) {
    guard value != isPointerOver else { return }
    isPointerOver = value
    onPointerOver?(value)
  }

  // MARK: - 描画

  override func draw(_ dirtyRect: NSRect) {
    let ee = shape.t
    let left = shape.edgeOnLeft
    let key = left ? Theme.Color.faceEditor : Theme.Color.faceTerminal
    let notchFill = key.withAlphaComponent(Theme.Opacity.faceNotchFill)
    let hoverFill =
      resting
      ? (left ? Theme.Color.faceNotchEditorHover : Theme.Color.faceNotchTerminalHover)
      : notchFill
    let ground = SeamGroundView.ground(veil: translucency?.effectiveOpacity ?? 1)
    let radius = Theme.Radius.faceNotch * (1 - ee)
    Self.mix(Self.mix(notchFill, hoverFill, hover), ground, ee).setFill()
    Self.outline(bounds, radius: radius, edgeOnLeft: left, closed: true).fill()

    let borderAlpha =
      (Theme.Opacity.faceNotchBorder
        + (Theme.Opacity.faceNotchBorderHover - Theme.Opacity.faceNotchBorder) * hover) * (1 - ee)
    if borderAlpha > 0 {
      // 縁側の辺には枠を引かないので、縁側は内側へ寄せない。
      let inset = Theme.Stroke.hairline / 2
      var rim = bounds.insetBy(dx: 0, dy: inset)
      rim.size.width -= inset
      if !left { rim.origin.x += inset }
      let border = Self.outline(
        rim, radius: max(0, radius - inset), edgeOnLeft: left, closed: false)
      border.lineWidth = Theme.Stroke.hairline
      key.withAlphaComponent(borderAlpha).setStroke()
      border.stroke()
    }

    let glyphAlpha = 1 - min(max(shape.t / 0.5, 0), 1)
    if glyphAlpha > 0 {
      let bright = left ? Theme.Color.faceEditorBright : Theme.Color.faceTerminalBright
      drawGlyph(
        editor: left, color: Self.mix(key, bright, hover).withAlphaComponent(glyphAlpha))
    }

    let barAlpha = min(max((shape.t - 0.5) / 0.5, 0), 1)
    if barAlpha > 0 {
      let size = Theme.Layout.faceSeamBar
      let bar = NSRect(
        x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
        height: size.height)
      Theme.Color.faceTerminal.withAlphaComponent(Theme.Opacity.faceSeamBar * barAlpha).setFill()
      NSBezierPath(
        roundedRect: bar, xRadius: Theme.Radius.faceSeamBar, yRadius: Theme.Radius.faceSeamBar
      ).fill()
    }
  }

  /// 2 色を RGBA（sRGB・非事前乗算）で線形補間する。
  private static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    guard t > 0 else { return a }
    guard t < 1 else { return b }
    let ca = a.usingColorSpace(.sRGB) ?? a
    let cb = b.usingColorSpace(.sRGB) ?? b
    func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
    return NSColor(
      srgbRed: lerp(ca.redComponent, cb.redComponent),
      green: lerp(ca.greenComponent, cb.greenComponent),
      blue: lerp(ca.blueComponent, cb.blueComponent),
      alpha: lerp(ca.alphaComponent, cb.alphaComponent))
  }

  /// 縁側の 2 角は直角、反対側の 2 角は丸めた輪郭。`closed` でなければ縁側の辺を引かない。
  private static func outline(
    _ r: NSRect, radius: CGFloat, edgeOnLeft: Bool, closed: Bool
  ) -> NSBezierPath {
    let edgeX = edgeOnLeft ? r.minX : r.maxX
    let farX = edgeOnLeft ? r.maxX : r.minX
    let p = NSBezierPath()
    p.move(to: NSPoint(x: edgeX, y: r.minY))
    if radius > 0 {
      p.appendArc(
        from: NSPoint(x: farX, y: r.minY), to: NSPoint(x: farX, y: r.maxY), radius: radius)
      p.appendArc(
        from: NSPoint(x: farX, y: r.maxY), to: NSPoint(x: edgeX, y: r.maxY), radius: radius)
    } else {
      p.line(to: NSPoint(x: farX, y: r.minY))
      p.line(to: NSPoint(x: farX, y: r.maxY))
    }
    p.line(to: NSPoint(x: edgeX, y: r.maxY))
    if closed { p.close() }
    return p
  }

  /// 見本 `parts.tsx` のグリフ（viewBox 18・stroke 1.8）を `faceNotchGlyph` に写す。
  private func drawGlyph(editor: Bool, color: NSColor) {
    let size = Theme.Layout.faceNotchGlyph
    let scale = size / 18
    let origin = NSPoint(x: bounds.midX - size / 2, y: bounds.midY - size / 2)
    var scaled = AffineTransform(scale: scale)
    scaled.append(AffineTransform(translationByX: origin.x, byY: origin.y))
    let copy = NSBezierPath()
    copy.append(editor ? Self.fileGlyph : Self.terminalGlyph)
    copy.transform(using: scaled)
    copy.lineWidth = 1.8 * scale
    if !editor {
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

  /// 器が掴みを打ち切った（外から配置が来た）。この後の dragged / up は無視する。
  func cancelGrab() {
    grab = nil
  }

  override func mouseDown(with event: NSEvent) {
    let x0 = x(in: event)
    grab = Grab(x0: x0)
    onGrab?(x0)
  }

  override func mouseDragged(with event: NSEvent) {
    guard var g = grab else { return }
    let x = x(in: event)
    if !g.moved {
      guard abs(x - g.x0) >= FaceGeometry.dragThreshold else { return }
      g.moved = true
      grab = g
    }
    NSCursor.resizeLeftRight.set()
    onDrag?(x, event.timestamp)
  }

  override func mouseUp(with event: NSEvent) {
    guard let g = grab else { return }
    grab = nil
    if g.moved {
      onRelease?(x(in: event), event.timestamp)
    } else {
      onClick?()
    }
    refreshPointer()
  }

  override func scrollWheel(with event: NSEvent) {
    onScroll?(event)
  }
}
