import AppKit

/// 面の地（chrome と同じ veil）。本体を含む全面を 1 層で塗る——テキスト面と俯瞰は地を持たず、その上に描く（veil が二重に
/// ならない）。設定パレットで不透明度を変えた直後も追従する（観測して再描画）。
extension EditorPaneView {
  /// 地の色。透過設定を反映した veil（不透明なら bgBase そのもの）。
  var groundColor: NSColor {
    Theme.Color.bgBase.withAlphaComponent(translucency?.effectiveOpacity ?? 1)
  }

  func observeTranslucency() {
    needsDisplay = true
    guard let translucency else { return }
    withObservationTracking {
      _ = translucency.effectiveOpacity
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        self?.observeTranslucency()
      }
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    groundColor.setFill()
    bounds.intersection(dirtyRect).fill()
  }
}
