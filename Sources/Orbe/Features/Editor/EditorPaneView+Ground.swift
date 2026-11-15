import AppKit

/// 面の地（chrome と同じ veil）。本体を含む全面を層の背景色 1 枚で塗る——テキスト面と俯瞰は地を持たず、その上に描く（veil が
/// 二重にならない）。絵で塗らないのは、面が動く間に帯ごと描き足すと、画素の途中にかかる境の 1px が半透明で残るため。
/// 設定パレットで不透明度を変えた直後も追従する（観測して塗り直す）。
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
    paintDiffDivider()
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = groundColor.cgColor
    }
  }
}
