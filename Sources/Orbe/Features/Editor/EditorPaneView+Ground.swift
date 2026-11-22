import AppKit

/// 面の地（chrome と同じ veil）。上のバーの分とバーより下の分を、それぞれの層の背景色 1 枚で塗る（重ねて塗らない）——テキスト面と
/// 俯瞰は地を持たず、その上に描く（veil が二重にならない）。分けるのは、透かしの間にバーより下の地だけを見えなくするため。絵で
/// 塗らないのは、面が動く間に帯ごと描き足すと、画素の途中にかかる境の 1px が半透明で残るため。設定パレットで不透明度を変えた
/// 直後も追従する（観測して塗り直す）。
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
      let ground = groundColor.cgColor
      barGround.layer?.backgroundColor = ground
      belowGround.layer?.backgroundColor = ground
    }
  }
}
