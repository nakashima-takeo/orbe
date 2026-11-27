import Foundation

/// 起動時の読み込み・初回シード・`PRAGMA foreign_key_check`・構造整合検査・個別 URL 無害化。
extension BrowserDatabase {
  private static let allTables = [
    "profiles", "spaces", "tabs", "space_active_tabs",
    "closed_tabs", "browser_meta", "pending_store_removals",
  ]

  /// 完全空 DB なら初回シードを 1 トランザクションで投入し、既存行があれば `foreign_key_check` と構造検査を通して読む。
  /// 構造不整合は `SQLITE_CORRUPT` を投げて `StateDatabase.open` の正規退避経路へ委ねる。
  static func loadOrSeed(_ db: SQLiteDatabase, language: Language, now: Date) throws -> Loaded {
    let database = BrowserDatabase(db)
    if try database.isCompletelyEmpty() {
      let seed = BrowserMemory.makeDefaultSeed(language: language, now: now)
      try database.writeSeed(seed)
      return Loaded(memory: seed, seededLanguage: language)
    }
    try database.verifyForeignKeys()
    return Loaded(memory: try database.readAll(), seededLanguage: nil)
  }

  private func isCompletelyEmpty() throws -> Bool {
    for table in Self.allTables {
      let hasRow =
        try db.select("SELECT EXISTS(SELECT 1 FROM \(table))", []) { $0.int64(at: 0) != 0 }.first
        ?? false
      if hasRow { return false }
    }
    return true
  }

  private func writeSeed(_ seed: BrowserMemory) throws {
    try transaction {
      for profile in seed.profiles {
        try insertProfile(profile)
      }
      for space in seed.spaces {
        try insertSpace(space)
      }
      try insertMeta(selection: seed.activeSpaceSelection, sheetRatioBps: seed.sheetRatioBps)
    }
  }

  private func verifyForeignKeys() throws {
    let violations = try db.select("PRAGMA foreign_key_check", []) { $0.text(at: 0) ?? "" }
    guard violations.isEmpty else {
      let tables = Set(violations).sorted().joined(separator: ", ")
      throw Self.corrupt("foreign_key_check failed in \(tables)")
    }
  }

  private func readAll() throws -> BrowserMemory {
    let profiles = try readProfiles()
    guard !profiles.isEmpty else {
      throw Self.corrupt("profiles table is empty")
    }
    let profileIds = Set(profiles.map(\.id))
    let spaces = try readSpaces(validProfileIds: profileIds)
    let spaceById = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
    let tabs = try readTabs(spaceById: spaceById)
    let tabById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
    let activeTabBySpace = try readActiveTabs(spaceById: spaceById, tabById: tabById)
    let closedTabs = try readClosedTabs(spaceById: spaceById)
    let (activeSpaceSelection, sheetRatioBps) = try readMeta(spaceById: spaceById)
    let pendingStoreRemovals = try readPendingStoreRemovals(excluding: profileIds)
    return BrowserMemory(
      profiles: profiles,
      spaces: spaces,
      tabs: tabs,
      activeTabBySpace: activeTabBySpace,
      closedTabs: closedTabs,
      activeSpaceSelection: activeSpaceSelection,
      sheetRatioBps: sheetRatioBps,
      pendingStoreRemovals: pendingStoreRemovals)
  }

  /// SQLite の `TEXT` 比較は `BINARY` であり全書き込みが大文字 `UUID.uuidString` を使うため、
  /// 非正規形式（小文字等）は起動時検査で `nil` 扱いとして破損退避へ送る。
  private static func canonicalUUID(_ raw: String?) -> UUID? {
    guard let raw, let uuid = UUID(uuidString: raw), raw == uuid.uuidString else { return nil }
    return uuid
  }

  private func readProfiles() throws -> [BrowserProfile] {
    var seenIds = Set<UUID>()
    return try db.select(
      """
      SELECT id, name, color, mcp_allowed, position, created_at
      FROM profiles ORDER BY position, created_at, id
      """, []
    ) { s in
      guard let id = Self.canonicalUUID(s.text(at: 0)),
        seenIds.insert(id).inserted,
        let name = s.text(at: 1), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let rawColor = s.text(at: 2), let color = BrowserProfileColor(rawValue: rawColor)
      else {
        throw Self.corrupt("invalid profile row")
      }
      let mcpRaw = s.int64(at: 3)
      let position = s.int(at: 4)
      guard mcpRaw == 0 || mcpRaw == 1, position >= 0 else {
        throw Self.corrupt("invalid profile attributes")
      }
      return BrowserProfile(
        id: id, name: name, color: color, mcpAllowed: mcpRaw == 1, position: position,
        createdAt: BrowserPersistence.date(s.int64(at: 5)))
    }
  }

  private func readSpaces(validProfileIds: Set<UUID>) throws -> [BrowserSpace] {
    var seenIds = Set<UUID>()
    var seenWorkspaces = Set<UUID>()
    return try db.select(
      """
      SELECT id, kind, workspace_id, name, icon, profile_id, position, created_at
      FROM spaces ORDER BY kind, position, created_at, id
      """, []
    ) { s in
      guard let id = Self.canonicalUUID(s.text(at: 0)),
        seenIds.insert(id).inserted,
        let rawKind = s.text(at: 1), let kind = BrowserSpaceKind(rawValue: rawKind),
        let name = s.text(at: 3),
        let rawIcon = s.text(at: 4), let icon = BrowserSpaceIcon(rawValue: rawIcon),
        let profileId = Self.canonicalUUID(s.text(at: 5)),
        validProfileIds.contains(profileId)
      else {
        throw Self.corrupt("invalid space row")
      }
      let position = s.int(at: 6)
      guard position >= 0 else { throw Self.corrupt("negative space position") }
      let workspaceId: UUID?
      if let rawWorkspaceId = s.text(at: 2) {
        guard let parsed = Self.canonicalUUID(rawWorkspaceId) else {
          throw Self.corrupt("invalid space workspace_id")
        }
        workspaceId = parsed
      } else {
        workspaceId = nil
      }
      switch kind {
      case .local:
        guard let workspaceId, icon == .local, seenWorkspaces.insert(workspaceId).inserted else {
          throw Self.corrupt("invalid local space invariants")
        }
      case .free:
        guard workspaceId == nil, icon != .local,
          !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          throw Self.corrupt("invalid free space invariants")
        }
      }
      return BrowserSpace(
        id: id, kind: kind, workspaceId: workspaceId, name: name, icon: icon,
        profileId: profileId, position: position,
        createdAt: BrowserPersistence.date(s.int64(at: 7)))
    }
  }

  private func readTabs(spaceById: [UUID: BrowserSpace]) throws -> [BrowserTab] {
    var seenIds = Set<UUID>()
    return try db.select(
      """
      SELECT id, space_id, space_kind, section, position, url, title, created_at, last_active_at
      FROM tabs ORDER BY space_id, section, position, created_at, id
      """, []
    ) { s in
      guard let id = Self.canonicalUUID(s.text(at: 0)),
        seenIds.insert(id).inserted,
        let spaceId = Self.canonicalUUID(s.text(at: 1)),
        let space = spaceById[spaceId],
        let rawKind = s.text(at: 2), let spaceKind = BrowserSpaceKind(rawValue: rawKind),
        space.kind == spaceKind,
        let rawSection = s.text(at: 3), let section = BrowserTabSection(rawValue: rawSection),
        !(spaceKind == .local && section == .favorite)
      else {
        throw Self.corrupt("invalid tab row")
      }
      let position = s.int(at: 4)
      guard position >= 0 else { throw Self.corrupt("negative tab position") }
      let sanitizedURL: URL? = s.text(at: 5).flatMap { raw in
        guard let parsed = URL(string: raw),
          BrowserURLInput.isValidHTTPNavigationURL(parsed)
        else { return nil }
        return parsed
      }
      return BrowserTab(
        id: id, spaceId: spaceId, section: section, position: position,
        url: sanitizedURL, title: s.text(at: 6) ?? "",
        createdAt: BrowserPersistence.date(s.int64(at: 7)),
        lastActiveAt: BrowserPersistence.date(s.int64(at: 8)))
    }
  }

  private func readActiveTabs(
    spaceById: [UUID: BrowserSpace], tabById: [UUID: BrowserTab]
  ) throws -> [UUID: UUID] {
    var result: [UUID: UUID] = [:]
    let rows = try db.select("SELECT space_id, tab_id FROM space_active_tabs", []) { s in
      guard let spaceId = Self.canonicalUUID(s.text(at: 0)),
        let tabId = Self.canonicalUUID(s.text(at: 1)),
        spaceById[spaceId] != nil, let tab = tabById[tabId], tab.spaceId == spaceId
      else {
        throw Self.corrupt("invalid space_active_tabs row")
      }
      return (spaceId, tabId)
    }
    for (spaceId, tabId) in rows {
      guard result.updateValue(tabId, forKey: spaceId) == nil else {
        throw Self.corrupt("duplicate space_active_tabs space_id")
      }
    }
    return result
  }

  private func readClosedTabs(spaceById: [UUID: BrowserSpace]) throws -> [BrowserClosedTab] {
    let rows = try db.select(
      """
      SELECT id, url, title, original_space_id, closed_at
      FROM closed_tabs ORDER BY id DESC
      """, []
    ) { s -> BrowserClosedTab? in
      let id = s.int64(at: 0)
      guard let spaceId = Self.canonicalUUID(s.text(at: 3)),
        spaceById[spaceId] != nil
      else {
        throw Self.corrupt("invalid closed_tabs space reference")
      }
      guard let rawURL = s.text(at: 1), let url = URL(string: rawURL),
        BrowserURLInput.isValidHTTPNavigationURL(url)
      else {
        return nil
      }
      return BrowserClosedTab(
        id: id, url: url, title: s.text(at: 2) ?? "", originalSpaceId: spaceId,
        closedAt: BrowserPersistence.date(s.int64(at: 4)))
    }
    return rows.compactMap { $0 }
  }

  private func readMeta(spaceById: [UUID: BrowserSpace]) throws
    -> (BrowserActiveSpaceSelection, Int)
  {
    let rows = try db.select(
      """
      SELECT id, active_space_kind, active_free_space_id, sheet_ratio_bps
      FROM browser_meta
      """, []
    ) { s in
      (
        id: s.int64(at: 0), kind: s.text(at: 1), freeId: s.text(at: 2),
        ratioBps: s.int(at: 3)
      )
    }
    guard rows.count == 1, let row = rows.first, row.id == 1,
      let rawKind = row.kind, let kind = BrowserSpaceKind(rawValue: rawKind)
    else {
      throw Self.corrupt("invalid browser_meta row")
    }
    let selection: BrowserActiveSpaceSelection
    switch kind {
    case .local:
      guard row.freeId == nil else {
        throw Self.corrupt("browser_meta local selection has active_free_space_id")
      }
      selection = .local
    case .free:
      guard let freeId = Self.canonicalUUID(row.freeId),
        let space = spaceById[freeId], space.kind == .free
      else {
        throw Self.corrupt("browser_meta free selection points to missing or non-free space")
      }
      selection = .free(freeId)
    }
    return (selection, BrowserPersistence.clampSheetRatioBps(row.ratioBps))
  }

  private func readPendingStoreRemovals(excluding activeProfileIds: Set<UUID>) throws
    -> [BrowserPendingStoreRemoval]
  {
    var seenIds = Set<UUID>()
    return try db.select(
      "SELECT store_id, queued_at FROM pending_store_removals ORDER BY queued_at, store_id", []
    ) { s in
      guard let storeId = Self.canonicalUUID(s.text(at: 0)),
        !activeProfileIds.contains(storeId),
        seenIds.insert(storeId).inserted
      else {
        throw Self.corrupt("invalid pending_store_removals row")
      }
      return BrowserPendingStoreRemoval(
        storeId: storeId, queuedAt: BrowserPersistence.date(s.int64(at: 1)))
    }
  }
}
