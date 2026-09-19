import AppKit

/// 面の地（chrome と同じ veil）。設定パレットで不透明度を変えた直後も追従する（観測して再描画）。焦点の文書の
/// テキスト面の矩形には描かず、同じ色を面に渡して面が敷く（本文の下とガターの上。横スクロールで本文がガターの下を
/// 通っても透けず、veil が二重にならない）。
extension EditorPaneView {
  /// 地の色。透過設定を反映した veil（不透明なら bgBase そのもの）。
  var groundColor: NSColor {
    Theme.Color.bgBase.withAlphaComponent(translucency?.effectiveOpacity ?? 1)
  }

  /// 地を描き直し、焦点の文書の面へ渡す。
  func applyGround() {
    needsDisplay = true
    document?.surface.setGround(groundColor)
  }

  func observeTranslucency() {
    applyGround()
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
    let path = NSBezierPath(rect: dirtyRect)
    let hole = bodyRect.intersection(dirtyRect)
    if document != nil, !hole.isEmpty {
      path.append(NSBezierPath(rect: hole))
      path.windingRule = .evenOdd
    }
    path.fill()
  }
}
