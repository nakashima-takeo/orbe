import AppKit

/// 背: 面の継ぎ目に立つ 14px の帯。隠れた面の印（その面のキー色のグラデとグリフ）か、両面が
/// 見えているときのグリップを描く。動かさずに離せばクリック、4px 動けばドラッグ（ポインタごとに位置を、
/// 離したことを 1 回）として器へ伝える。
final class SpineView: NSView {
  var look: FaceGeometry.SpineLook = .hidden(.editor) {
    didSet {
      guard look != oldValue else { return }
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Theme.Motion.spineLook
        fade.timingFunction = CAMediaTimingFunction(name: .default)
        layer?.add(fade, forKey: "look")
      }
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
    }
  }
  /// 地の veil。設定パレットで不透明度を変えた直後も追従する（観測して再描画）。
  var translucency: ChromeTranslucency? {
    didSet { observeTranslucency() }
  }
  /// 掴んだ（mouseDown）。器はここで解決結果を凍結し、焦点の面へ first responder を戻す。
  var onGrab: (() -> Void)?
  /// ドラッグ中。`x` は背の左端が来るべき、器の左端からの距離（掴んだ位置のオフセットを引いてある
  /// ので、背の中のどこを掴んでも引いた距離だけ動く）。
  var onDrag: ((CGFloat) -> Void)?
  /// 動かさずに離した。
  var onClick: (() -> Void)?
  /// ドラッグの末に離した。
  var onRelease: (() -> Void)?

  /// 掴んだ位置（器の左端からの x・背の左端からのオフセット）と、閾値を越えて動いたか。
  private struct Grab {
    let x0: CGFloat
    let offset: CGFloat
    var moved = false
  }
  private var drag: Grab?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

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

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsDisplay = true
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: look == .grip ? .resizeLeftRight : .pointingHand)
  }

  // MARK: - 描画

  override func draw(_ dirtyRect: NSRect) {
    Theme.Color.bgBase.withAlphaComponent(translucency?.effectiveOpacity ?? 1).setFill()
    bounds.fill()
    switch look {
    case .grip:
      Theme.Color.faceTerminal.withAlphaComponent(0.07).setFill()
      bounds.fill()
      let bar = NSRect(x: bounds.midX - 1, y: bounds.midY - 11, width: 2, height: 22)
      Theme.Color.faceTerminal.withAlphaComponent(0.55).setFill()
      NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    case .hidden(let face):
      let key = face == .editor ? Theme.Color.faceEditor : Theme.Color.faceTerminal
      // グラデはその面がある側（エディター＝左・端末＝右）へ濃くなる。
      let faint = key.withAlphaComponent(0.04)
      let strong = key.withAlphaComponent(0.14)
      let gradient = NSGradient(
        starting: face == .editor ? strong : faint, ending: face == .editor ? faint : strong)
      gradient?.draw(in: bounds, angle: 0)
      drawGlyph(for: face, color: key.withAlphaComponent(0.85))
    }
  }

  /// 見本 `parts.tsx` のグリフ（viewBox 18・stroke 1.8）を 10px に写す。
  private func drawGlyph(for face: Face, color: NSColor) {
    let size: CGFloat = 10
    let scale = size / 18
    let origin = NSPoint(x: bounds.midX - size / 2, y: bounds.midY - size / 2)
    let transform = AffineTransform(translationByX: origin.x, byY: origin.y)
    var scaled = AffineTransform(scale: scale)
    scaled.append(transform)
    let copy = NSBezierPath()
    copy.append(face == .editor ? Self.fileGlyph : Self.terminalGlyph)
    copy.transform(using: scaled)
    copy.lineWidth = 1.8 * scale
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

  /// `❯_`。
  private static let terminalGlyph: NSBezierPath = {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 4, y: 6))
    p.line(to: NSPoint(x: 7.5, y: 9))
    p.line(to: NSPoint(x: 4, y: 12))
    p.move(to: NSPoint(x: 9.5, y: 12.5))
    p.line(to: NSPoint(x: 14, y: 12.5))
    return p
  }()

  // MARK: - マウス

  private func x(in event: NSEvent) -> CGFloat {
    guard let superview else { return 0 }
    return superview.convert(event.locationInWindow, from: nil).x
  }

  override func mouseDown(with event: NSEvent) {
    let x0 = x(in: event)
    drag = Grab(x0: x0, offset: x0 - frame.minX)
    onGrab?()
  }

  override func mouseDragged(with event: NSEvent) {
    guard var d = drag else { return }
    let x = x(in: event)
    if !d.moved {
      guard abs(x - d.x0) >= FaceGeometry.dragThreshold else { return }
      d.moved = true
      drag = d
    }
    onDrag?(x - d.offset)
  }

  override func mouseUp(with event: NSEvent) {
    guard let d = drag else { return }
    drag = nil
    if d.moved { onRelease?() } else { onClick?() }
  }
}
