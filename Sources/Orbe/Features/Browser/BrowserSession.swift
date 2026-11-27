import Foundation

/// 内蔵ブラウザのランタイム調停層。
/// `BrowserStore`・materialize 済み `BrowserTabRuntime` プール・`BrowserDataStoreRegistry`・
/// `BrowserTabCleaner` を束ね、遅延 materialize・表示ライフサイクル連動の `lastActiveAt` 更新・
/// プロファイル削除時の解放先行順序を保証する。
@MainActor
final class BrowserSession {
  let store: BrowserStore
  let dataStores: BrowserDataStoreRegistry
  let cleaner: BrowserTabCleaner
  let now: () -> Date

  var runtimes: [UUID: BrowserTabRuntime] = [:]
  private(set) var isStarted = false
  private(set) var isBrowserOpen = false

  var visibleTabId: UUID?
  private var drainingStoreRemovals = false

  var onActiveDisplayChange: ((BrowserTabRuntime?) -> Void)?
  var onActiveNavigationFinish: (() -> Void)?

  var activeRuntime: BrowserTabRuntime? {
    store.activeTab.flatMap { runtimes[$0.id] }
  }

  init(
    store: BrowserStore,
    dataStores: BrowserDataStoreRegistry? = nil,
    cleaner: BrowserTabCleaner? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    self.store = store
    self.now = now
    self.dataStores =
      dataStores
      ?? BrowserDataStoreRegistry(isIsolated: { StateDir.isIsolated || !store.available })
    let resolvedCleaner = cleaner ?? BrowserTabCleaner(now: now)
    self.cleaner = resolvedCleaner
    resolvedCleaner.nextFireDate = { [weak self] in
      guard let self else { return nil }
      let protected = self.isBrowserOpen ? self.visibleTabId : nil
      return self.store.earliestTodayTabExpiry(excluding: protected)
    }
    resolvedCleaner.onSweep = { [weak self] current in
      _ = self?.sweepExpiredTodayTabs(now: current)
    }
  }

  deinit {
    let cleaner = self.cleaner
    let runtimes = self.runtimes
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        cleaner.stop()
        for runtime in runtimes.values {
          runtime.invalidate()
        }
      }
    }
  }

  /// 単体利用（`BrowserLayerView` 単独・テスト・視覚確認）用のインメモリ即開始セッション。
  static func inMemory(
    language: Language = .systemDefault,
    workspaceId: UUID = UUID(),
    workspaceName: String = "",
    now: @escaping () -> Date = Date.init
  ) -> BrowserSession {
    let store = BrowserStore.inMemory(language: language, now: now())
    let session = BrowserSession(store: store, now: now)
    session.start(initialWorkspaceId: workspaceId, workspaceName: workspaceName)
    return session
  }

  // MARK: - 起動・停止・workspace 連動

  /// 起動順序を固定する単一入口:
  /// 1. 起動時 12h 自動整理（保護無し）→ 2. 開始ゲート解放と初回 workspace 同期 →
  /// 3. 削除キュー再試行 → 4. 壁時計タイマー開始。
  func start(initialWorkspaceId: UUID, workspaceName: String = "") {
    guard !isStarted else {
      syncCurrentWorkspace(initialWorkspaceId, name: workspaceName)
      return
    }
    if let removed = store.pruneExpiredTodayTabs(now: now(), protectedTabId: nil).value {
      invalidateRuntimes(removed)
    }
    isStarted = true
    store.currentWorkspaceName = workspaceName
    _ = store.setCurrentWorkspace(initialWorkspaceId, now: now())
    syncVisibilityAndDisplay(touchingLeavingTab: false)
    drainPendingStoreRemovals()
    cleaner.start()
  }

  func stop() {
    cleaner.stop()
  }

  /// `renderSelection()`・`renameWorkspace()` から呼ばれる冪等な workspace 同期。`start` 完了前は無操作。
  func syncCurrentWorkspace(_ workspaceId: UUID, name: String? = nil) {
    guard isStarted else { return }
    if let name, store.currentWorkspaceName != name {
      store.currentWorkspaceName = name
    }
    guard store.currentWorkspaceId != workspaceId else { return }
    _ = store.setCurrentWorkspace(workspaceId, now: now())
    syncVisibilityAndDisplay()
  }

  func removeLocalSpace(for workspaceId: UUID) {
    guard let space = store.localSpace(for: workspaceId) else { return }
    let tabIds = store.tabs(in: space.id).map(\.id)
    invalidateRuntimes(tabIds)
    _ = store.removeLocalSpace(for: workspaceId)
    syncVisibilityAndDisplay(touchingLeavingTab: false)
  }

  // MARK: - 表示状態・シート幅比率

  func setBrowserOpen(_ open: Bool) {
    guard isBrowserOpen != open else { return }
    isBrowserOpen = open
    syncVisibilityAndDisplay()
  }

  func commitSheetRatio(_ ratio: Double) {
    _ = store.setSheetRatio(ratio)
  }

  // MARK: - 内部調停

  func syncVisibilityAndDisplay(touchingLeavingTab: Bool = true) {
    let current = now()
    let previous = visibleTabId
    let next = isBrowserOpen ? store.activeTab?.id : nil
    if previous != next {
      if touchingLeavingTab, let previous {
        _ = store.touchTabActive(previous, now: current)
      }
      visibleTabId = next
      if let next {
        _ = store.touchTabActive(next, now: current)
      }
    }
    syncActiveDisplay()
    cleaner.recount()
  }

  /// 段階 1（常時）で破棄済み・不一致ランタイムのアンマウントとツールバー投影を保証し、
  /// 段階 2（開放中のみ）で URL 付き未 materialize アクティブタブを遅延生成・ロードする。
  func syncActiveDisplay(allowMaterialize: Bool = true) {
    let activeTab = store.activeTab
    let existing = activeTab.flatMap { runtimes[$0.id] }
    onActiveDisplayChange?(existing)

    guard allowMaterialize, isBrowserOpen,
      let tab = activeTab,
      existing == nil,
      let url = tab.url
    else { return }

    guard let runtime = materializeRuntime(for: tab) else { return }
    runtime.load(url)
    onActiveDisplayChange?(runtime)
  }

  func ensureRuntime(for tab: BrowserTab) -> BrowserTabRuntime? {
    if let existing = runtimes[tab.id] { return existing }
    return materializeRuntime(for: tab)
  }

  func materializeRuntime(for tab: BrowserTab) -> BrowserTabRuntime? {
    guard let profileId = store.profileId(forTab: tab.id) else { return nil }
    let runtime = BrowserTabRuntime(
      tabId: tab.id, profileId: profileId, dataStore: dataStores.store(for: profileId))
    runtime.onStateChange = { [weak self, weak runtime] in
      guard let self, let runtime, self.runtimes[runtime.tabId] === runtime,
        self.store.activeTab?.id == runtime.tabId
      else { return }
      self.onActiveDisplayChange?(runtime)
    }
    runtime.onCommittedNavigation = { [weak self] url, title in
      guard let self else { return }
      _ = self.store.updateTabNavigation(tab.id, url: url, title: title, now: self.now())
      self.cleaner.recount()
    }
    runtime.onTitleChange = { [weak self] title in
      guard let self else { return }
      _ = self.store.updateTabTitle(tab.id, title: title)
    }
    runtime.onNavigationFinish = { [weak self] in
      guard let self, self.store.activeTab?.id == tab.id else { return }
      self.onActiveNavigationFinish?()
    }
    runtimes[tab.id] = runtime
    return runtime
  }

  func invalidateRuntimes(_ tabIds: [UUID]) {
    for tabId in tabIds {
      runtimes.removeValue(forKey: tabId)?.invalidate()
    }
  }

  func drainPendingStoreRemovals() {
    guard !drainingStoreRemovals, !dataStores.isIsolated else { return }
    let pending = store.pendingStoreRemovals.map(\.storeId)
    guard !pending.isEmpty else { return }
    drainingStoreRemovals = true
    drainNextStoreRemoval(pending, index: 0)
  }

  private func drainNextStoreRemoval(_ ids: [UUID], index: Int) {
    guard index < ids.count else {
      drainingStoreRemovals = false
      let attempted = Set(ids)
      if !dataStores.isIsolated,
        store.pendingStoreRemovals.contains(where: { !attempted.contains($0.storeId) })
      {
        drainPendingStoreRemovals()
      }
      return
    }
    guard !dataStores.isIsolated else {
      drainingStoreRemovals = false
      return
    }
    let storeId = ids[index]
    dataStores.removePersistentStore(for: storeId) { [weak self] removed in
      guard let self else { return }
      if removed {
        _ = self.store.removePendingStoreRemoval(storeId)
      }
      self.drainNextStoreRemoval(ids, index: index + 1)
    }
  }
}
