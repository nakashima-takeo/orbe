import Foundation
import OrbeTestSupport
import XCTest

@testable import Orbe

/// ブラウザ DB の破損耐性（大小文字違いの同一 UUID 重複行に対する退避経路）を守る。
extension BrowserLayerViewTests {
  /// `profiles`・`spaces`・`tabs`・`space_active_tabs`・`pending_store_removals` に
  /// 大小文字違いの同一 UUID が 2 行あってもクラッシュせず `SQLITE_CORRUPT` 経由で退避再作成する。
  func testCaseInsensitiveDuplicateUUIDQuarantinesDatabaseInsteadOfCrashing() throws {
    let originalOverride = BrowserPersistence.folderOverride
    defer { BrowserPersistence.folderOverride = originalOverride }

    try assertDuplicateUUIDQuarantined(caseName: "dup-profile") { db, seed in
      let profile = try XCTUnwrap(seed.profiles.first)
      try db.run(
        """
        INSERT INTO profiles (id, name, color, mcp_allowed, position, created_at)
        VALUES (?, 'dup', 'blue', 0, 9, 0)
        """, [.text(profile.id.uuidString.lowercased())])
    }

    try assertDuplicateUUIDQuarantined(caseName: "dup-space") { db, seed in
      let space = try XCTUnwrap(seed.spaces.first { $0.kind == .free })
      try db.run(
        """
        INSERT INTO spaces (id, kind, workspace_id, name, icon, profile_id, position, created_at)
        VALUES (?, 'free', NULL, 'dup', 'globe', ?, 9, 0)
        """, [.text(space.id.uuidString.lowercased()), .text(space.profileId.uuidString)])
    }

    try assertDuplicateUUIDQuarantined(caseName: "dup-tab") { db, seed in
      let tab = try XCTUnwrap(seed.tabs.first)
      try db.run(
        """
        INSERT INTO tabs (id, space_id, space_kind, section, position, url, title, created_at,
          last_active_at)
        VALUES (?, ?, 'free', 'today', 9, NULL, '', 0, 0)
        """, [.text(tab.id.uuidString.lowercased()), .text(tab.spaceId.uuidString)])
    }

    try assertDuplicateUUIDQuarantined(caseName: "dup-active-tab") { db, seed in
      let tab = try XCTUnwrap(seed.tabs.first)
      try db.run(
        "INSERT INTO space_active_tabs (space_id, tab_id) VALUES (?, ?)",
        [.text(tab.spaceId.uuidString.lowercased()), .text(tab.id.uuidString)])
    }

    try assertDuplicateUUIDQuarantined(caseName: "dup-pending-removal") { db, _ in
      let id = UUID()
      try db.run(
        "INSERT INTO pending_store_removals (store_id, queued_at) VALUES (?, 0)",
        [.text(id.uuidString)])
      try db.run(
        "INSERT INTO pending_store_removals (store_id, queued_at) VALUES (?, 1)",
        [.text(id.uuidString.lowercased())])
    }
  }

  private func assertDuplicateUUIDQuarantined(
    caseName: String,
    corrupt: (SQLiteDatabase, BrowserMemory) throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let root = TestScratch.caseDir.appendingPathComponent(caseName, isDirectory: true)
    let folder = root.appendingPathComponent("browser", isDirectory: true)
    BrowserPersistence.folderOverride = folder

    let seededMemory: BrowserMemory
    do {
      let opening = BrowserPersistence.open(language: .ja)
      guard case .opened = opening else {
        XCTFail("\(caseName): 初回オープンに失敗", file: file, line: line)
        return
      }
      let store = BrowserStore(opening: opening, language: .ja)
      let freeSpace = try XCTUnwrap(store.freeSpaces.first, file: file, line: line)
      let tab = try XCTUnwrap(
        store.openTab(
          in: freeSpace.id, url: URL(string: "https://docs.orbe.dev/a"), title: "A",
          activate: true
        ).value, file: file, line: line)
      XCTAssertEqual(store.activeTabId(in: freeSpace.id), tab.id, file: file, line: line)
      seededMemory = store.memory
    }

    do {
      let raw = try SQLiteDatabase(url: folder.appendingPathComponent("db.sqlite"))
      try raw.exec("PRAGMA foreign_keys = OFF")
      try corrupt(raw, seededMemory)
    }

    let reopened = BrowserPersistence.open(language: .ja)
    guard case .opened(let opened) = reopened else {
      XCTFail("\(caseName): 破損 DB 退避後の再作成に失敗", file: file, line: line)
      return
    }
    XCTAssertTrue(
      opened.memory.tabs.isEmpty, "\(caseName): 退避後に既定シードで再作成される", file: file, line: line)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertTrue(
      siblings.contains(where: { $0.hasPrefix("browser-broken-") }),
      "\(caseName): 破損フォルダが browser-broken-* へ退避される", file: file, line: line)
  }
}
