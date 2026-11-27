import Foundation
import SQLite3

/// 内蔵ブラウザ DB の読み書き。書き込みはすべて `transaction` 内で呼ぶ。
final class BrowserDatabase {
  struct Opened {
    let database: BrowserDatabase
    let memory: BrowserMemory
  }

  let db: SQLiteDatabase

  init(_ db: SQLiteDatabase) {
    self.db = db
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try db.transaction(body)
  }

  // MARK: - Profiles

  func insertProfile(_ profile: BrowserProfile) throws {
    try db.run(
      """
      INSERT INTO profiles (id, name, color, mcp_allowed, position, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        .text(profile.id.uuidString), .text(profile.name), .text(profile.color.rawValue),
        .integer(profile.mcpAllowed ? 1 : 0), .integer(Int64(profile.position)),
        Self.instant(profile.createdAt),
      ])
  }

  func updateProfile(_ profile: BrowserProfile) throws {
    try db.run(
      """
      UPDATE profiles SET name = ?, color = ?, mcp_allowed = ?, position = ?
      WHERE id = ?
      """,
      [
        .text(profile.name), .text(profile.color.rawValue),
        .integer(profile.mcpAllowed ? 1 : 0), .integer(Int64(profile.position)),
        .text(profile.id.uuidString),
      ])
  }

  func updateProfilePosition(_ id: UUID, position: Int) throws {
    try db.run(
      "UPDATE profiles SET position = ? WHERE id = ?",
      [.integer(Int64(position)), .text(id.uuidString)])
  }

  func reassignSpaces(fromProfile oldId: UUID, toProfile newId: UUID) throws {
    try db.run(
      "UPDATE spaces SET profile_id = ? WHERE profile_id = ?",
      [.text(newId.uuidString), .text(oldId.uuidString)])
  }

  func deleteProfile(_ id: UUID) throws {
    try db.run("DELETE FROM profiles WHERE id = ?", [.text(id.uuidString)])
  }

  // MARK: - Spaces

  func insertSpace(_ space: BrowserSpace) throws {
    try db.run(
      """
      INSERT INTO spaces (id, kind, workspace_id, name, icon, profile_id, position, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(space.id.uuidString), .text(space.kind.rawValue),
        Self.text(space.workspaceId?.uuidString), .text(space.name), .text(space.icon.rawValue),
        .text(space.profileId.uuidString), .integer(Int64(space.position)),
        Self.instant(space.createdAt),
      ])
  }

  func updateSpace(_ space: BrowserSpace) throws {
    try db.run(
      """
      UPDATE spaces SET name = ?, icon = ?, profile_id = ?, position = ?
      WHERE id = ?
      """,
      [
        .text(space.name), .text(space.icon.rawValue), .text(space.profileId.uuidString),
        .integer(Int64(space.position)), .text(space.id.uuidString),
      ])
  }

  func updateSpaceProfile(_ spaceId: UUID, profileId: UUID) throws {
    try db.run(
      "UPDATE spaces SET profile_id = ? WHERE id = ?",
      [.text(profileId.uuidString), .text(spaceId.uuidString)])
  }

  func updateSpacePosition(_ spaceId: UUID, position: Int) throws {
    try db.run(
      "UPDATE spaces SET position = ? WHERE id = ?",
      [.integer(Int64(position)), .text(spaceId.uuidString)])
  }

  func deleteSpace(_ spaceId: UUID) throws {
    try db.run("DELETE FROM spaces WHERE id = ?", [.text(spaceId.uuidString)])
  }

  // MARK: - Tabs

  func insertTab(_ tab: BrowserTab, spaceKind: BrowserSpaceKind) throws {
    try db.run(
      """
      INSERT INTO tabs (id, space_id, space_kind, section, position, url, title, created_at,
        last_active_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(tab.id.uuidString), .text(tab.spaceId.uuidString), .text(spaceKind.rawValue),
        .text(tab.section.rawValue), .integer(Int64(tab.position)),
        Self.text(tab.url?.absoluteString), .text(tab.title), Self.instant(tab.createdAt),
        Self.instant(tab.lastActiveAt),
      ])
  }

  func updateTabNavigation(_ tabId: UUID, url: URL, title: String, lastActiveAt: Date) throws {
    try db.run(
      "UPDATE tabs SET url = ?, title = ?, last_active_at = ? WHERE id = ?",
      [
        .text(url.absoluteString), .text(title), Self.instant(lastActiveAt),
        .text(tabId.uuidString),
      ])
  }

  func updateTabTitle(_ tabId: UUID, title: String) throws {
    try db.run("UPDATE tabs SET title = ? WHERE id = ?", [.text(title), .text(tabId.uuidString)])
  }

  func updateTabLastActiveAt(_ tabId: UUID, lastActiveAt: Date) throws {
    try db.run(
      "UPDATE tabs SET last_active_at = ? WHERE id = ?",
      [Self.instant(lastActiveAt), .text(tabId.uuidString)])
  }

  func updateTabPlacement(_ tab: BrowserTab) throws {
    try db.run(
      "UPDATE tabs SET section = ?, position = ?, last_active_at = ? WHERE id = ?",
      [
        .text(tab.section.rawValue), .integer(Int64(tab.position)),
        Self.instant(tab.lastActiveAt), .text(tab.id.uuidString),
      ])
  }

  func deleteTab(_ tabId: UUID) throws {
    try db.run("DELETE FROM tabs WHERE id = ?", [.text(tabId.uuidString)])
  }

  func deleteTodayTabs(in spaceId: UUID) throws {
    try db.run(
      "DELETE FROM tabs WHERE space_id = ? AND section = 'today'", [.text(spaceId.uuidString)])
  }

  // MARK: - Space active tab / Meta / Closed tabs / Pending removals

  func setActiveTab(_ tabId: UUID?, in spaceId: UUID) throws {
    if let tabId {
      try db.run(
        "INSERT OR REPLACE INTO space_active_tabs (space_id, tab_id) VALUES (?, ?)",
        [.text(spaceId.uuidString), .text(tabId.uuidString)])
    } else {
      try db.run("DELETE FROM space_active_tabs WHERE space_id = ?", [.text(spaceId.uuidString)])
    }
  }

  func insertMeta(selection: BrowserActiveSpaceSelection, sheetRatioBps: Int) throws {
    let (kind, freeId) = Self.encodedSelection(selection)
    try db.run(
      """
      INSERT INTO browser_meta (id, active_space_kind, active_free_space_id, sheet_ratio_bps)
      VALUES (1, ?, ?, ?)
      """,
      [.text(kind), Self.text(freeId), .integer(Int64(sheetRatioBps))])
  }

  func updateActiveSpace(_ selection: BrowserActiveSpaceSelection) throws {
    let (kind, freeId) = Self.encodedSelection(selection)
    try db.run(
      "UPDATE browser_meta SET active_space_kind = ?, active_free_space_id = ? WHERE id = 1",
      [.text(kind), Self.text(freeId)])
  }

  func updateSheetRatioBps(_ bps: Int) throws {
    try db.run(
      "UPDATE browser_meta SET sheet_ratio_bps = ? WHERE id = 1", [.integer(Int64(bps))])
  }

  func insertClosedTab(url: URL, title: String, originalSpaceId: UUID, closedAt: Date) throws
    -> Int64
  {
    try db.run(
      """
      INSERT INTO closed_tabs (url, title, original_space_id, closed_at)
      VALUES (?, ?, ?, ?)
      """,
      [
        .text(url.absoluteString), .text(title), .text(originalSpaceId.uuidString),
        Self.instant(closedAt),
      ])
    return db.lastInsertRowID
  }

  func trimClosedTabs(limit: Int) throws {
    try db.run(
      """
      DELETE FROM closed_tabs
      WHERE id NOT IN (SELECT id FROM closed_tabs ORDER BY id DESC LIMIT ?)
      """,
      [.integer(Int64(limit))])
  }

  func deleteClosedTab(_ id: Int64) throws {
    try db.run("DELETE FROM closed_tabs WHERE id = ?", [.integer(id)])
  }

  func insertPendingStoreRemoval(_ removal: BrowserPendingStoreRemoval) throws {
    try db.run(
      "INSERT OR REPLACE INTO pending_store_removals (store_id, queued_at) VALUES (?, ?)",
      [.text(removal.storeId.uuidString), Self.instant(removal.queuedAt)])
  }

  func deletePendingStoreRemoval(_ storeId: UUID) throws {
    try db.run(
      "DELETE FROM pending_store_removals WHERE store_id = ?", [.text(storeId.uuidString)])
  }

  // MARK: - Helpers

  static func instant(_ date: Date) -> SQLiteValue {
    .integer(BrowserPersistence.millis(date))
  }

  static func text(_ value: String?) -> SQLiteValue {
    value.map { .text($0) } ?? .null
  }

  static func corrupt(_ message: String) -> SQLiteError {
    SQLiteError(code: SQLITE_CORRUPT, message: message)
  }

  private static func encodedSelection(
    _ selection: BrowserActiveSpaceSelection
  ) -> (String, String?) {
    switch selection {
    case .free(let id): ("free", id.uuidString)
    case .local: ("local", nil)
    }
  }
}
