import AppKit

/// 面の地（chrome と同じ veil）。設定パレットで不透明度を変えた直後も追従する（観測して再描画）。
extension EditorPaneView {
  func observeTranslucency() {
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

  override func draw(_ dirtyRect: NSRect) {
    Theme.Color.bgBase.withAlphaComponent(translucency?.effectiveOpacity ?? 1).setFill()
    dirtyRect.fill()
  }
}
