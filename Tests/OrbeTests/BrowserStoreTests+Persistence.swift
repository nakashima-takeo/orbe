import Foundation
import OrbeTestSupport
import SQLite3
import XCTest

@testable import Orbe

/// ブラウザ DB の破損耐性・不正 URL 無害化・未来版／排他ロック拒否・ロールバック・運転中破損フォールバック。
///
/// 壊れると何が起きるか。FK 違反や破損 DB で起動不能になる、不正スキーム URL 1 件で全タブが退避消滅する、
/// 未来版や 2 つ目の Orbe が原本 DB を退避・破壊する、または運転中破損後も原本 DB へ書き込み続ける。
extension BrowserStoreTests {
  // MARK: - 破損 DB の退避と再作成

  /// `PRAGMA foreign_key_check` 違反・`profiles` 空・`browser_meta` 欠損・非 DB 破損ファイルは
  /// フォルダごと `browser-broken-*` へ退避してから既定シードで健全再作成する。
  func testForeignKeyViolationAndCorruptDatabasesAreQuarantinedAndReseeded() throws {
    let originalOverride = BrowserPersistence.folderOverride
    defer { BrowserPersistence.folderOverride = originalOverride }

    try assertQuarantined(caseName: "fk-space-profile") { db, seed in
      let space = try XCTUnwrap(seed.spaces.first { $0.kind == .free })
      try db.run(
        "UPDATE spaces SET profile_id = ? WHERE id = ?",
        [.text(UUID().uuidString), .text(space.id.uuidString)])
    }

    try assertQuarantined(caseName: "fk-cross-space-active") { db, seed in
      let freeSpaces = seed.spaces.filter { $0.kind == .free }
      let tab = try XCTUnwrap(seed.tabs.first { $0.spaceId == freeSpaces[0].id })
      try db.run(
        "INSERT OR REPLACE INTO space_active_tabs (space_id, tab_id) VALUES (?, ?)",
        [.text(freeSpaces[1].id.uuidString), .text(tab.id.uuidString)])
    }

    try assertQuarantined(caseName: "fk-case-mismatch-closed-tab") { db, seed in
      let space = try XCTUnwrap(seed.spaces.first { $0.kind == .free })
      try db.run(
        "INSERT INTO closed_tabs (url, title, original_space_id, closed_at) VALUES (?, 'Case', ?, 1)",
        [.text(url("/case-fk").absoluteString), .text(space.id.uuidString.lowercased())])
    }

    try assertQuarantined(caseName: "empty-profiles") { db, _ in
      try db.exec("DELETE FROM spaces; DELETE FROM profiles;")
    }

    try assertQuarantined(caseName: "missing-meta") { db, _ in
      try db.exec("DELETE FROM browser_meta;")
    }

    // 非 DB バイト列で上書きしたファイル破損も退避して再作成する。
    let corruptRoot = TestScratch.caseDir.appendingPathComponent("not-a-db", isDirectory: true)
    let corruptFolder = corruptRoot.appendingPathComponent("browser", isDirectory: true)
    BrowserPersistence.folderOverride = corruptFolder
    try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
    try Data("corrupt-bytes".utf8).write(to: corruptFolder.appendingPathComponent("db.sqlite"))

    let recovered = openStore()
    XCTAssertTrue(recovered.available)
    XCTAssertEqual(recovered.profiles.count, 2)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: corruptRoot.path)
    XCTAssertTrue(siblings.contains(where: { $0.hasPrefix("browser-broken-") }))
  }

  private func assertQuarantined(
    caseName: String,
    corrupt: (SQLiteDatabase, BrowserMemory) throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let root = TestScratch.caseDir.appendingPathComponent(caseName, isDirectory: true)
    let folder = root.appendingPathComponent("browser", isDirectory: true)
    BrowserPersistence.folderOverride = folder

    let seeded: BrowserMemory
    do {
      let store = openStore()
      let space = try XCTUnwrap(store.freeSpaces.first, file: file, line: line)
      _ = store.openTab(
        in: space.id, url: url("/ok"), title: "OK", activate: true, now: Self.baseTime)
      seeded = store.memory
    }

    do {
      let raw = try SQLiteDatabase(url: folder.appendingPathComponent("db.sqlite"))
      try raw.exec("PRAGMA foreign_keys = OFF")
      try corrupt(raw, seeded)
    }

    let reopened = openStore()
    XCTAssertTrue(reopened.available, "\(caseName): 退避後に健全再作成する", file: file, line: line)
    XCTAssertTrue(reopened.tabs.isEmpty, "\(caseName): 既定シードへ戻る", file: file, line: line)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertTrue(
      siblings.contains(where: { $0.hasPrefix("browser-broken-") }),
      "\(caseName): browser-broken-* へ退避される", file: file, line: line)
  }

  // MARK: - 個別不正 URL の無害化

  /// 個別の不正スキーム URL は DB 全体退避にせず、`tabs.url` は `nil` 化、`closed_tabs` はスキップして
  /// 健全なタブと構成を守る。
  func testInvalidSchemeURLsAreSanitizedWithoutQuarantiningDatabase() throws {
    let spaceId: UUID
    let badTabId: UUID
    let goodTabId: UUID

    do {
      let store = openStore()
      let space = try XCTUnwrap(store.freeSpaces.first)
      spaceId = space.id
      let goodTab = try XCTUnwrap(
        store.openTab(
          in: space.id, url: url("/safe"), title: "Safe", activate: true, now: Self.baseTime
        ).value)
      let badTab = try XCTUnwrap(
        store.openTab(
          in: space.id, url: url("/temp"), title: "Bad", activate: false, now: Self.baseTime
        ).value)
      goodTabId = goodTab.id
      badTabId = badTab.id
    }

    do {
      let db = try rawDatabase()
      try db.run(
        "UPDATE tabs SET url = 'javascript:alert(1)' WHERE id = ?", [.text(badTabId.uuidString)])
      try db.run(
        "INSERT INTO closed_tabs (url, title, original_space_id, closed_at) VALUES (?, 'Evil', ?, 1)",
        [.text("file:///etc/passwd"), .text(spaceId.uuidString)])
      try db.run(
        "INSERT INTO closed_tabs (url, title, original_space_id, closed_at) VALUES (?, 'Good', ?, 2)",
        [.text(url("/closed-ok").absoluteString), .text(spaceId.uuidString)])
    }

    let reopened = openStore()
    XCTAssertTrue(reopened.available)
    XCTAssertEqual(try quarantined(), [], "不正 URL では DB を退避しない")
    XCTAssertEqual(reopened.tab(id: goodTabId)?.url, url("/safe"))
    XCTAssertNil(reopened.tab(id: badTabId)?.url, "不正スキームのタブ URL は nil へ無害化する")
    XCTAssertEqual(reopened.closedTabs.map(\.url), [url("/closed-ok")], "不正な閉じたタブ行は読み飛ばす")
  }

  // MARK: - 未来版と排他ロック競合

  /// 未来版 DB は退避も破壊もせず非永続フォールバックへ入り、排他ロック競合する 2 つ目のストアも
  /// 退避せず原本を汚さないまま 1 つ目の継続書き込みを妨げない。
  func testFutureVersionAndExclusiveLockConflictFallbackWithoutTouchingOriginalDB() throws {
    // 1. 排他ロック競合: first が握っている間に second を開くと second は非永続フォールバック。
    let firstTabURL = url("/from-first")
    let secondOnlyURL = url("/from-second")
    do {
      let first = openStore()
      let second = openStore()
      XCTAssertTrue(first.available)
      XCTAssertFalse(second.available, "排他ロック中は 2 つ目が .refused になる")
      XCTAssertNotNil(second.unavailableReason)
      XCTAssertEqual(try quarantined(), [], "排他競合では退避しない")

      let secondSpace = try XCTUnwrap(second.freeSpaces.first)
      let secondResult = second.openTab(in: secondSpace.id, url: secondOnlyURL, now: Self.baseTime)
      XCTAssertFalse(secondResult.didPersist, "非永続モードは DB へ書かず .inMemory を返す")
      XCTAssertTrue(secondResult.didSucceed)

      let firstSpace = try XCTUnwrap(first.freeSpaces.first)
      XCTAssertTrue(
        first.openTab(in: firstSpace.id, url: firstTabURL, now: Self.baseTime).didPersist)
    }

    // 解放後の再オープンでは first の書き込みだけが残り、second のメモリ操作は混入しない。
    do {
      let reopened = openStore()
      XCTAssertTrue(reopened.available)
      XCTAssertEqual(reopened.tabs.map(\.url), [firstTabURL])
    }

    // 2. 未来版 DB（user_version = 99）は原本を残したまま非永続フォールバックになる。
    try rawDatabase().exec("PRAGMA user_version = 99")
    let future = openStore()
    XCTAssertFalse(future.available)
    XCTAssertEqual(try quarantined(), [], "未来版は退避しない")
    let futureSpace = try XCTUnwrap(future.freeSpaces.first)
    XCTAssertTrue(
      future.openTab(in: futureSpace.id, url: url("/mem"), now: Self.baseTime).didSucceed)
    let version = try rawDatabase().select("PRAGMA user_version", []) { $0.int(at: 0) }.first
    XCTAssertEqual(version, 99, "原本の未来版 DB は書き換えない")
  }

  // MARK: - トランザクション巻き戻しと運転中破損

  /// 非破損エラーのトランザクション失敗は DB・メモリ双方を巻き戻して接続を維持し、
  /// 運転中の `SQLiteError.isBroken` 検知は原本を残したまま非永続モードへ移行して通知する。
  func testTransactionRollbackAndRuntimeCorruptionFallbackToInMemory() throws {
    let preservedURL = url("/before-fault")
    let rolledBackURL = url("/rolled-back")
    let afterBrokenURL = url("/after-broken")

    do {
      let store = openStore()
      let space = try XCTUnwrap(store.freeSpaces.first)
      let saved = try XCTUnwrap(
        store.openTab(in: space.id, url: preservedURL, title: "Saved", now: Self.baseTime).value)

      // 1. 非破損エラー（制約エラー）は DB・メモリとも巻き戻し、接続は維持する。
      let constraintResult: BrowserStoreCommitResult<Void> = store.commit { db, draft in
        let temp = BrowserTab(
          id: UUID(), spaceId: space.id, section: .today, position: 9,
          url: rolledBackURL, title: "Temp", createdAt: Self.baseTime, lastActiveAt: Self.baseTime)
        try db?.insertTab(temp, spaceKind: .free)
        draft.tabs.append(temp)
        throw SQLiteError(code: SQLITE_CONSTRAINT, message: "simulated constraint")
      }
      XCTAssertFalse(constraintResult.didSucceed)
      XCTAssertTrue(store.available, "非破損エラーでは接続を切らない")
      XCTAssertNil(store.unavailableReason)
      XCTAssertEqual(store.tabs.map(\.id), [saved.id], "メモリがロールバックされる")

      // 2. 運転中の SQLITE_CORRUPT 検知で原本を残したまま非永続モードへ移行する。
      let brokenResult: BrowserStoreCommitResult<Void> = store.commit { _, draft in
        draft.sheetRatioBps = 7000
        throw SQLiteError(code: SQLITE_CORRUPT, message: "simulated corruption")
      }
      XCTAssertFalse(brokenResult.didSucceed)
      XCTAssertFalse(store.available, "破損検知後は非永続モードへ移行する")
      XCTAssertNotNil(store.unavailableReason)
      XCTAssertEqual(
        store.sheetRatioBps, BrowserPersistence.defaultSheetRatioBps, "失敗 Tx の変更は反映しない")
      XCTAssertEqual(try quarantined(), [], "運転中破損の退避は次回起動へ任せる")

      // 以後の操作は .inMemory として閲覧を継続し、原本 DB へは書かない。
      let inMemoryResult = store.openTab(in: space.id, url: afterBrokenURL, now: Self.baseTime)
      XCTAssertTrue(inMemoryResult.didSucceed)
      XCTAssertFalse(inMemoryResult.didPersist)
    }

    let reopened = openStore()
    XCTAssertTrue(reopened.available)
    XCTAssertEqual(reopened.tabs.map(\.url), [preservedURL], "ロールバック分も非永続分も原本 DB へ残らない")
  }
}
