import Foundation
import Observation

/// 内蔵ブラウザの永続ドメイン SSOT（@Observable・main 専用・AppKit/WebKit 非依存）。
/// 全書き込みは `commit` を経由し、1 トランザクションで書いて通ってからメモリを進める。
/// 起動時 `.refused` や運転中の `SQLiteError.isBroken` では原本 DB へ一切触れず非永続モードへ移行する。
@Observable final class BrowserStore {
  static let closedTabLimit = 50
  static let todayTabTTL: TimeInterval = 12 * 60 * 60

  private(set) var profiles: [BrowserProfile]
  private(set) var spaces: [BrowserSpace]
  private(set) var tabs: [BrowserTab]
  private(set) var activeTabBySpace: [UUID: UUID]
  /// 最新順（`id DESC`）。
  private(set) var closedTabs: [BrowserClosedTab]
  private(set) var activeSpaceSelection: BrowserActiveSpaceSelection
  private(set) var sheetRatioBps: Int
  private(set) var pendingStoreRemovals: [BrowserPendingStoreRemoval]
  /// 現在のアクティブ workspace ID（ランタイム同期値。永続化しない）。
  private(set) var currentWorkspaceId: UUID?
  /// 現在のアクティブ workspace 表示名（ランタイム同期値。永続化しない）。
  private(set) var currentWorkspaceName = ""

  private var database: BrowserDatabase?
  private(set) var unavailableReason: String?
  var available: Bool { database != nil }

  struct InitialDefaultFreeSpace {
    let id: UUID
    let key: L10nKey
    let seededName: String
  }

  @ObservationIgnored private var nextInMemoryClosedTabId: Int64
  /// 初回シードで投入された既定自由スペースの初期状態（初回言語選択確定時の未変更同期に使う）。
  @ObservationIgnored var initialDefaultFreeSpaces: [InitialDefaultFreeSpace] = []

  init(
    opening: BrowserPersistence.Opening,
    language: Language = .systemDefault,
    now: Date = Date()
  ) {
    let initial: BrowserMemory
    let seededLanguage: Language?
    switch opening {
    case .opened(let opened):
      database = opened.database
      unavailableReason = nil
      initial = opened.memory
      seededLanguage = opened.seededLanguage
    case .refused(let reason):
      database = nil
      unavailableReason = reason
      initial = BrowserMemory.makeDefaultSeed(language: language, now: now)
      seededLanguage = language
    }
    profiles = initial.profiles
    spaces = initial.spaces
    tabs = initial.tabs
    activeTabBySpace = initial.activeTabBySpace
    closedTabs = initial.closedTabs
    activeSpaceSelection = initial.activeSpaceSelection
    sheetRatioBps = initial.sheetRatioBps
    pendingStoreRemovals = initial.pendingStoreRemovals
    nextInMemoryClosedTabId = (initial.closedTabs.map(\.id).max() ?? 0) + 1
    if let seededLanguage {
      let seededFree = initial.spaces.filter { $0.kind == .free }.sorted(by: Self.spaceOrder)
      if seededFree.count == BrowserMemory.defaultFreeSpaceSpecs.count {
        initialDefaultFreeSpaces = zip(seededFree, BrowserMemory.defaultFreeSpaceSpecs).map {
          InitialDefaultFreeSpace(
            id: $0.id, key: $1.key, seededName: L10n.string($1.key, seededLanguage))
        }
      }
    }
  }

  static func open(language: Language = .systemDefault, now: Date = Date()) -> BrowserStore {
    BrowserStore(
      opening: BrowserPersistence.open(language: language, now: now), language: language, now: now)
  }

  static func inMemory(language: Language = .systemDefault, now: Date = Date()) -> BrowserStore {
    BrowserStore(opening: .refused("in-memory session"), language: language, now: now)
  }

  func updateCurrentWorkspaceState(id: UUID?, name: String?) {
    currentWorkspaceId = id
    if let name {
      currentWorkspaceName = name
    }
  }

  var memory: BrowserMemory {
    BrowserMemory(
      profiles: profiles,
      spaces: spaces,
      tabs: tabs,
      activeTabBySpace: activeTabBySpace,
      closedTabs: closedTabs,
      activeSpaceSelection: activeSpaceSelection,
      sheetRatioBps: sheetRatioBps,
      pendingStoreRemovals: pendingStoreRemovals)
  }

  // MARK: - 導出クエリ

  var sheetRatio: Double { BrowserPersistence.ratio(fromBps: sheetRatioBps) }

  var defaultLocalProfileId: UUID? {
    profiles.first(where: \.mcpAllowed)?.id ?? profiles.first?.id
  }

  var freeSpaces: [BrowserSpace] {
    spaces.filter { $0.kind == .free }.sorted(by: Self.spaceOrder)
  }

  func localSpace(for workspaceId: UUID) -> BrowserSpace? {
    spaces.first { $0.kind == .local && $0.workspaceId == workspaceId }
  }

  var currentLocalSpace: BrowserSpace? {
    currentWorkspaceId.flatMap(localSpace(for:))
  }

  var activeSpace: BrowserSpace? {
    switch activeSpaceSelection {
    case .free(let id):
      spaces.first { $0.id == id && $0.kind == .free }
    case .local:
      currentLocalSpace
    }
  }

  func profile(id: UUID) -> BrowserProfile? {
    profiles.first { $0.id == id }
  }

  func space(id: UUID) -> BrowserSpace? {
    spaces.first { $0.id == id }
  }

  func tab(id: UUID) -> BrowserTab? {
    tabs.first { $0.id == id }
  }

  func tabs(in spaceId: UUID, section: BrowserTabSection? = nil) -> [BrowserTab] {
    tabs.filter { tab in
      tab.spaceId == spaceId && (section == nil || tab.section == section)
    }.sorted(by: Self.tabOrder)
  }

  func activeTabId(in spaceId: UUID) -> UUID? {
    activeTabBySpace[spaceId]
  }

  func activeTab(in spaceId: UUID) -> BrowserTab? {
    guard let id = activeTabBySpace[spaceId] else { return nil }
    return tabs.first { $0.id == id && $0.spaceId == spaceId }
  }

  var activeTab: BrowserTab? {
    activeSpace.flatMap { activeTab(in: $0.id) }
  }

  func profileId(forTab tabId: UUID) -> UUID? {
    guard let tab = tab(id: tabId), let space = space(id: tab.spaceId) else { return nil }
    return space.profileId
  }

  func displayName(for space: BrowserSpace, fallbackLocalName: String) -> String {
    switch space.kind {
    case .free:
      return space.name
    case .local:
      if space.workspaceId == currentWorkspaceId {
        let trimmed = currentWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
      let stored = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
      return stored.isEmpty ? fallbackLocalName : stored
    }
  }

  /// 現在のコンテキストで復元可能な閉じたタブ一覧（最新順。生存自由スペースまたは現在 workspace のローカルスペース由来）。
  func reopenableClosedTabs(limit: Int? = nil) -> [BrowserClosedTab] {
    let freeIds = Set(spaces.filter { $0.kind == .free }.map(\.id))
    let localId = currentLocalSpace?.id
    let visible = closedTabs.filter { entry in
      freeIds.contains(entry.originalSpaceId) || entry.originalSpaceId == localId
    }
    guard let limit else { return visible }
    return Array(visible.prefix(max(0, limit)))
  }

  /// 現在のコンテキストで復元可能な最新の閉じたタブ（生存自由スペースまたは現在 workspace のローカルスペース由来）。
  func nextReopenableClosedTab() -> BrowserClosedTab? {
    reopenableClosedTabs(limit: 1).first
  }

  /// 全スペースの `TODAY` タブのうち保護対象を除いた最も早い整理予定時刻を返す。
  func earliestTodayTabExpiry(ttl: TimeInterval = todayTabTTL, excluding protectedTabId: UUID?)
    -> Date?
  {
    let earliestActive = tabs.compactMap { tab -> Date? in
      guard tab.section == .today, tab.id != protectedTabId else { return nil }
      return tab.lastActiveAt
    }.min()
    return earliestActive?.addingTimeInterval(ttl)
  }

  // MARK: - 単一書き込み経路

  func noopResult<T>(_ value: T) -> BrowserStoreCommitResult<T> {
    database != nil ? .persisted(value) : .inMemory(value)
  }

  func commit<T>(_ body: (BrowserDatabase?, inout BrowserMemory) throws -> T)
    -> BrowserStoreCommitResult<T>
  {
    var draft = memory
    guard let database else {
      do {
        let result = try body(nil, &draft)
        apply(draft)
        return .inMemory(result)
      } catch {
        NSLog("[browser] unexpected in-memory store error: \(error)")
        return .failed
      }
    }
    do {
      let result = try database.transaction {
        try body(database, &draft)
      }
      apply(draft)
      return .persisted(result)
    } catch {
      fault(error)
      return .failed
    }
  }

  func allocateInMemoryClosedTabId(for draft: BrowserMemory) -> Int64 {
    let maxExisting = draft.closedTabs.map(\.id).max() ?? 0
    let candidate = max(nextInMemoryClosedTabId, maxExisting + 1)
    nextInMemoryClosedTabId = candidate + 1
    return candidate
  }

  private func apply(_ next: BrowserMemory) {
    if next.profiles != profiles { profiles = next.profiles }
    if next.spaces != spaces { spaces = next.spaces }
    if next.tabs != tabs { tabs = next.tabs }
    if next.activeTabBySpace != activeTabBySpace { activeTabBySpace = next.activeTabBySpace }
    if next.closedTabs != closedTabs { closedTabs = next.closedTabs }
    if next.activeSpaceSelection != activeSpaceSelection {
      activeSpaceSelection = next.activeSpaceSelection
    }
    if next.sheetRatioBps != sheetRatioBps { sheetRatioBps = next.sheetRatioBps }
    if next.pendingStoreRemovals != pendingStoreRemovals {
      pendingStoreRemovals = next.pendingStoreRemovals
    }
    if let maxClosed = closedTabs.map(\.id).max(), maxClosed >= nextInMemoryClosedTabId {
      nextInMemoryClosedTabId = maxClosed + 1
    }
  }

  private func fault(_ error: Error) {
    NSLog("[browser] cannot save browser database: \(error)")
    if let sqliteError = error as? SQLiteError, sqliteError.isBroken {
      database = nil
      unavailableReason = "browser database broke while running; see the log"
    }
  }

  static func spaceOrder(_ lhs: BrowserSpace, _ rhs: BrowserSpace) -> Bool {
    if lhs.position != rhs.position { return lhs.position < rhs.position }
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  static func tabOrder(_ lhs: BrowserTab, _ rhs: BrowserTab) -> Bool {
    if lhs.section != rhs.section { return lhs.section.sortOrder < rhs.section.sortOrder }
    if lhs.position != rhs.position { return lhs.position < rhs.position }
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
