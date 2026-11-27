import Foundation

/// `BrowserSession` のプロファイル・スペース・タブ・自動整理・遷移操作。
extension BrowserSession {
  // MARK: - プロファイル・スペース操作

  @discardableResult
  func createProfile(name: String, color: BrowserProfileColor, mcpAllowed: Bool) -> BrowserProfile?
  {
    store.createProfile(name: name, color: color, mcpAllowed: mcpAllowed, now: now()).value
  }

  @discardableResult
  func updateProfile(
    _ id: UUID, name: String, color: BrowserProfileColor, mcpAllowed: Bool
  ) -> BrowserProfile? {
    store.updateProfile(id, name: name, color: color, mcpAllowed: mcpAllowed).value
  }

  /// プロファイル削除の厳密順序:
  /// 対象 WebView 全解放・アンマウント完了 → 隔離キャッシュ解放 → DB 削除（`.persisted` のみ OS ストア削除）。
  @discardableResult
  func deleteProfile(_ profileId: UUID, reassigningTo fallbackProfileId: UUID) -> Bool {
    guard store.profiles.count > 1,
      profileId != fallbackProfileId,
      store.profile(id: profileId) != nil,
      store.profile(id: fallbackProfileId) != nil
    else { return false }

    let spaceIds = Set(store.spaces.filter { $0.profileId == profileId }.map(\.id))
    var targetTabIds = Set(store.tabs.filter { spaceIds.contains($0.spaceId) }.map(\.id))
    for (tabId, runtime) in runtimes where runtime.profileId == profileId {
      targetTabIds.insert(tabId)
    }
    autoreleasepool {
      let detached = detachRuntimes(Array(targetTabIds))
      syncActiveDisplay(allowMaterialize: false)
      invalidateDetachedRuntimes(detached)
      dataStores.releaseCache(for: profileId)
    }

    let result = store.deleteProfile(profileId, reassigningTo: fallbackProfileId, now: now())
    if case .failed = result {
      syncActiveDisplay()
      return false
    }
    syncActiveDisplay()
    if case .persisted = result, !dataStores.isIsolated {
      scheduleDrainPendingStoreRemovals(delay: 0)
    }
    return true
  }

  @discardableResult
  func selectSpace(_ selection: BrowserActiveSpaceSelection) -> Bool {
    guard store.selectSpace(selection).didSucceed else { return false }
    syncVisibilityAndDisplay()
    return true
  }

  @discardableResult
  func createFreeSpace(name: String, icon: BrowserSpaceIcon, profileId: UUID) -> BrowserSpace? {
    store.createFreeSpace(name: name, icon: icon, profileId: profileId, now: now()).value
  }

  @discardableResult
  func updateFreeSpace(_ id: UUID, name: String, icon: BrowserSpaceIcon) -> BrowserSpace? {
    store.updateFreeSpace(id, name: name, icon: icon).value
  }

  @discardableResult
  func setSpaceProfile(_ spaceId: UUID, profileId: UUID) -> Bool {
    guard let existing = store.space(id: spaceId), store.profile(id: profileId) != nil else {
      return false
    }
    if existing.profileId == profileId { return true }
    let tabIds = store.tabs(in: spaceId).map(\.id)
    guard store.setSpaceProfile(spaceId, profileId: profileId).didSucceed else {
      return false
    }
    let detached = detachRuntimes(tabIds)
    syncActiveDisplay()
    invalidateDetachedRuntimes(detached)
    return true
  }

  @discardableResult
  func deleteFreeSpace(_ id: UUID) -> Bool {
    let result = store.deleteFreeSpace(id)
    guard let removedTabIds = result.value else { return false }
    let detached = detachRuntimes(removedTabIds)
    syncVisibilityAndDisplay(touchingLeavingTab: false)
    invalidateDetachedRuntimes(detached)
    return true
  }

  // MARK: - タブ操作・整理・復元

  @discardableResult
  func openTab(
    in spaceId: UUID? = nil,
    section: BrowserTabSection = .today,
    url: URL? = nil,
    title: String = "",
    activate: Bool = true
  ) -> BrowserTab? {
    guard let resolvedSpaceId = spaceId ?? store.activeSpace?.id else { return nil }
    guard
      let created = store.openTab(
        in: resolvedSpaceId, section: section, url: url, title: title, activate: activate,
        now: now()
      ).value
    else { return nil }
    if activate {
      syncVisibilityAndDisplay()
    } else {
      cleaner.recount()
    }
    return created
  }

  @discardableResult
  func selectTab(_ tabId: UUID) -> Bool {
    guard store.selectTab(tabId).didSucceed else { return false }
    syncVisibilityAndDisplay()
    return true
  }

  @discardableResult
  func moveTab(_ tabId: UUID, to section: BrowserTabSection, index: Int? = nil) -> Bool {
    guard store.moveTab(tabId, to: section, index: index, now: now()).didSucceed else {
      return false
    }
    cleaner.recount()
    return true
  }

  @discardableResult
  func closeTab(_ tabId: UUID, recordClosed: Bool = true) -> Bool {
    guard store.closeTab(tabId, recordClosed: recordClosed, now: now()).didSucceed else {
      return false
    }
    let detached = detachRuntimes([tabId])
    syncVisibilityAndDisplay(touchingLeavingTab: false)
    invalidateDetachedRuntimes(detached)
    return true
  }

  @discardableResult
  func clearTodayTabs(in spaceId: UUID? = nil) -> [UUID] {
    guard let resolvedSpaceId = spaceId ?? store.activeSpace?.id,
      let removed = store.clearTodayTabs(in: resolvedSpaceId, now: now()).value
    else { return [] }
    let detached = detachRuntimes(removed)
    syncVisibilityAndDisplay(touchingLeavingTab: false)
    invalidateDetachedRuntimes(detached)
    return removed
  }

  @discardableResult
  func reopenClosedTab(id: Int64? = nil) -> BrowserTab? {
    guard let restored = store.reopenClosedTab(id: id, now: now()).value ?? nil else { return nil }
    syncVisibilityAndDisplay()
    return restored
  }

  @discardableResult
  func sweepExpiredTodayTabs(now currentTime: Date? = nil) -> [UUID] {
    let protected = isBrowserOpen ? visibleTabId : nil
    guard
      let removed = store.pruneExpiredTodayTabs(
        now: currentTime ?? now(), protectedTabId: protected
      ).value
    else { return [] }
    if !removed.isEmpty {
      let detached = detachRuntimes(removed)
      syncVisibilityAndDisplay(touchingLeavingTab: false)
      invalidateDetachedRuntimes(detached)
    }
    return removed
  }

  // MARK: - アクティブタブへの遷移操作

  func load(_ url: URL) {
    let initialURL = BrowserURLInput.isValidHTTPNavigationURL(url) ? url : nil
    guard let runtime = prepareActiveRuntimeForNavigation(initialURL: initialURL) else { return }
    runtime.load(url, notify: false)
    onActiveDisplayChange?(runtime)
    cleaner.recount()
  }

  func loadHTMLString(_ html: String, baseURL: URL?) {
    guard let runtime = prepareActiveRuntimeForNavigation(initialURL: nil) else { return }
    runtime.loadHTMLString(html, baseURL: baseURL, notify: false)
    onActiveDisplayChange?(runtime)
    cleaner.recount()
  }

  private func prepareActiveRuntimeForNavigation(initialURL: URL?) -> BrowserTabRuntime? {
    let tab: BrowserTab
    if let existing = store.activeTab {
      tab = existing
      if existing.url == nil, let initialURL {
        _ = store.updateTabNavigation(existing.id, url: initialURL, title: nil, now: now())
      }
    } else {
      guard let space = store.activeSpace,
        let created = store.openTab(
          in: space.id, section: .today, url: initialURL, activate: true, now: now()
        ).value
      else { return nil }
      tab = created
      if isBrowserOpen { visibleTabId = created.id }
    }
    return ensureRuntime(for: tab)
  }

  func goBack() { activeRuntime?.goBack() }
  func goForward() { activeRuntime?.goForward() }
  func reloadPage() { activeRuntime?.reloadPage() }
  func reloadOrStop() { activeRuntime?.reloadOrStop() }
}
