import AppKit

/// 器の地。分割中（カードで描くとき）だけ、両カードの外側——器の内側の余白と面と面の間——をタブ行と同じ重ね方
/// （透過時だけ敷く veil ＋ `tabRowBg`）で塗る。カードの下には何も敷かない——両面の地は半透明なので、敷けば分割した
/// 途端に面の色が変わる。器の最背面に置き、当たりは取らない。
final class FaceGroundView: NSView {
  /// カードで描くときの置き方の矩形。nil なら何も塗らない。
  var cards: FaceGeometry.Frames? {
    didSet { if cards != oldValue { needsDisplay = true } }
  }
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

  private func observeTranslucency() {
    guard let translucency else { return }
    withObservationTracking {
      _ = translucency.additiveOpacity
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        self?.needsDisplay = true
        self?.observeTranslucency()
      }
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let cards else { return }
    let radius = Theme.Radius.faceCard
    let ground = NSBezierPath(rect: bounds)
    ground.append(NSBezierPath(roundedRect: cards.editor, xRadius: radius, yRadius: radius))
    ground.append(NSBezierPath(roundedRect: cards.terminal, xRadius: radius, yRadius: radius))
    ground.windingRule = .evenOdd
    Theme.Color.bgBase.withAlphaComponent(translucency?.additiveOpacity ?? 0).setFill()
    ground.fill()
    Theme.Color.tabRowBg.setFill()
    ground.fill()
  }
}
