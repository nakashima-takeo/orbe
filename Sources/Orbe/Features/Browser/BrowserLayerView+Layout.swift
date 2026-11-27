import AppKit
import QuartzCore

/// サイドバーの横並び ⇄ 狭幅オーバーレイ幾何の純粋計算。
struct BrowserSidebarLayout: Equatable {
  let isVisible: Bool
  let isOverlay: Bool
  let sidebarFrame: NSRect
  let contentFrame: NSRect
  let scrimFrame: NSRect

  static func compute(belowBounds: NSRect, isSidebarOpen: Bool) -> BrowserSidebarLayout {
    guard isSidebarOpen, belowBounds.width > 0 else {
      return BrowserSidebarLayout(
        isVisible: false, isOverlay: false,
        sidebarFrame: .zero, contentFrame: belowBounds, scrimFrame: .zero)
    }
    let isOverlay = belowBounds.width < Theme.Layout.browserSidebarInlineThreshold
    let sidebarWidth = min(Theme.Layout.browserSidebarWidth, belowBounds.width)
    let sidebarFrame = NSRect(x: 0, y: 0, width: sidebarWidth, height: belowBounds.height)
    if isOverlay {
      return BrowserSidebarLayout(
        isVisible: true, isOverlay: true,
        sidebarFrame: sidebarFrame, contentFrame: belowBounds, scrimFrame: belowBounds)
    }
    let contentFrame = NSRect(
      x: sidebarWidth, y: 0,
      width: max(0, belowBounds.width - sidebarWidth), height: belowBounds.height)
    return BrowserSidebarLayout(
      isVisible: true, isOverlay: false,
      sidebarFrame: sidebarFrame, contentFrame: contentFrame, scrimFrame: .zero)
  }
}

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
    layoutBelowBarSubtree()

    resizeHandle.frame = NSRect(
      x: 0, y: 0, width: Theme.Layout.browserResizeHandleWidth, height: sheetView.bounds.height)
    layoutSnapBadge()
  }

  private func layoutBelowBarSubtree() {
    let sidebarLayout = BrowserSidebarLayout.compute(
      belowBounds: belowBar.bounds, isSidebarOpen: effectiveSidebarOpen)
    contentView.frame = sidebarLayout.contentFrame
    webView?.frame = contentView.bounds
    newTabHost.frame = contentView.bounds
    snapshotOverlay?.frame = contentView.bounds

    sidebarScrim.frame = sidebarLayout.scrimFrame
    sidebarScrim.isHidden = !sidebarLayout.isOverlay
    sidebarContainer.isHidden = !sidebarLayout.isVisible
    sidebarContainer.frame = sidebarLayout.sidebarFrame
    sidebarGround.frame = sidebarContainer.bounds
    sidebarHost.frame = sidebarContainer.bounds
    sidebarBorder.frame = NSRect(
      x: max(0, sidebarContainer.bounds.width - Theme.Stroke.hairline), y: 0,
      width: Theme.Stroke.hairline, height: sidebarContainer.bounds.height)
    sidebarContainer.layer?.shadowPath = CGPath(rect: sidebarContainer.bounds, transform: nil)

    popoverHost.frame = belowBar.bounds
    popoverHost.isHidden = !isPopoverOpen

    if mode.isOpen && !lastLayoutWasSidebarOverlay && sidebarLayout.isOverlay {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.isSidebarOverlay else { return }
        self.reclaimFocusToSelfIfInside(self.contentView)
      }
    }
    lastLayoutWasSidebarOverlay = mode.isOpen && sidebarLayout.isOverlay
    syncSidebarShadow(isOverlay: sidebarLayout.isOverlay)
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

  func currentSheetWidth() -> CGFloat {
    switch mode {
    case .full:
      return bounds.width
    case .sheet:
      if let preview = resizeSession?.current.previewWidth {
        return preview
      }
      return BrowserResizeSession.sheetWidth(ratio: sheetRatio, containerWidth: bounds.width)
    case .closed:
      if case .sheet(let closingWidth?, _) = fade {
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
      needsLayout = true
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
    newTabHost.isHidden = hasNavigated
    popoverHost.isHidden = !isPopoverOpen
    toolbar.isSidebarOpen = effectiveSidebarOpen
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
      sidebarGround.layer?.backgroundColor = Theme.Color.browserSidebarBg.cgColor
      sidebarBorder.layer?.backgroundColor = Theme.Color.browserBarBorder.cgColor
      sidebarScrim.layer?.backgroundColor = Theme.Color.browserSidebarScrim.cgColor
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
    syncSidebarShadow(isOverlay: effectiveSidebarOverlay)
  }

  private func syncSidebarShadow(isOverlay: Bool) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let shadow = Theme.Color.browserSidebarShadow(dark: isDark)
      sidebarContainer.layer?.shadowColor = shadow.color.cgColor
      sidebarContainer.layer?.shadowOffset = shadow.offset
      sidebarContainer.layer?.shadowRadius = shadow.radius
      sidebarContainer.layer?.shadowOpacity = isOverlay ? shadow.opacity : 0
    }
  }

  func showArrowPointer() {
    guard let window, window.isKeyWindow else { return }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    if bounds.contains(point) { NSCursor.arrow.set() }
  }
}
