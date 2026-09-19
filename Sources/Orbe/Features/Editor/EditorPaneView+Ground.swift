import AppKit

/// 面の地（chrome と同じ veil）。設定パレットで不透明度を変えた直後も追従する（観測して再描画）。焦点の文書の
/// テキスト面の矩形には描かず、同じ色を面に渡して面が敷く（veil が二重にならない）。俯瞰の列は面の地の上に
/// 描く。穴は幾何の関数なので、文書の出入りと `layout()` のたびに描き直す。
extension EditorPaneView {
  /// 地の色。透過設定を反映した veil（不透明なら bgBase そのもの）。
  var groundColor: NSColor {
    Theme.Color.bgBase.withAlphaComponent(translucency?.effectiveOpacity ?? 1)
  }

  /// 地を描き直し、焦点の文書の面へ渡す（文書の出入り・透過設定の変化）。
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
    let area = bounds.intersection(dirtyRect)
    let path = NSBezierPath(rect: area)
    let hole = surfaceRect.intersection(area)
    if document != nil, !hole.isEmpty {
      path.append(NSBezierPath(rect: hole))
      path.windingRule = .evenOdd
    }
    path.fill()
  }
}
