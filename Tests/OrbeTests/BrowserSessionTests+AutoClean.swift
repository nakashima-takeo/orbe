import AppKit
import OrbeTestSupport
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

  /// 運転中はブラウザ開放中で表示中のアクティブ 1 枚のみ保護し（壁時計タイマーも保護タブを除外して
  /// 次の非表示タブ期限で予約）、開放・閉鎖直前・開放中のタブ／スペース／ローカル workspace 切替で
  /// 離脱側と新表示側の `TODAY` タブ `lastActiveAt` を更新する。
  func testRuntimeProtectionAndLastActiveUpdatesOnOpenCloseAndOpenSwitches() throws {
    let ttl = BrowserStore.todayTabTTL
    var clock = Self.baseTime
    var armed: (date: Date, fire: () -> Void)?
    let wsA = UUID()
    let wsB = UUID()
    let store = openPersistentStore(now: clock)
    let cleaner = BrowserTabCleaner(
      now: { clock },
      arm: { date, fire in
        armed = (date, fire)
        return { armed = nil }
      })
    let session = BrowserSession(store: store, cleaner: cleaner, now: { clock })
    session.start(initialWorkspaceId: wsA)

    let free0 = store.freeSpaces[0]
    let free1 = store.freeSpaces[1]
    let tabFree0 = try XCTUnwrap(session.openTab(in: free0.id, section: .today, activate: true))
    clock = Self.baseTime.addingTimeInterval(120)
    let tabFree0Bg = try XCTUnwrap(session.openTab(in: free0.id, section: .today, activate: false))
    let tabFree1 = try XCTUnwrap(session.openTab(in: free1.id, section: .today, activate: false))
    let localA = try XCTUnwrap(store.localSpace(for: wsA))
    let tabLocalA = try XCTUnwrap(session.openTab(in: localA.id, section: .today, activate: false))
    XCTAssertTrue(session.selectSpace(.free(free0.id)))

    // 1. 開放中は表示中 tabFree0 を更新かつ保護対象から除外し、壁時計タイマーは非表示タブ期限へ張る。
    clock = Self.baseTime.addingTimeInterval(3600)
    session.setBrowserOpen(true)
    XCTAssertEqual(store.tab(id: tabFree0.id)?.lastActiveAt, clock, "開放時に表示中 TODAY を更新")
    XCTAssertEqual(
      store.tab(id: tabFree0Bg.id)?.lastActiveAt, Self.baseTime.addingTimeInterval(120))
    XCTAssertEqual(
      armed?.date, Self.baseTime.addingTimeInterval(120 + ttl),
      "開放中は保護タブを除外した最早期限（非表示タブ）で壁時計予約する")

    // 2. 壁時計タイマー発火（t0 + 120s + 12h）: 非表示タブは整理され、表示中 tabFree0 は保護される。
    clock = Self.baseTime.addingTimeInterval(120 + ttl)
    armed?.fire()
    XCTAssertNil(store.tab(id: tabFree0Bg.id), "非アクティブな期限超過 TODAY は壁時計発火で整理される")
    XCTAssertNil(store.tab(id: tabFree1.id))
    XCTAssertNil(store.tab(id: tabLocalA.id))
    XCTAssertNotNil(store.tab(id: tabFree0.id), "開放中かつ表示中のアクティブ 1 枚は保護される")
    XCTAssertNil(armed, "保護タブ以外に残存 TODAY が無いため開放中は再予約しない")

    // 3. 開放中の selectSpace で離脱側・切替先双方を更新する（閉鎖中非延命テストの対の肯定検証）。
    let tabFree1Fresh = try XCTUnwrap(
      session.openTab(in: free1.id, section: .today, activate: false))
    XCTAssertTrue(store.selectTab(tabFree1Fresh.id).didPersist)
    XCTAssertTrue(store.selectSpace(.free(free0.id)).didPersist)
    clock = clock.addingTimeInterval(600)
    XCTAssertTrue(session.selectSpace(.free(free1.id)))
    XCTAssertEqual(
      store.tab(id: tabFree0.id)?.lastActiveAt, clock,
      "開放中の selectSpace で離脱側を更新（これが待たずに成り立たなければ testClosedSwitchesDoNotExtendTodayTabLastActiveAt も成り立たない）"
    )
    XCTAssertEqual(
      store.tab(id: tabFree1Fresh.id)?.lastActiveAt, clock,
      "開放中の selectSpace で切替先を更新（testClosedSwitchesDoNotExtendTodayTabLastActiveAt の対）")

    // 4. .local 表示中の workspace 切替と閉鎖直前の更新・保護解除後の壁時計再予約。
    try assertLocalSwitchAndCloseTimerRearm(
      LocalSwitchRearmContext(
        session: session, store: store, wsA: wsA, wsB: wsB, localAId: localA.id,
        clock: { clock }, advanceClock: { clock = clock.addingTimeInterval($0) },
        armedDate: { armed?.date }))
  }

  private struct LocalSwitchRearmContext {
    let session: BrowserSession
    let store: BrowserStore
    let wsA: UUID
    let wsB: UUID
    let localAId: UUID
    let clock: () -> Date
    let advanceClock: (TimeInterval) -> Void
    let armedDate: () -> Date?
  }

  private func assertLocalSwitchAndCloseTimerRearm(_ ctx: LocalSwitchRearmContext) throws {
    let ttl = BrowserStore.todayTabTTL
    let localATab = try XCTUnwrap(
      ctx.session.openTab(in: ctx.localAId, section: .today, activate: true))
    ctx.session.syncCurrentWorkspace(ctx.wsB)
    let localB = try XCTUnwrap(ctx.store.localSpace(for: ctx.wsB))
    let localBTab = try XCTUnwrap(
      ctx.session.openTab(in: localB.id, section: .today, activate: true))
    ctx.advanceClock(600)
    ctx.session.syncCurrentWorkspace(ctx.wsA)
    XCTAssertEqual(ctx.store.tab(id: localBTab.id)?.lastActiveAt, ctx.clock(), "ローカル WS 切替で離脱側を更新")
    XCTAssertEqual(ctx.store.tab(id: localATab.id)?.lastActiveAt, ctx.clock(), "ローカル WS 切替で新表示側を更新")

    ctx.advanceClock(1800)
    ctx.session.setBrowserOpen(false)
    let closeTime = ctx.clock()
    XCTAssertEqual(ctx.store.tab(id: localATab.id)?.lastActiveAt, closeTime, "閉鎖直前に表示中タブを更新")
    XCTAssertNotNil(ctx.armedDate(), "閉鎖で保護が外れ壁時計タイマーが再予約される")
    XCTAssertTrue(ctx.session.sweepExpiredTodayTabs().isEmpty, "閉鎖直後は消えない")

    ctx.advanceClock(ttl)
    XCTAssertTrue(
      ctx.session.sweepExpiredTodayTabs().contains(localATab.id), "閉鎖中はアクティブでも 12h で整理")
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

  /// アプリ終了経路の `stop(flushingActiveTab: true)` は開放中表示 `TODAY` タブの `lastActiveAt` を
  /// DB へ確定保存して再起動時 12 時間整理から守り、`flushingActiveTab: false`（`deinit` 相当）は無副作用停止する。
  func testStopFlushingActiveTabPersistsLastActiveAtWhileDefaultStopIsSideEffectFree() throws {
    let ttl = BrowserStore.todayTabTTL
    var clock = Self.baseTime
    let wsId = UUID()
    let tabId: UUID

    do {
      let store = openPersistentStore(now: clock)
      let session = BrowserSession(
        store: store, cleaner: BrowserTabCleaner(now: { clock }, arm: { _, _ in {} }),
        now: { clock })
      session.start(initialWorkspaceId: wsId)
      let space = try XCTUnwrap(store.freeSpaces.first)
      let tab = try XCTUnwrap(
        session.openTab(
          in: space.id, section: .today, url: URL(string: "https://docs.orbe.dev/live")!,
          activate: true))
      tabId = tab.id
      session.setBrowserOpen(true)

      // 1. flushingActiveTab: false は lastActiveAt を書き換えずに停止する。
      clock = Self.baseTime.addingTimeInterval(3600)
      session.stop(flushingActiveTab: false)
      XCTAssertEqual(
        store.tab(id: tabId)?.lastActiveAt, Self.baseTime,
        "既定 stop() は lastActiveAt へ副作用を出さない")

      // 2. 再開後に 12h 超閲覧して flushingActiveTab: true で終了すると DB へ確定保存し、2 回目も冪等。
      session.start(initialWorkspaceId: wsId)
      clock = Self.baseTime.addingTimeInterval(ttl + 600)
      let terminateAt = clock
      session.stop(flushingActiveTab: true)
      XCTAssertEqual(store.tab(id: tabId)?.lastActiveAt, terminateAt, "終了時に表示中 TODAY を確定保存")
      clock = terminateAt.addingTimeInterval(600)
      session.stop(flushingActiveTab: true)
      XCTAssertEqual(store.tab(id: tabId)?.lastActiveAt, terminateAt, "二重呼び出しは冪等")
    }

    // 直後の再起動では 12h 整理で消えず生存する。
    let restartAt = Self.baseTime.addingTimeInterval(ttl + 660)
    let reopened = openPersistentStore(now: restartAt)
    let restarted = BrowserSession(store: reopened, now: { restartAt })
    restarted.start(initialWorkspaceId: wsId)
    XCTAssertNotNil(reopened.tab(id: tabId), "終了直前まで見ていた TODAY タブが再起動で消えない")
  }

  /// `BrowserTabCleaner.pass()` は掃討判定と再予約判定で同一 `now()` スナップショットを使い、
  /// 実行中に壁時計が期限を跨いでもタイマーが消滅せず再予約される。
  func testTabCleanerPassUsesSingleNowSnapshotWhenClockCrossesDueDuringPass() {
    let base = Self.baseTime
    let due1 = base.addingTimeInterval(5)
    let due2 = base.addingTimeInterval(10)

    // 1. 掃討未発火パス: 1 回目 now() が due1 未満でも、実行中に時計が進む構成で確実に due1 を予約する。
    var calls1 = 0
    var armed1: Date?
    let cleaner1 = BrowserTabCleaner(
      now: {
        calls1 += 1
        return calls1 == 1 ? base : base.addingTimeInterval(20)
      },
      arm: { date, _ in
        armed1 = date
        return { armed1 = nil }
      },
      nextFireDate: { due1 },
      onSweep: { _ in XCTFail("due1 > current なので掃討しない") })
    cleaner1.start()
    XCTAssertEqual(calls1, 1, "pass() 内で now() は 1 回だけ読む")
    XCTAssertEqual(armed1, due1, "時計が期限を跨いでもタイマーが消滅せず予約される")
    cleaner1.stop()

    // 2. 掃討発火パス: onSweep の SQLite 書込中に壁時計が次期限 due2 を跨いでも再予約が消滅しない。
    var clock2 = due1
    var swept = false
    var armed2: Date?
    let cleaner2 = BrowserTabCleaner(
      now: { clock2 },
      arm: { date, _ in
        armed2 = date
        return { armed2 = nil }
      },
      nextFireDate: { swept ? due2 : due1 },
      onSweep: { _ in
        swept = true
        clock2 = due2.addingTimeInterval(1)
      })
    cleaner2.start()
    XCTAssertTrue(swept)
    XCTAssertEqual(armed2, due2, "onSweep 中に時計が次期限を跨いでも次タイマーを再予約する")
    cleaner2.stop()
  }
}
