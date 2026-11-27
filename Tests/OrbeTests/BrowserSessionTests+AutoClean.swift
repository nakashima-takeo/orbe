import AppKit
import OrbeTestSupport
import SQLite3
import XCTest

@testable import Orbe

/// 12 時間自動整理（起動時一律整理・運転中の表示中アクティブ 1 枚保護・表示ライフサイクル連動の
/// `lastActiveAt` 更新・閉鎖中非延命・`BrowserTabCleaner` の壁時計予約／スリープ復帰／時計変更／
/// 失敗時無限ループ防止）を守る。
///
/// 壊れると何が起きるか。再起動しても古い放置タブが溜まり続ける、または運転中に見ているタブが
/// 目の前から消える。閉じた直後やタブ切替直後に直前まで見ていたタブが即消滅する。閉鎖中の切替で
/// 放置タブが永遠に延命される。スリープ明けに自動整理が走らない、あるいは DB 失敗時に無限再帰する。
extension BrowserSessionTests {
  // MARK: - 起動時一律整理

  /// 起動時（`start`）はアクティブタブを含めてちょうど 12 時間以上経過した `TODAY` タブを全スペースから
  /// 一律整理し、`PINNED`/`favorite`/12h 未満/時計巻き戻りタブは保持する。自動整理分は履歴へ積まない。
  func testStartupPruneRemovesExpiredTodayIncludingActiveWithoutRecordingClosedHistory() throws {
    let t0 = Self.baseTime
    let ttl = BrowserStore.todayTabTTL
    let startAt = t0.addingTimeInterval(ttl)

    let exactActiveId: UUID
    let olderInactiveId: UUID
    let freshId: UUID
    let clockRollbackId: UUID
    let pinnedId: UUID
    let favoriteId: UUID

    do {
      let store = openPersistentStore(now: t0)
      let freeSpace = try XCTUnwrap(store.freeSpaces.first)
      let url = URL(string: "https://docs.orbe.dev/tab")!

      exactActiveId = try XCTUnwrap(
        store.openTab(in: freeSpace.id, section: .today, url: url, activate: true, now: t0).value?
          .id)
      olderInactiveId = try XCTUnwrap(
        store.openTab(
          in: freeSpace.id, section: .today, url: url, activate: false,
          now: t0.addingTimeInterval(-3600)
        ).value?.id)
      freshId = try XCTUnwrap(
        store.openTab(
          in: freeSpace.id, section: .today, url: url, activate: false,
          now: t0.addingTimeInterval(1)
        ).value?.id)
      clockRollbackId = try XCTUnwrap(
        store.openTab(
          in: freeSpace.id, section: .today, url: url, activate: false,
          now: startAt.addingTimeInterval(3600)
        ).value?.id)
      pinnedId = try XCTUnwrap(
        store.openTab(
          in: freeSpace.id, section: .pinned, url: url, activate: false,
          now: t0.addingTimeInterval(-ttl)
        ).value?.id)
      favoriteId = try XCTUnwrap(
        store.openTab(
          in: freeSpace.id, section: .favorite, url: url, activate: false,
          now: t0.addingTimeInterval(-ttl)
        ).value?.id)
      XCTAssertTrue(store.selectSpace(.free(freeSpace.id)).didPersist)
    }

    let reopened = openPersistentStore(now: startAt)
    let session = BrowserSession(store: reopened, now: { startAt })
    session.start(initialWorkspaceId: UUID())

    XCTAssertNil(reopened.tab(id: exactActiveId), "ちょうど 12h 経過のアクティブ TODAY は起動時に整理")
    XCTAssertNil(reopened.tab(id: olderInactiveId), "12h 超過の非アクティブ TODAY も整理")
    XCTAssertNotNil(reopened.tab(id: freshId), "12h 未満（1 秒手前）は保持")
    XCTAssertNotNil(reopened.tab(id: clockRollbackId), "時計巻き戻り（未来時刻）は誤削除しない")
    XCTAssertNotNil(reopened.tab(id: pinnedId), "PINNED は整理対象外")
    XCTAssertNotNil(reopened.tab(id: favoriteId), "favorite は整理対象外")
    XCTAssertTrue(reopened.closedTabs.isEmpty, "自動整理は閉じたタブ復元履歴へ積まない")
  }

  // MARK: - 運転中の保護と表示ライフサイクル連動 lastActiveAt

  /// 運転中はブラウザ開放中で表示中のアクティブ 1 枚のみ保護し、開放・閉鎖直前・開放中のタブ／スペース／
  /// ローカル workspace 切替で離脱側と新表示側の `TODAY` タブ `lastActiveAt` を更新する。
  func testRuntimeProtectionAndLastActiveUpdatesOnOpenCloseAndOpenSwitches() throws {
    let ttl = BrowserStore.todayTabTTL
    var clock = Self.baseTime
    let wsA = UUID()
    let wsB = UUID()
    let store = openPersistentStore(now: clock)
    let session = BrowserSession(
      store: store,
      cleaner: BrowserTabCleaner(now: { clock }, arm: { _, _ in {} }),
      now: { clock })
    session.start(initialWorkspaceId: wsA)

    let free0 = store.freeSpaces[0]
    let free1 = store.freeSpaces[1]
    let tabFree0 = try XCTUnwrap(session.openTab(in: free0.id, section: .today, activate: true))
    let tabFree0Bg = try XCTUnwrap(session.openTab(in: free0.id, section: .today, activate: false))
    let tabFree1 = try XCTUnwrap(session.openTab(in: free1.id, section: .today, activate: false))
    let localA = try XCTUnwrap(store.localSpace(for: wsA))
    let tabLocalA = try XCTUnwrap(session.openTab(in: localA.id, section: .today, activate: false))
    XCTAssertTrue(session.selectSpace(.free(free0.id)))

    // 1. 1 時間後に開放 → 表示された tabFree0 のみ lastActiveAt 更新。
    clock = Self.baseTime.addingTimeInterval(3600)
    session.setBrowserOpen(true)
    XCTAssertEqual(store.tab(id: tabFree0.id)?.lastActiveAt, clock, "開放時に表示中 TODAY を更新")
    XCTAssertEqual(store.tab(id: tabFree0Bg.id)?.lastActiveAt, Self.baseTime)

    // 2. さらに 12h 経過（t0 + 13h）: 表示中 tabFree0 のみ保護され、非表示の tabFree0Bg は整理される。
    clock = Self.baseTime.addingTimeInterval(ttl + 3600)
    let swept = session.sweepExpiredTodayTabs()
    XCTAssertTrue(swept.contains(tabFree0Bg.id), "非アクティブな期限超過 TODAY は整理される")
    XCTAssertNotNil(store.tab(id: tabFree0.id), "開放中かつ表示中のアクティブ 1 枚は保護される")

    // 3. 開放中にスペース切替 → 離脱直前の tabFree0 と新表示の tabFree1 相当を更新（新タブ作成で確認）。
    let tabFree1Fresh = try XCTUnwrap(
      session.openTab(in: free1.id, section: .today, activate: false))
    XCTAssertNil(store.tab(id: tabFree1.id), "前提: 古い tabFree1 は先ほど整理済み")
    XCTAssertNil(store.tab(id: tabLocalA.id))
    clock = clock.addingTimeInterval(600)
    XCTAssertTrue(session.selectTab(tabFree1Fresh.id))
    XCTAssertEqual(store.tab(id: tabFree0.id)?.lastActiveAt, clock, "開放中の切替で離脱側も更新")
    XCTAssertEqual(store.tab(id: tabFree1Fresh.id)?.lastActiveAt, clock, "開放中の切替で新表示側も更新")

    // 4. .local 表示中の workspace 切替でも離脱側・新表示側の両方を更新する。
    let localATab = try XCTUnwrap(session.openTab(in: localA.id, section: .today, activate: true))
    session.syncCurrentWorkspace(wsB)
    let localB = try XCTUnwrap(store.localSpace(for: wsB))
    let localBTab = try XCTUnwrap(session.openTab(in: localB.id, section: .today, activate: true))
    clock = clock.addingTimeInterval(600)
    session.syncCurrentWorkspace(wsA)
    XCTAssertEqual(store.tab(id: localBTab.id)?.lastActiveAt, clock, "ローカル WS 切替で離脱側を更新")
    XCTAssertEqual(store.tab(id: localATab.id)?.lastActiveAt, clock, "ローカル WS 切替で新表示側を更新")

    // 5. ブラウザ閉鎖直前に表示中タブを更新し、閉鎖直後は消えず 12h 後に閉鎖中のため整理される。
    clock = clock.addingTimeInterval(1800)
    session.setBrowserOpen(false)
    XCTAssertEqual(store.tab(id: localATab.id)?.lastActiveAt, clock, "閉鎖直前に表示中タブを更新")
    XCTAssertTrue(session.sweepExpiredTodayTabs().isEmpty, "閉鎖直後は消えない")

    clock = clock.addingTimeInterval(ttl)
    XCTAssertTrue(
      session.sweepExpiredTodayTabs().contains(localATab.id), "閉鎖中はアクティブでも 12h で整理")
  }

  /// ブラウザ閉鎖中のタブ切替・スペース切替・workspace 切替では `lastActiveAt` を一切延命しない。
  func testClosedSwitchesDoNotExtendTodayTabLastActiveAt() throws {
    var clock = Self.baseTime
    let wsA = UUID()
    let wsB = UUID()
    let store = openPersistentStore(now: clock)
    let session = BrowserSession(
      store: store,
      cleaner: BrowserTabCleaner(now: { clock }, arm: { _, _ in {} }),
      now: { clock })
    session.start(initialWorkspaceId: wsA)

    let free0 = store.freeSpaces[0]
    let free1 = store.freeSpaces[1]
    let tab0 = try XCTUnwrap(session.openTab(in: free0.id, section: .today, activate: true))
    let tab1 = try XCTUnwrap(session.openTab(in: free1.id, section: .today, activate: false))
    let localA = try XCTUnwrap(store.localSpace(for: wsA))
    let localTab = try XCTUnwrap(session.openTab(in: localA.id, section: .today, activate: false))
    XCTAssertFalse(session.isBrowserOpen, "前提: ブラウザ閉鎖中")

    clock = Self.baseTime.addingTimeInterval(7200)
    XCTAssertTrue(session.selectSpace(.free(free1.id)))
    XCTAssertTrue(session.selectTab(tab1.id))
    XCTAssertTrue(session.selectSpace(.local))
    session.syncCurrentWorkspace(wsB)
    session.syncCurrentWorkspace(wsA)

    XCTAssertEqual(store.tab(id: tab0.id)?.lastActiveAt, Self.baseTime, "閉鎖中の切替で延命しない")
    XCTAssertEqual(store.tab(id: tab1.id)?.lastActiveAt, Self.baseTime, "閉鎖中のタブ選択で延命しない")
    XCTAssertEqual(store.tab(id: localTab.id)?.lastActiveAt, Self.baseTime, "閉鎖中の WS 切替で延命しない")
  }

  // MARK: - BrowserTabCleaner 壁時計・通知・失敗保護・停止

  /// 壁時計予約の発火で整理→次期限再予約し、スリープ復帰・システム時計変更通知でも即整理する。
  /// 期限超過が残る失敗時は即時再予約で無限ループせず、`stop()` 後は通知を無視する。
  func testTabCleanerWallTimerWakeClockChangeFailureGuardAndStop() throws {
    let ttl = BrowserStore.todayTabTTL
    var clock = Self.baseTime
    var armed: (date: Date, fire: () -> Void)?
    let store = openPersistentStore(now: clock)
    let cleaner = BrowserTabCleaner(
      now: { clock },
      arm: { date, fire in
        armed = (date, fire)
        return { armed = nil }
      })
    let session = BrowserSession(store: store, cleaner: cleaner, now: { clock })
    session.start(initialWorkspaceId: UUID())
    let space = try XCTUnwrap(store.freeSpaces.first)

    let tab1 = try XCTUnwrap(session.openTab(in: space.id, section: .today, activate: false))
    clock = Self.baseTime.addingTimeInterval(600)
    let tab2 = try XCTUnwrap(session.openTab(in: space.id, section: .today, activate: false))
    clock = Self.baseTime.addingTimeInterval(1200)
    let tab3 = try XCTUnwrap(session.openTab(in: space.id, section: .today, activate: false))
    XCTAssertEqual(armed?.date, Self.baseTime.addingTimeInterval(ttl), "最早期限でタイマー予約")

    // 1. 壁時計タイマー発火で tab1 を整理し、次期限（tab2）へ再予約する。
    clock = Self.baseTime.addingTimeInterval(ttl)
    armed?.fire()
    XCTAssertNil(store.tab(id: tab1.id))
    XCTAssertNotNil(store.tab(id: tab2.id))
    XCTAssertEqual(armed?.date, Self.baseTime.addingTimeInterval(600 + ttl))

    // 2. スリープ復帰通知で期限到来済みの tab2 を即整理する。
    clock = Self.baseTime.addingTimeInterval(600 + ttl)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    nextTurn()
    XCTAssertNil(store.tab(id: tab2.id), "スリープ復帰通知で再計算・整理が走る")
    XCTAssertEqual(armed?.date, Self.baseTime.addingTimeInterval(1200 + ttl))

    // 3. システム時計変更通知で tab3 を即整理する。
    clock = Self.baseTime.addingTimeInterval(1200 + ttl)
    NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
    nextTurn()
    XCTAssertNil(store.tab(id: tab3.id), "時計変更通知で再計算・整理が走る")
    XCTAssertNil(armed, "残存 TODAY タブが無ければタイマー解除")

    // 4. stop() 後は通知が届いても整理が走らない。
    let afterStop = try XCTUnwrap(session.openTab(in: space.id, section: .today, activate: false))
    session.stop()
    XCTAssertNil(armed)
    clock = clock.addingTimeInterval(ttl + 60)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
    nextTurn()
    XCTAssertNotNil(store.tab(id: afterStop.id), "stop() 後は通知を無視する")

    // 5. 単体 BrowserTabCleaner: 整理しても過去期限が残り続ける失敗ケースで即時再 arm し無限ループしない。
    var armCalls = 0
    var sweepCalls = 0
    let duePast = Self.baseTime
    let guardCleaner = BrowserTabCleaner(
      now: { Self.baseTime.addingTimeInterval(10) },
      arm: { _, _ in
        armCalls += 1
        return {}
      },
      nextFireDate: { duePast },
      onSweep: { _ in sweepCalls += 1 })
    guardCleaner.start()
    XCTAssertEqual(sweepCalls, 1)
    XCTAssertEqual(armCalls, 0, "過去期限が残存しても即時再予約でループしない")
    guardCleaner.stop()
  }
}
