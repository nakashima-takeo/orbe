import AppKit
import STTextView

/// 幅と高さを固定したキャレット。STTextView は行の高さで枠を渡してくるので、その中で縦に中央へ置く。
/// 色は描画時に解く（名前付き NSColor が外観に追従する）。
final class CaretIndicatorView: NSView, STInsertionPointIndicatorProtocol {
  private let size: CGSize
  private var timer: Timer?

  var insertionPointColor: NSColor {
    didSet { needsDisplay = true }
  }

  init(frame: CGRect, size: CGSize, color: NSColor) {
    self.size = size
    insertionPointColor = color
    super.init(frame: frame)
    autoresizingMask = [.width, .height]
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    insertionPointColor.setFill()
    NSRect(
      x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height
    ).fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  func blinkStart() {
    guard timer == nil else { return }
    isHidden = false
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.isHidden.toggle()
    }
  }

  func blinkStop() {
    timer?.invalidate()
    timer = nil
    isHidden = false
  }

  deinit { timer?.invalidate() }
}
