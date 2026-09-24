import AppKit

/// 本体に重ねる影（受動）——先頭の行が上へ隠れている間の本文の上端の影（VS Code `ScrollDecorationViewPart`: 高さ 6、
/// `box-shadow: 0 6px 6px -6px inset`）と、本文が右にまだ続くときのミニマップ左端の影（`minimap-shadow-visible`:
/// ミニマップの左 6 の帯の外側にぼかし 6 の影）。影の濃さは CSS のぼかし（σ = 3 のガウス）を縦・横の勾配で写す。
final class EditorScrollShadowView: NSView {
  /// 上端の影を出す（先頭行が上へ隠れている）。
  var showsTop = false {
    didSet { if showsTop != oldValue { needsDisplay = true } }
  }
  /// ミニマップの左端の x（この view の座標）。nil なら左の影を出さない。
  var minimapEdge: CGFloat? {
    didSet { if minimapEdge != oldValue { needsDisplay = true } }
  }
  private let topColor: NSColor
  private let edgeColor: NSColor

  /// 影の厚み（CSS の 6px）。
  private static let depth: CGFloat = 6

  init(topColor: NSColor, edgeColor: NSColor) {
    self.topColor = topColor
    self.edgeColor = edgeColor
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    if showsTop {
      // 上端の外側（y < 0）にある影の縁が内へぼける: y での濃さは 0.5·erfc(y / (σ√2))。
      drawGradient(
        context, color: topColor, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: Self.depth),
        clip: NSRect(x: 0, y: 0, width: bounds.width, height: Self.depth))
    }
    if let edge = minimapEdge {
      // 影の帯（edge − 6 … edge）の外側（左）へ広がるぶん。帯の中とその右（ミニマップ）には描かない。
      let band = edge - Self.depth
      drawGradient(
        context, color: edgeColor,
        from: CGPoint(x: band, y: 0), to: CGPoint(x: band - Self.depth * 2, y: 0),
        clip: NSRect(x: band - Self.depth * 2, y: 0, width: Self.depth * 2, height: bounds.height))
    }
  }

  /// `from` から `to` へ、ぼかし 6（σ = 3）の影の縁の濃さで薄れる勾配。
  private func drawGradient(
    _ context: CGContext, color: NSColor, from: CGPoint, to: CGPoint, clip: NSRect
  ) {
    var resolved = color
    effectiveAppearance.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB) ?? color
    }
    let length = hypot(to.x - from.x, to.y - from.y)
    let steps = 8
    var colors: [CGColor] = []
    var locations: [CGFloat] = []
    for step in 0...steps {
      let t = CGFloat(step) / CGFloat(steps)
      let distance = t * length
      let strength = 0.5 * erfc(Double(distance) / (3 * 2.0.squareRoot()))
      colors.append(resolved.withAlphaComponent(resolved.alphaComponent * strength).cgColor)
      locations.append(t)
    }
    guard
      let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
        locations: locations)
    else { return }
    context.saveGState()
    context.clip(to: clip)
    context.drawLinearGradient(gradient, start: from, end: to, options: [])
    context.restoreGState()
  }
}
