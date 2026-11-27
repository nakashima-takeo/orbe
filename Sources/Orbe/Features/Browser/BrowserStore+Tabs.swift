import Foundation

/// `BrowserStore` のタブ操作・12 時間自動整理・手動整理・閉じたタブ復元。
extension BrowserStore {
  func openTab(
    in spaceId: UUID,
    section: BrowserTabSection = .today,
    url: URL? = nil,
    title: String = "",
    activate: Bool = true,
    now: Date = Date()
  ) -> BrowserStoreCommitResult<BrowserTab> {
    guard let space = space(id: spaceId) else { return .failed }
    if space.kind == .local && section == .favorite { return .failed }
    if let url, !BrowserURLInput.isValidHTTPNavigationURL(url) { return .failed }
    let instant = BrowserPersistence.storedInstant(now)
    let position = tabs(in: spaceId, section: section).count
    let created = BrowserTab(
      id: UUID(), spaceId: spaceId, section: section, position: position,
      url: url, title: title, createdAt: instant, lastActiveAt: instant)
    let nextSelection: BrowserActiveSpaceSelection? =
      if activate {
        Self.selection(for: space, currentWorkspaceId: currentWorkspaceId)
      } else {
        nil
      }
    return commit { db, draft in
      try db?.insertTab(created, spaceKind: space.kind)
      draft.tabs.append(created)
      if activate {
        try db?.setActiveTab(created.id, in: spaceId)
        draft.activeTabBySpace[spaceId] = created.id
        if let nextSelection, draft.activeSpaceSelection != nextSelection {
          try db?.updateActiveSpace(nextSelection)
          draft.activeSpaceSelection = nextSelection
        }
      }
      return created
    }
  }

  func selectTab(_ tabId: UUID) -> BrowserStoreCommitResult<BrowserTab> {
    guard let tab = tab(id: tabId), let space = space(id: tab.spaceId),
      let nextSelection = Self.selection(for: space, currentWorkspaceId: currentWorkspaceId)
    else { return .failed }
    if activeSpaceSelection == nextSelection && activeTabBySpace[space.id] == tabId {
      return noopResult(tab)
    }
    return commit { db, draft in
      try db?.setActiveTab(tabId, in: space.id)
      draft.activeTabBySpace[space.id] = tabId
      if draft.activeSpaceSelection != nextSelection {
        try db?.updateActiveSpace(nextSelection)
        draft.activeSpaceSelection = nextSelection
      }
      return tab
    }
  }

  /// 対象が `TODAY` タブのときのみ `lastActiveAt` を更新する（同一ミリ秒なら無操作）。
  func touchTabActive(_ tabId: UUID, now: Date = Date()) -> BrowserStoreCommitResult<Void> {
    guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return .failed }
    guard tabs[index].section == .today else { return noopResult(()) }
    let instant = BrowserPersistence.storedInstant(now)
    guard BrowserPersistence.millis(tabs[index].lastActiveAt) != BrowserPersistence.millis(instant)
    else { return noopResult(()) }
    return commit { db, draft in
      try db?.updateTabLastActiveAt(tabId, lastActiveAt: instant)
      draft.tabs[index].lastActiveAt = instant
    }
  }

  func updateTabNavigation(_ tabId: UUID, url: URL, title: String? = nil, now: Date = Date())
    -> BrowserStoreCommitResult<BrowserTab>
  {
    guard BrowserURLInput.isValidHTTPNavigationURL(url),
      let index = tabs.firstIndex(where: { $0.id == tabId })
    else { return .failed }
    let instant = BrowserPersistence.storedInstant(now)
    var updated = tabs[index]
    updated.url = url
    if let title { updated.title = title }
    updated.lastActiveAt = instant
    return commit { db, draft in
      try db?.updateTabNavigation(
        tabId, url: url, title: updated.title, lastActiveAt: updated.lastActiveAt)
      draft.tabs[index] = updated
      return updated
    }
  }

  func updateTabTitle(_ tabId: UUID, title: String) -> BrowserStoreCommitResult<BrowserTab> {
    guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return .failed }
    if tabs[index].title == title { return noopResult(tabs[index]) }
    var updated = tabs[index]
    updated.title = title
    return commit { db, draft in
      try db?.updateTabTitle(tabId, title: title)
      draft.tabs[index] = updated
      return updated
    }
  }

  func moveTab(
    _ tabId: UUID, to targetSection: BrowserTabSection, index: Int? = nil, now: Date = Date()
  ) -> BrowserStoreCommitResult<BrowserTab> {
    guard let moving = tab(id: tabId), let space = space(id: moving.spaceId) else { return .failed }
    if space.kind == .local && targetSection == .favorite { return .failed }
    let sourceSection = moving.section
    let instant = BrowserPersistence.storedInstant(now)
    return commit { db, draft in
      var updated = moving
      updated.section = targetSection
      if sourceSection != targetSection && targetSection == .today {
        updated.lastActiveAt = instant
      }
      if sourceSection == targetSection {
        var list = Self.sectionTabs(in: draft, spaceId: moving.spaceId, section: sourceSection)
          .filter { $0.id != tabId }
        let insertion = min(max(0, index ?? list.count), list.count)
        list.insert(updated, at: insertion)
        try Self.writeSectionOrder(list, db: db, draft: &draft)
      } else {
        let sourceList = Self.sectionTabs(
          in: draft, spaceId: moving.spaceId, section: sourceSection
        )
        .filter { $0.id != tabId }
        var destList = Self.sectionTabs(in: draft, spaceId: moving.spaceId, section: targetSection)
        let insertion = min(max(0, index ?? destList.count), destList.count)
        destList.insert(updated, at: insertion)
        try Self.writeSectionOrder(sourceList, db: db, draft: &draft)
        try Self.writeSectionOrder(destList, db: db, draft: &draft)
      }
      return draft.tabs.first { $0.id == tabId } ?? updated
    }
  }

  func closeTab(_ tabId: UUID, recordClosed: Bool = true, now: Date = Date())
    -> BrowserStoreCommitResult<Void>
  {
    guard let closing = tab(id: tabId) else { return .failed }
    let instant = BrowserPersistence.storedInstant(now)
    let wasActive = activeTabBySpace[closing.spaceId] == tabId
    let nextActiveId =
      wasActive
      ? Self.fallbackActiveTabId(in: memory, spaceId: closing.spaceId, removing: [tabId])
      : nil
    return commit { db, draft in
      try db?.deleteTab(tabId)
      draft.tabs.removeAll { $0.id == tabId }
      let remaining = Self.sectionTabs(
        in: draft, spaceId: closing.spaceId, section: closing.section)
      try Self.writeSectionOrder(remaining, db: db, draft: &draft)
      if wasActive {
        try db?.setActiveTab(nextActiveId, in: closing.spaceId)
        draft.activeTabBySpace[closing.spaceId] = nextActiveId
      }
      if recordClosed, let url = closing.url {
        try recordClosedEntry(
          ClosedTabRecord(
            url: url, title: closing.title, spaceId: closing.spaceId, closedAt: instant),
          db: db, draft: &draft)
      }
    }
  }

  /// 手動整理（`Clear · 12h`）。指定スペースの全 `TODAY` タブを削除し、URL 付きタブを履歴へ積む。
  func clearTodayTabs(in spaceId: UUID, now: Date = Date()) -> BrowserStoreCommitResult<[UUID]> {
    guard space(id: spaceId) != nil else { return .failed }
    let targets = tabs(in: spaceId, section: .today)
    guard !targets.isEmpty else { return noopResult([]) }
    let targetIds = targets.map(\.id)
    let targetSet = Set(targetIds)
    let instant = BrowserPersistence.storedInstant(now)
    let activeLost = activeTabBySpace[spaceId].map(targetSet.contains) ?? false
    let nextActiveId =
      activeLost
      ? Self.fallbackActiveTabId(in: memory, spaceId: spaceId, removing: targetSet)
      : nil
    return commit { db, draft in
      for tab in targets {
        guard let url = tab.url else { continue }
        try recordClosedEntry(
          ClosedTabRecord(url: url, title: tab.title, spaceId: spaceId, closedAt: instant),
          db: db, draft: &draft)
      }
      try db?.deleteTodayTabs(in: spaceId)
      draft.tabs.removeAll { targetSet.contains($0.id) }
      if activeLost {
        try db?.setActiveTab(nextActiveId, in: spaceId)
        draft.activeTabBySpace[spaceId] = nextActiveId
      }
      return targetIds
    }
  }

  /// 最終閲覧・操作から `ttl` 以上経過した `TODAY` タブを全スペースから物理削除する（履歴へは積まない）。
  func pruneExpiredTodayTabs(
    now: Date = Date(), ttl: TimeInterval = todayTabTTL, protectedTabId: UUID?
  ) -> BrowserStoreCommitResult<[UUID]> {
    let instant = BrowserPersistence.storedInstant(now)
    let nowMillis = BrowserPersistence.millis(instant)
    let ttlMillis = Int64((ttl * 1000).rounded())
    let expired = tabs.filter { tab in
      tab.section == .today && tab.id != protectedTabId
        && (nowMillis - BrowserPersistence.millis(tab.lastActiveAt)) >= ttlMillis
    }
    guard !expired.isEmpty else { return noopResult([]) }
    let expiredIds = expired.map(\.id)
    let expiredSet = Set(expiredIds)
    let affectedSpaces = Set(expired.map(\.spaceId))
    let before = memory
    return commit { db, draft in
      for tabId in expiredIds {
        try db?.deleteTab(tabId)
      }
      draft.tabs.removeAll { expiredSet.contains($0.id) }
      for spaceId in affectedSpaces {
        let remainingToday = Self.sectionTabs(in: draft, spaceId: spaceId, section: .today)
        try Self.writeSectionOrder(remainingToday, db: db, draft: &draft)
        if let activeId = draft.activeTabBySpace[spaceId], expiredSet.contains(activeId) {
          let nextId = Self.fallbackActiveTabId(
            in: before, spaceId: spaceId, removing: expiredSet)
          try db?.setActiveTab(nextId, in: spaceId)
          draft.activeTabBySpace[spaceId] = nextId
        }
      }
      return expiredIds
    }
  }

  /// 現在のコンテキストで復元可能な最新の閉じたタブを元スペースの `TODAY` 末尾へ復元し選択する。
  func reopenClosedTab(now: Date = Date()) -> BrowserStoreCommitResult<BrowserTab?> {
    guard let entry = nextReopenableClosedTab() else { return noopResult(nil) }
    guard let space = space(id: entry.originalSpaceId),
      let nextSelection = Self.selection(for: space, currentWorkspaceId: currentWorkspaceId)
    else { return .failed }
    let instant = BrowserPersistence.storedInstant(now)
    let restored = BrowserTab(
      id: UUID(), spaceId: space.id, section: .today,
      position: tabs(in: space.id, section: .today).count,
      url: entry.url, title: entry.title, createdAt: instant, lastActiveAt: instant)
    return commit { db, draft in
      try db?.deleteClosedTab(entry.id)
      draft.closedTabs.removeAll { $0.id == entry.id }
      try db?.insertTab(restored, spaceKind: space.kind)
      draft.tabs.append(restored)
      try db?.setActiveTab(restored.id, in: space.id)
      draft.activeTabBySpace[space.id] = restored.id
      if draft.activeSpaceSelection != nextSelection {
        try db?.updateActiveSpace(nextSelection)
        draft.activeSpaceSelection = nextSelection
      }
      return restored
    }
  }

  // MARK: - 内部補助

  private struct ClosedTabRecord {
    let url: URL
    let title: String
    let spaceId: UUID
    let closedAt: Date
  }

  private func recordClosedEntry(
    _ record: ClosedTabRecord, db: BrowserDatabase?, draft: inout BrowserMemory
  ) throws {
    let entryId: Int64
    if let db {
      entryId = try db.insertClosedTab(
        url: record.url, title: record.title, originalSpaceId: record.spaceId,
        closedAt: record.closedAt)
      try db.trimClosedTabs(limit: Self.closedTabLimit)
    } else {
      entryId = allocateInMemoryClosedTabId(for: draft)
    }
    let entry = BrowserClosedTab(
      id: entryId, url: record.url, title: record.title, originalSpaceId: record.spaceId,
      closedAt: record.closedAt)
    draft.closedTabs.insert(entry, at: 0)
    if draft.closedTabs.count > Self.closedTabLimit {
      draft.closedTabs.removeLast(draft.closedTabs.count - Self.closedTabLimit)
    }
  }

  private static func selection(
    for space: BrowserSpace, currentWorkspaceId: UUID?
  ) -> BrowserActiveSpaceSelection? {
    switch space.kind {
    case .free:
      return .free(space.id)
    case .local:
      return space.workspaceId == currentWorkspaceId ? .local : nil
    }
  }

  private static func sectionTabs(
    in memory: BrowserMemory, spaceId: UUID, section: BrowserTabSection
  ) -> [BrowserTab] {
    memory.tabs.filter { $0.spaceId == spaceId && $0.section == section }.sorted(by: tabOrder)
  }

  private static func writeSectionOrder(
    _ ordered: [BrowserTab], db: BrowserDatabase?, draft: inout BrowserMemory
  ) throws {
    for (pos, tab) in ordered.enumerated() {
      var next = tab
      next.position = pos
      if let idx = draft.tabs.firstIndex(where: { $0.id == tab.id }) {
        if draft.tabs[idx] != next {
          draft.tabs[idx] = next
          try db?.updateTabPlacement(next)
        }
      }
    }
  }

  /// アクティブタブ削除時の次候補を「削除前の同区分直後 → 直前 → 同スペース他区分先頭（favorite → pinned → today）→ nil」で選ぶ。
  private static func fallbackActiveTabId(
    in before: BrowserMemory, spaceId: UUID, removing removedIds: Set<UUID>
  ) -> UUID? {
    if let activeId = before.activeTabBySpace[spaceId],
      let activeTab = before.tabs.first(where: { $0.id == activeId && $0.spaceId == spaceId })
    {
      let sameSection = sectionTabs(in: before, spaceId: spaceId, section: activeTab.section)
      if let activeIndex = sameSection.firstIndex(where: { $0.id == activeId }) {
        if let after = sameSection[(activeIndex + 1)...].first(where: {
          !removedIds.contains($0.id)
        }) {
          return after.id
        }
        if let beforeTab = sameSection[..<activeIndex].last(where: {
          !removedIds.contains($0.id)
        }) {
          return beforeTab.id
        }
      }
    }
    for section in [BrowserTabSection.favorite, .pinned, .today] {
      let candidates = sectionTabs(in: before, spaceId: spaceId, section: section)
      if let first = candidates.first(where: { !removedIds.contains($0.id) }) {
        return first.id
      }
    }
    return nil
  }
}
