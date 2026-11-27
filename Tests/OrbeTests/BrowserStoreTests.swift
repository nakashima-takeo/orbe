import Foundation
import OrbeTestSupport
import SQLite3
import XCTest

@testable import Orbe

/// 内蔵ブラウザ永続ストア（`BrowserStore` / `BrowserDatabase` / `BrowserPersistence`）の
/// 初回シード・再起動往復・ドメイン不変条件・閉じたタブ復元・破損/排他フォールバックを守る。
/// DB は `TestScratch.caseDir` 配下の本物 SQLite を使用する。
///
/// 壊れると何が起きるか。再起動でプロファイル・自由/ローカルスペース・タブ構成・シート幅比率・
/// 閉じたタブ履歴が失われる。最後のプロファイルが消えたりローカルスペースへ Favorite が混入したりして
/// DB 整合が崩れる。別 workspace や削除済み非公開スペースの履歴が越境復元される。破損 DB で起動不能に陥る、
/// または 2 つ目の Orbe や運転中破損が原本 DB を破壊する。
final class BrowserStoreTests: OrbeTestCase {
  static let baseTime = Date(timeIntervalSince1970: 1_800_000_000)

  func openStore(language: Language = .ja, now: Date = baseTime) -> BrowserStore {
    BrowserStore(
      opening: BrowserPersistence.open(language: language, now: now),
      language: language,
      now: now)
  }

  func quarantined() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: TestScratch.caseDir.path)
      .filter { $0.hasPrefix("browser-broken-") }
  }

  func rawDatabase() throws -> SQLiteDatabase {
    try SQLiteDatabase(url: browserFolder().appendingPathComponent("db.sqlite"))
  }

  func url(_ path: String) -> URL {
    URL(string: "https://docs.orbe.dev\(path)")!
  }

  // MARK: - 初回シードと再起動往復

  /// 初回空 DB は既定構成を 1 Tx でシードし、プロファイル・自由/ローカルスペース・3 区分タブと並び順・
  /// 各スペースのアクティブタブ・閉じたタブ履歴・アクティブスペース選択・シート幅比率・削除待ちキューが
  /// 再起動往復で完全一致する。未知 workspace のローカルスペースも再起動で自動削除しない。
  func testInitialSeedAndFullRestartRoundTripPreserveAllState() throws {
    let t0 = Self.baseTime
    let wsA = UUID()
    let wsB = UUID()
    let wsRemoved = UUID()
    let (snapshot, deletedProfileId) = try populateRoundTripState(
      t0: t0, wsA: wsA, wsB: wsB, wsRemoved: wsRemoved)

    let reopened = openStore(language: .ja, now: t0.addingTimeInterval(60))
    XCTAssertTrue(reopened.available)
    assertMemoryEquivalent(reopened.memory, snapshot)
    XCTAssertEqual(reopened.pendingStoreRemovals.map(\.storeId), [deletedProfileId])
    XCTAssertNotNil(reopened.localSpace(for: wsA), "未知 workspace のローカルスペースは自動削除しない")
    XCTAssertNotNil(reopened.localSpace(for: wsB))
    XCTAssertNil(reopened.localSpace(for: wsRemoved), "removeLocalSpace の削除が再起動後も永続化")
    XCTAssertEqual(reopened.sheetRatio, 0.84, accuracy: 0.0001)
  }

  private func populateRoundTripState(
    t0: Date, wsA: UUID, wsB: UUID, wsRemoved: UUID
  ) throws -> (BrowserMemory, UUID) {
    let store = openStore(language: .ja, now: t0)
    XCTAssertTrue(store.available)
    XCTAssertEqual(store.profiles.map(\.name), ["personal", "work"])
    XCTAssertEqual(store.profiles.map(\.mcpAllowed), [false, true])
    XCTAssertEqual(store.freeSpaces.count, 3)
    XCTAssertEqual(store.activeSpaceSelection, .local)
    XCTAssertEqual(store.sheetRatioBps, BrowserPersistence.defaultSheetRatioBps)

    let work = store.profiles[1]
    let customProfile = try XCTUnwrap(
      store.createProfile(name: "qa", color: .teal, mcpAllowed: false, now: t0).value)
    let disposable = try XCTUnwrap(
      store.createProfile(name: "temp", color: .pink, mcpAllowed: false, now: t0).value)
    _ = store.updateProfile(customProfile.id, name: "staging", color: .purple, mcpAllowed: true)

    let customSpace = try XCTUnwrap(
      store.createFreeSpace(name: "設計", icon: .code, profileId: disposable.id, now: t0).value)
    _ = store.updateFreeSpace(customSpace.id, name: "仕様", icon: .globe)
    XCTAssertTrue(
      store.deleteProfile(disposable.id, reassigningTo: customProfile.id, now: t0).didPersist)

    let localA = try XCTUnwrap(store.setCurrentWorkspace(wsA, now: t0).value)
    let localB = try XCTUnwrap(store.setCurrentWorkspace(wsB, now: t0).value)
    let localRemoved = try XCTUnwrap(store.setCurrentWorkspace(wsRemoved, now: t0).value)
    XCTAssertEqual(localA.profileId, work.id, "ローカルスペースの既定プロファイルは MCP 公開の先頭")

    _ = store.openTab(
      in: localRemoved.id, url: url("/gone"), title: "Gone", activate: true, now: t0)
    XCTAssertEqual(store.removeLocalSpace(for: wsRemoved).value?.count, 1)

    _ = store.openTab(
      in: customSpace.id, section: .favorite, url: url("/fav"), title: "Fav", activate: false,
      now: t0)
    let pin = try XCTUnwrap(
      store.openTab(
        in: customSpace.id, section: .pinned, url: url("/pin"), title: "Pin", activate: true,
        now: t0
      ).value)
    let today = try XCTUnwrap(
      store.openTab(
        in: customSpace.id, section: .today, url: url("/t1"), title: "T1", activate: false,
        now: t0
      ).value)
    _ = store.openTab(
      in: localA.id, section: .today, url: url("/ws-a"), title: "A", activate: true, now: t0)
    _ = store.openTab(
      in: localB.id, section: .pinned, url: url("/ws-b"), title: "B", activate: true, now: t0)
    XCTAssertTrue(
      store.closeTab(today.id, recordClosed: true, now: t0.addingTimeInterval(30)).didPersist)
    XCTAssertEqual(store.activeTabId(in: customSpace.id), pin.id)
    XCTAssertTrue(store.selectSpace(.free(customSpace.id)).didPersist)
    XCTAssertEqual(store.setSheetRatio(0.95).value ?? 0, 0.84, accuracy: 0.0001, "上限へ丸めて保存")
    return (store.memory, disposable.id)
  }

  private func assertMemoryEquivalent(
    _ actual: BrowserMemory, _ expected: BrowserMemory,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(actual.profiles, expected.profiles, file: file, line: line)
    XCTAssertEqual(
      actual.spaces.filter { $0.kind == .free }.sorted(by: BrowserStore.spaceOrder),
      expected.spaces.filter { $0.kind == .free }.sorted(by: BrowserStore.spaceOrder),
      file: file, line: line)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: actual.spaces.map { ($0.id, $0) }),
      Dictionary(uniqueKeysWithValues: expected.spaces.map { ($0.id, $0) }),
      file: file, line: line)
    for space in expected.spaces {
      let actualTabs = actual.tabs.filter { $0.spaceId == space.id }.sorted(
        by: BrowserStore.tabOrder)
      let expectedTabs = expected.tabs.filter { $0.spaceId == space.id }.sorted(
        by: BrowserStore.tabOrder)
      XCTAssertEqual(actualTabs, expectedTabs, file: file, line: line)
    }
    XCTAssertEqual(actual.activeTabBySpace, expected.activeTabBySpace, file: file, line: line)
    XCTAssertEqual(actual.closedTabs, expected.closedTabs, file: file, line: line)
    XCTAssertEqual(
      actual.activeSpaceSelection, expected.activeSpaceSelection, file: file, line: line)
    XCTAssertEqual(actual.sheetRatioBps, expected.sheetRatioBps, file: file, line: line)
    XCTAssertEqual(
      actual.pendingStoreRemovals, expected.pendingStoreRemovals, file: file, line: line)
  }

  // MARK: - ドメイン不変条件・タブ移動・次選択

  /// プロファイル最低 1 件・自己付け替え禁止・自由スペース削除時の `browser_meta` 先行退避とカスケード、
  /// ローカルスペースへの `.favorite` 拒否（ストア＋DB 制約双方）を守る。
  func testProfileSpaceAndLocalFavoriteInvariantsAreEnforcedInStoreAndSQLite() throws {
    let t0 = Self.baseTime
    let wsId = UUID()
    let localSpaceId: UUID

    do {
      let store = openStore(now: t0)
      let personal = store.profiles[0]
      let work = store.profiles[1]

      XCTAssertFalse(
        store.deleteProfile(personal.id, reassigningTo: personal.id, now: t0).didSucceed)
      XCTAssertFalse(store.deleteProfile(personal.id, reassigningTo: UUID(), now: t0).didSucceed)
      XCTAssertTrue(store.deleteProfile(work.id, reassigningTo: personal.id, now: t0).didPersist)
      XCTAssertEqual(store.profiles.map(\.id), [personal.id])
      XCTAssertEqual(store.profiles[0].position, 0)
      XCTAssertEqual(store.defaultLocalProfileId, personal.id, "公開プロファイル削除後も有効な先頭へ解決")
      XCTAssertFalse(
        store.deleteProfile(personal.id, reassigningTo: personal.id, now: t0).didSucceed,
        "最後の 1 件は削除不可")

      // アクティブな自由スペースを順に削除すると残存自由先頭→最後は .local へ退避する。
      let freeIds = store.freeSpaces.map(\.id)
      XCTAssertTrue(store.selectSpace(.free(freeIds[0])).didPersist)
      let doomedTab = try XCTUnwrap(
        store.openTab(in: freeIds[0], url: url("/doomed"), title: "D", activate: true, now: t0)
          .value)
      XCTAssertTrue(store.closeTab(doomedTab.id, recordClosed: true, now: t0).didPersist)
      XCTAssertEqual(store.closedTabs.count, 1)

      XCTAssertTrue(store.deleteFreeSpace(freeIds[0]).didPersist)
      XCTAssertEqual(store.activeSpaceSelection, .free(freeIds[1]), "残存自由スペース先頭へ退避")
      XCTAssertTrue(store.closedTabs.isEmpty, "削除スペースの閉じたタブ履歴も連動消去")
      XCTAssertEqual(store.freeSpaces.map(\.position), [0, 1], "残存自由スペースの position を密連番化")

      XCTAssertTrue(store.deleteFreeSpace(freeIds[1]).didPersist)
      XCTAssertTrue(store.deleteFreeSpace(freeIds[2]).didPersist)
      XCTAssertEqual(store.activeSpaceSelection, .local, "自由スペース全削除時は .local へ退避")

      let local = try XCTUnwrap(store.setCurrentWorkspace(wsId, now: t0).value)
      localSpaceId = local.id
      XCTAssertFalse(
        store.openTab(in: local.id, section: .favorite, url: url("/f"), now: t0).didSucceed,
        "ローカルスペースへ favorite 作成不可")
      let localPinned = try XCTUnwrap(
        store.openTab(in: local.id, section: .pinned, url: url("/p"), now: t0).value)
      XCTAssertFalse(
        store.moveTab(localPinned.id, to: .favorite, now: t0).didSucceed,
        "ローカルスペースで favorite へ移動不可")
    }

    // DB の CHECK 制約単体でもローカルスペースの favorite 挿入を拒否する。
    let db = try rawDatabase()
    try db.exec("PRAGMA foreign_keys = ON")
    XCTAssertThrowsError(
      try db.run(
        """
        INSERT INTO tabs (id, space_id, space_kind, section, position, url, title, created_at,
          last_active_at)
        VALUES (?, ?, 'local', 'favorite', 0, 'https://docs.orbe.dev/x', '', 0, 0)
        """, [.text(UUID().uuidString), .text(localSpaceId.uuidString)]),
      "DB の CHECK 制約もローカルスペースへの favorite 混入を拒否する")
  }

  /// `moveTab` の密連番化と `TODAY` 降格時のみの `lastActiveAt` リセット、
  /// およびアクティブタブ閉鎖時の次選択順（同区分直後→直前→他区分 `favorite→pinned→today`→`nil`）を守る。
  func testMoveTabOrderDemotionTimestampAndCloseTabFallbackOrder() throws {
    let t0 = Self.baseTime
    let t1 = t0.addingTimeInterval(3600)
    let t2 = t0.addingTimeInterval(7200)
    let store = openStore(now: t0)
    let space = try XCTUnwrap(store.freeSpaces.first)

    let fav = try XCTUnwrap(
      store.openTab(in: space.id, section: .favorite, url: url("/fav"), activate: false, now: t0)
        .value)
    let pin = try XCTUnwrap(
      store.openTab(in: space.id, section: .pinned, url: url("/pin"), activate: false, now: t0)
        .value)
    let a = try XCTUnwrap(
      store.openTab(in: space.id, section: .today, url: url("/a"), activate: false, now: t0).value)
    let b = try XCTUnwrap(
      store.openTab(in: space.id, section: .today, url: url("/b"), activate: true, now: t0).value)
    let c = try XCTUnwrap(
      store.openTab(in: space.id, section: .today, url: url("/c"), activate: false, now: t0).value)

    // TODAY 内並べ替えは密連番化するが lastActiveAt を延命しない。
    XCTAssertTrue(store.moveTab(c.id, to: .today, index: 0, now: t1).didPersist)
    XCTAssertEqual(store.tabs(in: space.id, section: .today).map(\.id), [c.id, a.id, b.id])
    XCTAssertEqual(store.tabs(in: space.id, section: .today).map(\.position), [0, 1, 2])
    XCTAssertEqual(store.tab(id: c.id)?.lastActiveAt, t0, "同区分並べ替えでは lastActiveAt を延命しない")

    // PINNED → TODAY 降格時だけ lastActiveAt を now へ更新する。
    XCTAssertTrue(store.moveTab(pin.id, to: .today, index: nil, now: t2).didPersist)
    XCTAssertEqual(store.tab(id: pin.id)?.lastActiveAt, t2, "TODAY 降格時は即整理されないよう更新")

    // 現在の TODAY 順は [c, a, b, pin]。アクティブ b を閉じると直後 pin → 直前 a → c → 他区分先頭 fav → nil。
    XCTAssertTrue(store.selectTab(b.id).didPersist)
    XCTAssertTrue(store.closeTab(b.id, now: t2).didPersist)
    XCTAssertEqual(store.activeTabId(in: space.id), pin.id, "同区分の直後タブへ移る")
    XCTAssertTrue(store.closeTab(pin.id, now: t2).didPersist)
    XCTAssertEqual(store.activeTabId(in: space.id), a.id, "末尾閉鎖時は同区分の直前タブへ移る")
    XCTAssertTrue(store.closeTab(a.id, now: t2).didPersist)
    XCTAssertEqual(store.activeTabId(in: space.id), c.id)
    XCTAssertTrue(store.closeTab(c.id, now: t2).didPersist)
    XCTAssertEqual(store.activeTabId(in: space.id), fav.id, "同区分が空なら他区分先頭へ移る")
    XCTAssertTrue(store.closeTab(fav.id, now: t2).didPersist)
    XCTAssertNil(store.activeTabId(in: space.id), "全タブ消滅時は nil")
  }

  // MARK: - 閉じたタブ履歴と復元

  /// 手動閉鎖・手動 `clearTodayTabs` のみ上限 50 件の厳密 LIFO で記録し、URL なし・`recordClosed: false`・
  /// 自動整理分は積まない。`reopenClosedTab` は元スペースへ復元し、他 workspace のローカル履歴はスキップ、
  /// スペース削除時は非公開履歴が越境復元されない。
  func testClosedTabHistoryLimitLIFOScopeIsolationAndReopen() throws {
    let t0 = Self.baseTime
    let wsA = UUID()
    let wsB = UUID()
    let store = openStore(now: t0)
    let freePersonal = store.freeSpaces[0]
    let freeWork = store.freeSpaces[1]
    let localA = try XCTUnwrap(store.setCurrentWorkspace(wsA, now: t0).value)

    // URL なし・recordClosed: false・自動整理は履歴へ積まない。
    let emptyTab = try XCTUnwrap(store.openTab(in: freeWork.id, url: nil, now: t0).value)
    let silentTab = try XCTUnwrap(
      store.openTab(in: freeWork.id, url: url("/silent"), now: t0).value)
    let oldTab = try XCTUnwrap(
      store.openTab(
        in: freeWork.id, url: url("/expired"), now: t0.addingTimeInterval(-BrowserStore.todayTabTTL)
      ).value)
    XCTAssertTrue(store.closeTab(emptyTab.id, recordClosed: true, now: t0).didPersist)
    XCTAssertTrue(store.closeTab(silentTab.id, recordClosed: false, now: t0).didPersist)
    XCTAssertEqual(store.pruneExpiredTodayTabs(now: t0, protectedTabId: nil).value, [oldTab.id])
    XCTAssertTrue(store.closedTabs.isEmpty)

    // 55 件閉じると最新 50 件のみ LIFO 保持する（古い 0..4 は切り捨て）。
    for i in 0..<55 {
      let tab = try XCTUnwrap(
        store.openTab(
          in: freeWork.id, url: url("/bulk/\(i)"), title: "T\(i)", activate: false, now: t0
        ).value)
      XCTAssertTrue(
        store.closeTab(tab.id, recordClosed: true, now: t0.addingTimeInterval(Double(i))).didPersist
      )
    }
    XCTAssertEqual(store.closedTabs.count, BrowserStore.closedTabLimit)
    XCTAssertEqual(store.closedTabs.first?.url, url("/bulk/54"))
    XCTAssertEqual(store.closedTabs.last?.url, url("/bulk/5"))

    // clearTodayTabs も URL 付きタブを履歴へ積む。
    _ = store.openTab(
      in: freePersonal.id, section: .today, url: url("/private"), title: "Private", activate: true,
      now: t0)
    _ = store.openTab(in: freePersonal.id, section: .today, url: nil, activate: false, now: t0)
    XCTAssertEqual(
      store.clearTodayTabs(in: freePersonal.id, now: t0.addingTimeInterval(100)).value?.count, 2)
    XCTAssertEqual(store.closedTabs.first?.url, url("/private"))

    // 個人スペースを削除すると配下履歴も消え、仕事スペース側へ越境復元されない。
    XCTAssertTrue(store.deleteFreeSpace(freePersonal.id).didPersist)
    XCTAssertFalse(store.closedTabs.contains(where: { $0.url == url("/private") }))

    // wsA のローカルタブを閉じた後 wsB へ移ると、wsB では wsA ローカル履歴をスキップして自由スペース履歴を復元し、
    // wsA へ戻ると wsA のローカル履歴を元のローカルスペースへ復元できる。
    let localATab = try XCTUnwrap(
      store.openTab(in: localA.id, url: url("/local-a"), title: "LA", activate: true, now: t0).value
    )
    XCTAssertTrue(
      store.closeTab(localATab.id, recordClosed: true, now: t0.addingTimeInterval(200)).didPersist)
    _ = store.setCurrentWorkspace(wsB, now: t0.addingTimeInterval(210))

    let restoredInB = try XCTUnwrap(
      store.reopenClosedTab(now: t0.addingTimeInterval(220)).value ?? nil)
    XCTAssertEqual(restoredInB.url, url("/bulk/54"), "他 workspace のローカル履歴はスキップする")
    XCTAssertEqual(restoredInB.spaceId, freeWork.id)
    XCTAssertEqual(store.activeSpaceSelection, .free(freeWork.id))

    _ = store.setCurrentWorkspace(wsA, now: t0.addingTimeInterval(230))
    let restoredInA = try XCTUnwrap(
      store.reopenClosedTab(now: t0.addingTimeInterval(240)).value ?? nil)
    XCTAssertEqual(restoredInA.url, url("/local-a"), "元の workspace へ戻ればローカル履歴を復元できる")
    XCTAssertEqual(restoredInA.spaceId, localA.id)
    XCTAssertEqual(store.activeSpaceSelection, .local)
  }
}
