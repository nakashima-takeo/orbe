import AppKit

/// `BrowserLayerView` のサイドバー開閉・狭幅オーバーレイ・ビュー内ポップオーバー・焦点退避・タブ／新タブ操作。
extension BrowserLayerView {
  func wireCallbacks() {
    sheetView.onHoverChange = { [weak self] hovered in
      guard let self, self.isSheetHovered != hovered else { return }
      self.isSheetHovered = hovered
      self.syncFocusAppearance()
    }
    resizeHandle.onDragStart = { [weak self] in self?.dragDidStart() }
    resizeHandle.onDragMove = { [weak self] x in self?.dragDidMove(to: x) }
    resizeHandle.onDragEnd = { [weak self] cancelled in self?.dragDidEnd(cancelled: cancelled) }
    resizeHandle.onDoubleClick = { [weak self] in
      guard let self, self.mode == .sheet else { return }
      self.requestModeChange(.full, animated: true)
    }

    toolbar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
    toolbar.onBack = { [weak self] in
      guard let self else { return }
      self.prepareForToolbarAction(endingURLEditing: true)
      self.goBack()
      self.focusBrowser()
    }
    toolbar.onForward = { [weak self] in
      guard let self else { return }
      self.prepareForToolbarAction(endingURLEditing: true)
      self.goForward()
      self.focusBrowser()
    }
    toolbar.onReloadOrStop = { [weak self] in
      guard let self else { return }
      self.prepareForToolbarAction(endingURLEditing: true)
      self.reloadOrStop()
      self.focusBrowser()
    }
    toolbar.onToggleFull = { [weak self] in
      guard let self else { return }
      self.prepareForToolbarAction(endingURLEditing: true)
      let next: BrowserMode = self.mode == .full ? .sheet : .full
      self.requestModeChange(next, animated: true)
      self.focusBrowser()
    }
    toolbar.onBeginURLEditing = { [weak self] in self?.beginURLEditing() }
    toolbar.onCommitURL = { [weak self] text in self?.commitURLEditing(text) ?? false }
    toolbar.onCancelURL = { [weak self] in self?.cancelURLEditing() }
    toolbar.onBlurURL = { [weak self] in self?.endURLEditingExternally() }
  }

  func wireSidebarAndPopoverCallbacks() {
    sidebarScrim.onTap = { [weak self] in
      self?.closeSidebarOverlay(focusingBrowser: true)
    }

    sidebarActions.onToggleProfilePopover = { [weak self] in self?.toggleProfilePopover() }
    sidebarActions.onSelectTab = { [weak self] tabId in self?.selectTabFromSidebar(tabId) }
    sidebarActions.onCloseTab = { [weak self] tabId in self?.closeTabFromSidebar(tabId) }
    sidebarActions.onTabMenuAction = { [weak self] action, tabId in
      self?.handleTabMenuAction(action, tabId: tabId)
    }
    sidebarActions.onClearToday = { [weak self] spaceId in
      self?.clearTodayTabsFromSidebar(in: spaceId)
    }
    sidebarActions.onOpenNewTab = { [weak self] in self?.openNewTab() }
    sidebarActions.onSelectSpace = { [weak self] selection in
      self?.selectSpaceFromSidebar(selection)
    }
    sidebarActions.onOpenCreateSpace = { [weak self] in
      self?.openPopover(.createSpace)
    }
    sidebarActions.onOpenEditSpace = { [weak self] spaceId, confirmingDelete in
      self?.openPopover(.editSpace(spaceId, confirmingDelete: confirmingDelete))
    }

    popoverModel.onBeforeFormUnmount = { [weak self] in
      guard let self else { return }
      self.reclaimFocusToSelfIfInside(self.popoverHost)
    }
    popoverModel.onDismiss = { [weak self] in
      guard let self else { return }
      self.closePopover()
      self.focusBrowser()
    }

    newTabActions.canFocusInput = { [weak self] in
      guard let self else { return false }
      return self.mode.isOpen && !self.hasNavigated && !self.isPopoverOpen
        && !self.isSidebarOverlay && !self.isEditingURL
    }
    newTabActions.onCommitURL = { [weak self] text in self?.commitNewTabURL(text) ?? false }
    newTabActions.onCancelInput = { [weak self] in self?.cancelNewTabURL() }
    newTabActions.onSelectQuickAccess = { [weak self] tabId in self?.selectQuickAccessTab(tabId) }
    newTabActions.onReopenClosedTab = { [weak self] id in self?.reopenClosedTabFromNewTab(id) }
    newTabActions.onTapBackground = { [weak self] in self?.handleNewTabBackgroundTap() }
  }

  // MARK: - 焦点退避とツールバー前処理

  /// 破棄・被覆されるコンテナ配下に `firstResponder` があれば同期で `BrowserLayerView` 自身へ退避する。
  func reclaimFocusToSelfIfInside(_ container: NSView) {
    guard let responder = window?.firstResponder as? NSView,
      responder === container || responder.isDescendant(of: container)
    else { return }
    window?.makeFirstResponder(self)
  }

  func prepareForToolbarAction(endingURLEditing: Bool) {
    closePopover()
    if endingURLEditing {
      endURLEditingExternally()
    }
  }

  // MARK: - サイドバー開閉と狭幅オーバーレイ

  func toggleSidebar() {
    guard mode.isOpen else { return }
    setSidebarOpen(!isSidebarOpen)
  }

  func setSidebarOpen(_ open: Bool, focusingBrowser: Bool = true) {
    guard mode.isOpen else { return }
    prepareForToolbarAction(endingURLEditing: false)
    guard open != isSidebarOpen else { return }
    if !open {
      reclaimFocusToSelfIfInside(sidebarContainer)
    }
    switch mode {
    case .sheet: sheetSidebarOpen = open
    case .full: fullSidebarOpen = open
    case .closed: return
    }
    toolbar.isSidebarOpen = isSidebarOpen
    if open && isSidebarOverlay {
      reclaimFocusToSelfIfInside(contentView)
    }
    needsLayout = true
    layoutSubtreeIfNeeded()
    if focusingBrowser && !isEditingAnyURL {
      focusBrowser()
    }
  }

  func closeSidebarOverlay(focusingBrowser: Bool) {
    guard isSidebarOverlay else { return }
    setSidebarOpen(false, focusingBrowser: focusingBrowser)
  }

  // MARK: - ビュー内ポップオーバー

  func toggleProfilePopover() {
    if popoverState == .profile {
      closePopover()
      focusBrowser()
    } else {
      openPopover(.profile)
    }
  }

  func openPopover(_ next: BrowserPopoverState) {
    guard mode.isOpen else { return }
    reclaimFocusToSelfIfInside(barHost)
    endURLEditingExternally()
    reclaimFocusToSelfIfInside(contentView)
    reclaimFocusToSelfIfInside(popoverHost)
    popoverModel.state = next
    popoverHost.isHidden = false
    needsLayout = true
    layoutSubtreeIfNeeded()
    focusBrowser()
  }

  func closePopover() {
    guard popoverState != nil else { return }
    reclaimFocusToSelfIfInside(popoverHost)
    popoverModel.state = nil
    popoverHost.isHidden = true
  }

  // MARK: - タブ・スペース・新タブ操作

  func openNewTab() {
    guard mode.isOpen else { return }
    let wasEditing = isEditingAnyURL
    closePopover()
    reclaimFocusToSelfIfInside(barHost)
    endURLEditingExternally()
    if isSidebarOverlay {
      closeSidebarOverlay(focusingBrowser: false)
    }
    guard session.openTab(section: .today, url: nil, activate: true) != nil else {
      if wasEditing { focusBrowser() }
      return
    }
    newTabModel.inputText = ""
    newTabModel.focusToken = max(1, newTabModel.focusToken &+ 1)
  }

  /// `⌘W` 専用: `TODAY` タブのみ閉じ、`PINNED` / `Favorites`・タブ 0 枚時は編集も焦点も変えない真の無動作。
  func closeActiveTodayTab() {
    guard mode.isOpen else { return }
    guard let tab = session.store.activeTab, tab.section == .today else { return }
    closePopover()
    reclaimFocusToSelfIfInside(barHost)
    reclaimFocusToSelfIfInside(newTabHost)
    endURLEditingExternally()
    _ = session.closeTab(tab.id, recordClosed: true)
    focusBrowser()
  }

  /// `⌘⇧T` 専用: 復元可能な履歴が無ければ編集も焦点も変えない真の無動作。
  /// 復元成功時は新タブ画面の一覧クリックと同様に未遷移 `TODAY` 空タブを自動掃除する。
  func reopenClosedTabFromShortcut() {
    guard mode.isOpen else { return }
    guard session.store.nextReopenableClosedTab() != nil else { return }
    let wasEditing = isEditingAnyURL
    closePopover()
    reclaimFocusToSelfIfInside(barHost)
    reclaimFocusToSelfIfInside(newTabHost)
    endURLEditingExternally()
    let emptyTabId = reusableEmptyTodayTabId(excluding: nil)
    guard session.reopenClosedTab() != nil else {
      if wasEditing { focusBrowser() }
      return
    }
    if let emptyTabId {
      _ = session.closeTab(emptyTabId, recordClosed: false)
    }
    focusBrowser()
  }

  func selectTabFromSidebar(_ tabId: UUID) {
    closePopover()
    _ = session.selectTab(tabId)
    if isSidebarOverlay {
      closeSidebarOverlay(focusingBrowser: true)
    } else {
      focusBrowser()
    }
  }

  func closeTabFromSidebar(_ tabId: UUID) {
    closePopover()
    _ = session.closeTab(tabId, recordClosed: true)
    focusBrowser()
  }

  func handleTabMenuAction(_ action: BrowserContextMenu.TabAction, tabId: UUID) {
    closePopover()
    BrowserContextMenu.execute(action, tabId: tabId, on: session)
    focusBrowser()
  }

  func clearTodayTabsFromSidebar(in spaceId: UUID) {
    closePopover()
    _ = session.clearTodayTabs(in: spaceId)
    focusBrowser()
  }

  func selectSpaceFromSidebar(_ selection: BrowserActiveSpaceSelection) {
    closePopover()
    _ = session.selectSpace(selection)
    focusBrowser()
  }

  func commitNewTabURL(_ text: String) -> Bool {
    guard let url = BrowserURLInput.resolve(text) else {
      NSSound.beep()
      return false
    }
    load(url)
    focusBrowser()
    return true
  }

  func cancelNewTabURL() {
    focusBrowser()
  }

  func selectQuickAccessTab(_ tabId: UUID) {
    closePopover()
    let emptyTabId = reusableEmptyTodayTabId(excluding: tabId)
    guard session.selectTab(tabId) else { return }
    if let emptyTabId {
      _ = session.closeTab(emptyTabId, recordClosed: false)
    }
    focusBrowser()
  }

  func reopenClosedTabFromNewTab(_ id: Int64) {
    closePopover()
    let emptyTabId = reusableEmptyTodayTabId(excluding: nil)
    guard session.reopenClosedTab(id: id) != nil else { return }
    if let emptyTabId {
      _ = session.closeTab(emptyTabId, recordClosed: false)
    }
    focusBrowser()
  }

  func handleNewTabBackgroundTap() {
    closePopover()
    endURLEditingExternally()
    focusBrowser()
  }

  private func reusableEmptyTodayTabId(excluding targetId: UUID?) -> UUID? {
    guard let active = session.store.activeTab,
      active.url == nil,
      active.section == .today,
      active.id != targetId
    else { return nil }
    return active.id
  }
}
