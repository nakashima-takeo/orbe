import AppKit

/// 面の clip の器。中身を面いっぱいに置き、分割中の焦点の印（面のキー色の細い帯）を中身の上辺へ重ねる——
/// 印は場所を取らないので、焦点が移っても中身は動かない。
final class FaceClipView: NSView {
  private let mark = FocusMarkView()
  /// 印の色。nil なら印を出さない。
  var markColor: NSColor? {
    get { mark.color }
    set { mark.color = newValue }
  }

  init(content: NSView) {
    super.init(frame: .zero)
    wantsLayer = true
    clipsToBounds = true
    content.autoresizingMask = []
    addSubview(content)
    addSubview(mark)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    mark.frame = NSRect(x: 0, y: 0, width: newSize.width, height: FaceGeometry.focusBand)
  }
}

/// 焦点の印。中身より手前に重なるが、クリックやドラッグは中身へ通す。
private final class FocusMarkView: NSView {
  var color: NSColor? {
    didSet {
      guard color != oldValue else { return }
      isHidden = color == nil
      needsDisplay = true
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    isHidden = true
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    color?.setFill()
    bounds.fill()
  }
}
