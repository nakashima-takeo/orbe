import AppKit

/// `BrowserLayerView` のイベント判定（`hitTest`・透かし吸収）・キー分類・ドラッグリサイズ処理。
extension BrowserLayerView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, frame.contains(point) else { return nil }
    if mode == .closed { return nil }
    if isPeeking { return self }
    let local = convert(point, from: superview)
    guard sheetView.frame.contains(local) else { return nil }
    let hit = super.hitTest(point)
    if !emptyOverlay.isHidden, let hit, hit.isDescendant(of: emptyOverlay) {
      return self
    }
    return hit
  }

  override func mouseDown(with event: NSEvent) {
    guard !isPeeking else { return }
    focusBrowser()
  }

  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
  override func keyDown(with event: NSEvent) {}

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard mode.isOpen, focusIsInside else { return super.performKeyEquivalent(with: event) }
    guard let action = Keybindings.chromeAction(for: event) else {
      return super.performKeyEquivalent(with: event)
    }
    switch action {
    case .toggleBrowser:
      endURLEditingExternally()
      onWindowCommand?(.toggleBrowser)
      return true
    case .nextTab, .prevTab:
      if isEditingURL {
        if event.specialKey == .leftArrow || event.specialKey == .rightArrow {
          return super.performKeyEquivalent(with: event)
        }
        return true
      }
      if let command = action.windowCommand { onWindowCommand?(command) }
      return true
    case .toggleEditorFace, .findInProject, .openEditor:
      if isEditingURL { return true }
      if let command = action.windowCommand { onWindowCommand?(command) }
      return true
    case .rename:
      if isEditingURL { return true }
      reloadPage()
      return true
    case .closeTab,
      .increaseFontSize, .decreaseFontSize, .resetFontSize,
      .saveDocument, .toggleEditorSidebar, .toggleEditorItemList,
      .find:
      return true
    case .scrollToTop, .scrollToBottom:
      return super.performKeyEquivalent(with: event)
    case .showClosedAgentsPalette, .switchWorkspace, .launchDefaultAgent,
      .showAgentPalette, .showWorktreePalette, .showTaskPalette,
      .showSettings, .toggleHelp:
      if isEditingURL { return true }
      if let command = action.windowCommand { onWindowCommand?(command) }
      return true
    }
  }

  // MARK: - ドラッグリサイズ

  func dragDidStart() {
    endURLEditingExternally()
    focusBrowser()
    let session = BrowserResizeSession(initialRatio: sheetRatio, containerWidth: bounds.width)
    resizeSession = session
    snapBadge.kind = session.current.badgeKind
    syncFocusAppearance()
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  func dragDidMove(to pointerX: CGFloat) {
    guard var session = resizeSession else { return }
    let preview = session.update(pointerX: pointerX, containerWidth: bounds.width)
    resizeSession = session
    snapBadge.kind = preview.badgeKind
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  func dragDidEnd(cancelled: Bool) {
    guard let session = resizeSession else { return }
    resizeSession = nil
    snapBadge.kind = nil
    if cancelled {
      sheetRatio = session.startRatio
      needsLayout = true
      layoutSubtreeIfNeeded()
      syncFocusAppearance()
      return
    }
    switch session.commit() {
    case .keepSheet(let ratio):
      sheetRatio = ratio
      self.session.commitSheetRatio(Double(ratio))
      needsLayout = true
      layoutSubtreeIfNeeded()
      syncFocusAppearance()
    case .snapFull(let preserved):
      sheetRatio = preserved
      requestModeChange(.full, animated: true)
    case .close(let preserved):
      sheetRatio = preserved
      requestModeChange(.closed, animated: true)
    }
  }
}

/// hitTest を常に素通しする補助ビュー（左層ベール・右端 Peek ライン用）。
final class BrowserPassthroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 上下反転座標のコンテナ（`belowBar` 用）。
final class BrowserFlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// シート上のホバーを監視する影コンテナ。背景色を持たず影と子ビューの配置のみを担う。
final class BrowserSheetContainerView: NSView {
  var onHoverChange: ((Bool) -> Void)?
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func mouseEntered(with event: NSEvent) {
    onHoverChange?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onHoverChange?(false)
  }
}
