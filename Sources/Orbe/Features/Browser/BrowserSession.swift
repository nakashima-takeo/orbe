import Foundation

/// 内蔵ブラウザのランタイム調停層。
/// `BrowserStore`・materialize 済み `BrowserTabRuntime` プール・`BrowserDataStoreRegistry`・
/// `BrowserTabCleaner` を束ね、遅延 materialize・表示ライフサイクル連動の `lastActiveAt` 更新・
/// プロファイル削除時の解放先行順序を保証する。
@MainActor
final class BrowserSession {
  typealias StoreRemovalScheduler =
    @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

  static let defaultStoreRemovalRetryDelays: [TimeInterval] = [0.25, 0.5, 1.0]

  let store: BrowserStore
  let dataStores: BrowserDataStoreRegistry
  let cleaner: BrowserTabCleaner
  let now: () -> Date
  let scheduleStoreRemoval: StoreRemovalScheduler
  var storeRemovalRetryDelays: [TimeInterval] = defaultStoreRemovalRetryDelays

  var runtimes: [UUID: BrowserTabRuntime] = [:]
  private(set) var isStarted = false
  private(set) var isBrowserOpen = false

  var visibleTabId: UUID?
  private var drainingStoreRemovals = false
  private var cancelScheduledStoreRemoval: (() -> Void)?
  private var storeRemovalRetryAttempts: [UUID: Int] = [:]

  /// アクティブタブまたは表示ランタイムの切替通知（マウント・焦点引継用）。
  var onActiveDisplayChange: ((BrowserTabRuntime?) -> Void)?
  /// 同一アクティブランタイムの KVO・遷移状態更新通知（ツールバー投影のみ）。
  var onActiveRuntimeStateChange: ((BrowserTabRuntime) -> Void)?
  var onActiveNavigationFinish: (() -> Void)?

  var activeRuntime: BrowserTabRuntime? {
    store.activeTab.flatMap { runtimes[$0.id] }
  }

  init(
    store: BrowserStore,
    dataStores: BrowserDataStoreRegistry? = nil,
    cleaner: BrowserTabCleaner? = nil,
    now: @escaping () -> Date = Date.init,
    scheduleStoreRemoval: @escaping StoreRemovalScheduler = BrowserSession.defaultScheduleRemoval
  ) {
    self.store = store
    self.now = now
    self.scheduleStoreRemoval = scheduleStoreRemoval
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
    let cancelRemoval = self.cancelScheduledStoreRemoval
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        cancelRemoval?()
        cleaner.stop()
        for runtime in runtimes.values {
          runtime.invalidate()
        }
      }
    }
  }

  static func defaultScheduleRemoval(
    delay: TimeInterval, work: @escaping @MainActor () -> Void
  ) -> () -> Void {
    let item = DispatchWorkItem {
      MainActor.assumeIsolated { work() }
    }
    if delay <= 0 {
      DispatchQueue.main.async(execute: item)
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    return { item.cancel() }
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
    let detached =
      store.pruneExpiredTodayTabs(now: now(), protectedTabId: nil).value.map(detachRuntimes) ?? []
    isStarted = true
    _ = syncWorkspaceIntoStore(initialWorkspaceId, name: workspaceName)
    syncVisibilityAndDisplay(touchingLeavingTab: false)
    invalidateDetachedRuntimes(detached)
    drainPendingStoreRemovals()
    cleaner.start()
  }

  /// セッションを停止する。アプリ終了経路（`flushingActiveTab: true`）では表示中 `TODAY` タブの
  /// `lastActiveAt` を確定保存してから停止し、`deinit` 等では無副作用で停止する。
  func stop(flushingActiveTab: Bool = false) {
    if flushingActiveTab, isBrowserOpen, let tabId = visibleTabId {
      _ = store.touchTabActive(tabId, now: now())
      visibleTabId = nil
    }
    isStarted = false
    cancelScheduledStoreRemoval?()
    cancelScheduledStoreRemoval = nil
    cleaner.stop()
  }

  /// `renderSelection()`・`renameWorkspace()` から呼ばれる冪等な workspace 同期。`start` 完了前は無操作。
  func syncCurrentWorkspace(_ workspaceId: UUID, name: String? = nil) {
    guard isStarted else { return }
    let workspaceChanged = store.currentWorkspaceId != workspaceId
    guard workspaceChanged || (name != nil && store.currentWorkspaceName != name) else { return }
    let didSync = syncWorkspaceIntoStore(workspaceId, name: name)
    if workspaceChanged && didSync {
      syncVisibilityAndDisplay()
    }
  }

  /// 運転中破損で非永続モードへ転落した直後は、メモリ上で 1 回だけ再同期して `.local` を機能継続させる。
  private func syncWorkspaceIntoStore(_ workspaceId: UUID, name: String?) -> Bool {
    let first = store.setCurrentWorkspace(workspaceId, name: name, now: now())
    if first.didSucceed { return true }
    guard !store.available else { return false }
    return store.setCurrentWorkspace(workspaceId, name: name, now: now()).didSucceed
  }

  func removeLocalSpace(for workspaceId: UUID) {
    guard let removedTabIds = store.removeLocalSpace(for: workspaceId).value else { return }
    let detached = detachRuntimes(removedTabIds)
    syncVisibilityAndDisplay(touchingLeavingTab: false)
    invalidateDetachedRuntimes(detached)
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

  /// 開放中で URL 付き未 materialize アクティブタブがあれば遅延生成・ロードし、表示切替を 1 回だけ通知する。
  func syncActiveDisplay(allowMaterialize: Bool = true) {
    let activeTab = store.activeTab
    var target = activeTab.flatMap { runtimes[$0.id] }
    if target == nil, allowMaterialize, isBrowserOpen,
      let tab = activeTab, let url = tab.url,
      let runtime = materializeRuntime(for: tab)
    {
      runtime.load(url, notify: false)
      target = runtime
    }
    onActiveDisplayChange?(target)
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
      self.onActiveRuntimeStateChange?(runtime)
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

  /// 指定タブのランタイムを辞書から切り離して返す（表示同期完了まで `superview` と強参照を維持する）。
  func detachRuntimes(_ tabIds: [UUID]) -> [BrowserTabRuntime] {
    tabIds.compactMap { runtimes.removeValue(forKey: $0) }
  }

  func invalidateDetachedRuntimes(_ detached: [BrowserTabRuntime]) {
    for runtime in detached {
      runtime.invalidate()
    }
  }

  func scheduleDrainPendingStoreRemovals(delay: TimeInterval) {
    guard isStarted, !dataStores.isIsolated, !store.pendingStoreRemovals.isEmpty else { return }
    cancelScheduledStoreRemoval?()
    cancelScheduledStoreRemoval = scheduleStoreRemoval(delay) { [weak self] in
      guard let self else { return }
      self.cancelScheduledStoreRemoval = nil
      self.drainPendingStoreRemovals()
    }
  }

  func drainPendingStoreRemovals() {
    guard isStarted, !drainingStoreRemovals, !dataStores.isIsolated else { return }
    let pending = store.pendingStoreRemovals.map(\.storeId)
    guard !pending.isEmpty else { return }
    cancelScheduledStoreRemoval?()
    cancelScheduledStoreRemoval = nil
    drainingStoreRemovals = true
    drainNextStoreRemoval(pending, index: 0, failedIds: [])
  }

  private func drainNextStoreRemoval(_ ids: [UUID], index: Int, failedIds: [UUID]) {
    guard index < ids.count else {
      drainingStoreRemovals = false
      finishStoreRemovalPass(attempted: Set(ids), failedIds: failedIds)
      return
    }
    guard isStarted, !dataStores.isIsolated else {
      drainingStoreRemovals = false
      cancelScheduledStoreRemoval?()
      cancelScheduledStoreRemoval = nil
      return
    }
    let storeId = ids[index]
    dataStores.removePersistentStore(for: storeId) { [weak self] removed in
      guard let self else { return }
      var nextFailed = failedIds
      if removed {
        self.storeRemovalRetryAttempts.removeValue(forKey: storeId)
        _ = self.store.removePendingStoreRemoval(storeId)
      } else {
        nextFailed.append(storeId)
      }
      self.drainNextStoreRemoval(ids, index: index + 1, failedIds: nextFailed)
    }
  }

  private func finishStoreRemovalPass(attempted: Set<UUID>, failedIds: [UUID]) {
    guard isStarted, !dataStores.isIsolated else {
      cancelScheduledStoreRemoval?()
      cancelScheduledStoreRemoval = nil
      return
    }
    if store.pendingStoreRemovals.contains(where: { !attempted.contains($0.storeId) }) {
      scheduleDrainPendingStoreRemovals(delay: 0)
      return
    }
    var minDelay: TimeInterval?
    for storeId in failedIds
    where store.pendingStoreRemovals.contains(where: { $0.storeId == storeId }) {
      let attempt = storeRemovalRetryAttempts[storeId, default: 0]
      guard attempt < storeRemovalRetryDelays.count else { continue }
      storeRemovalRetryAttempts[storeId] = attempt + 1
      let delay = storeRemovalRetryDelays[attempt]
      minDelay = minDelay.map { min($0, delay) } ?? delay
    }
    if let delay = minDelay {
      scheduleDrainPendingStoreRemovals(delay: delay)
    }
  }
}
