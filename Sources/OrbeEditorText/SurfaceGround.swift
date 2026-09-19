import AppKit

/// ガターの地。ガターの一番下に敷き、面を載せる側が渡した色（面の地と同じ veil）で塗る——横スクロールで本文が
/// ガターの下を通っても透けない。当たりを持たず、寸法は viewport で、位置は面が置き直す。
final class GutterGroundView: NSView {
  var color: NSColor? {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  // macOS 14 以降は view が bounds の外も描けるので、地は bounds に切る（オフスクリーン描画では dirtyRect が
  // 親の全域で来て、兄弟の骨を塗り潰す）。
  override func draw(_ dirtyRect: NSRect) {
    guard let color else { return }
    color.setFill()
    bounds.intersection(dirtyRect).fill()
  }
}

/// 上端の余白を空けてスクロールビューを置く器。器の高さが変わるたびに置き直す（autoresizing は
/// 起点が .zero だと余白を保てず、面が器より余白の分だけ長くなって最下行が切れる）。面の地はここが本文の下に
/// 敷く——ガターが本文の上に敷く矩形（`groundHole`）だけを除いて。同じ色を重ねないので透過の濃度が揃う。
final class SurfaceContainerView: NSView {
  var topInset: CGFloat = 0 {
    didSet { needsLayout = true }
  }
  var ground: NSColor? {
    didSet { needsDisplay = true }
  }
  /// `GutterGroundView` が塗る矩形（器の座標）。
  var groundHole = NSRect.zero {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard let ground else { return }
    ground.setFill()
    let area = bounds.intersection(dirtyRect)
    let path = NSBezierPath(rect: area)
    let hole = groundHole.intersection(area)
    if !hole.isEmpty {
      path.append(NSBezierPath(rect: hole))
      path.windingRule = .evenOdd
    }
    path.fill()
  }

  override func layout() {
    super.layout()
    for subview in subviews {
      subview.frame = NSRect(
        x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
    }
  }
}
