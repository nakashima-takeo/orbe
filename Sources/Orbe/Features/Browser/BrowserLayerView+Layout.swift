import AppKit
import QuartzCore

/// `BrowserLayerView` の幾何配置・外観追従・フェードアニメーション。
extension BrowserLayerView {
  private static let fadeKey = "browserFade"

  override func layout() {
    super.layout()
    leftVeilView.frame = bounds
    let railW = Theme.Layout.browserPeekRailWidth
    peekRailView.frame = NSRect(
      x: max(0, bounds.width - railW), y: 0, width: railW, height: bounds.height)

    let sheetWidth = currentSheetWidth()
    sheetView.frame = NSRect(
      x: bounds.width - sheetWidth, y: 0, width: sheetWidth, height: bounds.height)
    sheetView.layer?.shadowPath = CGPath(rect: sheetView.bounds, transform: nil)
    leftBorderLine.frame = NSRect(
      x: -Theme.Stroke.hairline, y: 0, width: Theme.Stroke.hairline,
      height: sheetView.bounds.height)

    let barH = min(Theme.Layout.browserBar, sheetView.bounds.height)
    let barRect = NSRect(x: 0, y: 0, width: sheetWidth, height: barH)
    barGround.frame = barRect
    barHost.frame = barRect

    let belowRect = NSRect(
      x: 0, y: barH, width: sheetWidth, height: max(0, sheetView.bounds.height - barH))
    belowBar.frame = belowRect
    belowGround.frame = belowBar.bounds
    webView?.frame = belowBar.bounds
    emptyOverlay.frame = belowBar.bounds
    snapshotOverlay?.frame = belowBar.bounds

    resizeHandle.frame = NSRect(
      x: 0, y: 0, width: Theme.Layout.browserResizeHandleWidth, height: sheetView.bounds.height)
    layoutSnapBadge()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    syncFocusAppearance()
  }

  private func layoutSnapBadge() {
    snapBadgeHost.isHidden = snapBadge.kind == nil
    if snapBadgeHost.frame != sheetView.bounds {
      snapBadgeHost.frame = sheetView.bounds
    }
  }

  private func currentSheetWidth() -> CGFloat {
    switch mode {
    case .full:
      return bounds.width
    case .sheet:
      if let preview = resizeSession?.current.previewWidth {
        return preview
      }
      return BrowserResizeSession.sheetWidth(ratio: sheetRatio, containerWidth: bounds.width)
    case .closed:
      if case .sheet(let closingWidth?) = fade {
        return min(bounds.width, closingWidth)
      }
      return BrowserResizeSession.sheetWidth(ratio: sheetRatio, containerWidth: bounds.width)
    }
  }

  func runFade(_ target: Fade?, duration: Double, animated: Bool) {
    fadeGeneration += 1
    let layer = target.flatMap(fadeLayer)
    let from = layer.map { $0.presentation()?.opacity ?? $0.opacity }
    sheetView.layer?.removeAnimation(forKey: Self.fadeKey)
    belowBar.layer?.removeAnimation(forKey: Self.fadeKey)
    guard animated, window != nil, !isHiddenOrHasHiddenAncestor, !reduceMotion,
      let target, let layer, let from
    else {
      fade = nil
      applyPresentation()
      return
    }
    fade = target
    applyPresentation()
    let generation = fadeGeneration
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from
    let toValue: Float =
      switch target {
      case .sheet: Float(sheetView.alphaValue)
      case .belowBar: Float(belowBar.alphaValue)
      }
    animation.toValue = toValue
    animation.duration = duration
    let ease = Theme.Motion.easing
    animation.timingFunction = CAMediaTimingFunction(
      controlPoints: Float(ease.p1.x), Float(ease.p1.y), Float(ease.p2.x), Float(ease.p2.y))
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      guard let self, generation == fadeGeneration else { return }
      fade = nil
      applyPresentation()
    }
    layer.add(animation, forKey: Self.fadeKey)
    CATransaction.commit()
  }

  private func fadeLayer(_ kind: Fade) -> CALayer? {
    switch kind {
    case .sheet: sheetView.layer
    case .belowBar: belowBar.layer
    }
  }

  func applyPresentation() {
    sheetView.isHidden = mode == .closed && fade == nil
    sheetView.alphaValue = (mode == .closed || (mode == .sheet && isPeeking)) ? 0 : 1
    belowBar.alphaValue = (mode == .full && isPeeking) ? 0 : 1
    let showSheetChrome = mode == .sheet && !isPeeking
    leftBorderLine.isHidden = !showSheetChrome
    resizeHandle.isHidden = !showSheetChrome
    let showPeekRail = mode == .sheet && isPeeking
    peekRailView.isHidden = !showPeekRail
    peekRailView.alphaValue = showPeekRail ? 1 : 0
    emptyOverlay.isHidden = hasNavigated
    syncFocusAppearance()
  }

  func syncFocusAppearance() {
    let strong = isBrowserFocused || isSheetHovered || resizeSession != nil
    toolbar.isInteractiveFocused = mode == .full || isPeeking || strong
    let showVeil = mode == .sheet && isBrowserFocused && !isPeeking
    leftVeilView.isHidden = !showVeil
    leftVeilView.alphaValue = showVeil ? 1 : 0

    effectiveAppearance.performAsCurrentDrawingAppearance {
      let base = Theme.Color.bgBase.cgColor
      barGround.layer?.backgroundColor = base
      belowGround.layer?.backgroundColor = base
      leftVeilView.layer?.backgroundColor = Theme.Color.browserLeftVeil.cgColor
      peekRailView.layer?.backgroundColor = Theme.Color.browserPeekRail.cgColor
      let borderColor =
        strong ? Theme.Color.browserSheetBorderFocus : Theme.Color.browserSheetBorderSoft
      leftBorderLine.layer?.backgroundColor = borderColor.cgColor

      let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let shadow = Theme.Color.browserShadow(focused: strong, dark: isDark)
      sheetView.layer?.shadowColor = shadow.color.cgColor
      sheetView.layer?.shadowOffset = shadow.offset
      sheetView.layer?.shadowRadius = shadow.radius
      let showShadow = mode == .sheet && !isPeeking
      sheetView.layer?.shadowOpacity = showShadow ? shadow.opacity : 0
      webView?.underPageBackgroundColor = Theme.Color.bgBase
    }
  }

  func showArrowPointer() {
    guard let window, window.isKeyWindow else { return }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    if bounds.contains(point) { NSCursor.arrow.set() }
  }
}
