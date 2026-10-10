import AppKit

/// 継ぎ目の地で自分の bounds を塗る view。器が両面の間の列（形が移る途中に開く幅 0〜取っ手の幅）に置き、取っ手の上下が
/// 窓の奥まで透けないようにする。当たりは取らない。
final class SeamGroundView: NSView {
  /// 透過設定。実効不透明度の変化を観測して描き直す。
  var translucency: ChromeTranslucency? {
    didSet { observeTranslucency() }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsDisplay = true
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

  override func draw(_ dirtyRect: NSRect) {
    Self.ground(veil: translucency?.effectiveOpacity ?? 1).setFill()
    bounds.fill(using: .sourceOver)
  }

  /// 継ぎ目の地: veil（`bgBase` × 透過の実効不透明度）に端末のキー色 α `faceSeamGround` を重ね、1 色に合成した色。
  static func ground(veil: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      var base = NSColor.black
      var ink = NSColor.white
      appearance.performAsCurrentDrawingAppearance {
        base = Theme.Color.bgBase.usingColorSpace(.sRGB) ?? base
        ink = Theme.Color.faceTerminal.usingColorSpace(.sRGB) ?? ink
      }
      let inkAlpha = CGFloat(Theme.Opacity.faceSeamGround)
      let alpha = inkAlpha + veil * (1 - inkAlpha)
      guard alpha > 0 else { return .clear }
      func channel(_ i: CGFloat, _ b: CGFloat) -> CGFloat {
        (i * inkAlpha + b * veil * (1 - inkAlpha)) / alpha
      }
      return NSColor(
        srgbRed: channel(ink.redComponent, base.redComponent),
        green: channel(ink.greenComponent, base.greenComponent),
        blue: channel(ink.blueComponent, base.blueComponent), alpha: alpha)
    }
  }
}
