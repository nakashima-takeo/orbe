import AppKit

/// `BrowserLayerView` のイベント判定（`hitTest`・透かし吸収）・キー単一裁定・ドラッグリサイズ処理。
extension BrowserLayerView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, frame.contains(point) else { return nil }
    if mode == .closed { return nil }
    if isPeeking { return self }
    let local = convert(point, from: superview)
    guard sheetView.frame.contains(local) else { return nil }
    return super.hitTest(point)
  }

  override func mouseDown(with event: NSEvent) {
    guard !isPeeking else { return }
    focusBrowser()
  }

  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}

  override func keyDown(with event: NSEvent) {
    if isPlainEscape(event) {
      if isPopoverOpen {
        closePopover()
        focusBrowser()
        return
      }
      if isSidebarOverlay && !isEditingAnyURL {
        closeSidebarOverlay(focusingBrowser: true)
      }
    }
  }

  override func cancelOperation(_ sender: Any?) {
    if isPopoverOpen {
      closePopover()
      focusBrowser()
      return
    }
    if isSidebarOverlay && !isEditingAnyURL {
      closeSidebarOverlay(focusingBrowser: true)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard mode.isOpen, focusIsInside || isEditingURL else {
      return super.performKeyEquivalent(with: event)
    }
    if let composing = IMEComposition.composingTextView(in: window),
      composing.isDescendant(of: self)
    {
      return super.performKeyEquivalent(with: event)
    }
    if isPlainEscape(event) {
      return handleEscapeKeyEquivalent(event)
    }
    guard let action = Keybindings.chromeAction(for: event) else {
      return super.performKeyEquivalent(with: event)
    }
    return routeChromeAction(action, event: event)
  }

  private func routeChromeAction(_ action: ChromeAction, event: NSEvent) -> Bool {
    switch action.browserRouting {
    case .window(.toggleBrowser):
      closePopover()
      endURLEditingExternally()
      onWindowCommand?(.toggleBrowser)
      return true
    case .browser(let browserAction):
      if isPopoverOpen { return true }
      handleBrowserKeyAction(browserAction)
      return true
    case .window(let command):
      return routeWindowCommand(command, event: event)
    case .block:
      return true
    case .passthrough:
      return super.performKeyEquivalent(with: event)
    }
  }

  private func routeWindowCommand(_ command: WindowCommand, event: NSEvent) -> Bool {
    let isArrow = event.specialKey == .leftArrow || event.specialKey == .rightArrow
    if (command == .nextTab || command == .prevTab) && isArrow {
      if isPopoverOpen {
        return isTextEditorInside(popoverHost) ? super.performKeyEquivalent(with: event) : true
      }
      if isEditingAnyURL {
        return super.performKeyEquivalent(with: event)
      }
    }
    if isPopoverOpen || isEditingAnyURL { return true }
    onWindowCommand?(command)
    return true
  }

  private func handleEscapeKeyEquivalent(_ event: NSEvent) -> Bool {
    if isPopoverOpen {
      closePopover()
      focusBrowser()
      return true
    }
    if isSidebarOverlay && !isEditingAnyURL {
      closeSidebarOverlay(focusingBrowser: true)
      return true
    }
    if isEditingURL && !isTextEditorInside(barHost) {
      cancelURLEditing()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  private func handleBrowserKeyAction(_ action: BrowserKeyAction) {
    switch action {
    case .newTab:
      openNewTab()
    case .closeTab:
      closeActiveTodayTab()
    case .reload:
      guard !isEditingAnyURL else { return }
      reloadPage()
    case .reopenClosedTab:
      reopenClosedTabFromShortcut()
    case .toggleSidebar:
      toggleSidebar()
    }
  }

  private func isPlainEscape(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard modifiers.isEmpty else { return false }
    return event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1B}"
  }

  private func isTextEditorInside(_ container: NSView) -> Bool {
    guard let editor = window?.firstResponder as? NSTextView else { return false }
    return editor.isDescendant(of: container)
  }

  // MARK: - ドラッグリサイズ

  func dragDidStart() {
    closePopover()
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

/// 上下反転座標のコンテナ（`belowBar`・`contentView`・`sidebarContainer` 用）。
final class BrowserFlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// 狭幅オーバーレイサイドバー背面の暗幕。クリックでサイドバーを閉じ、背面への入力貫通を防ぐ。
final class BrowserSidebarScrimView: NSView {
  var onTap: (() -> Void)?

  override func mouseDown(with event: NSEvent) {
    onTap?()
  }

  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
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
