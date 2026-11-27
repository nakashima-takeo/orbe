import AppKit
import OrbeTestSupport
import SQLite3
import WebKit
import XCTest

@testable import Orbe

/// プロファイル削除時の非同期 OS ストア削除遅延・有限回再試行・停止キャンセル・直列ドレイン、
/// 複数スペース一括破棄と `closed_tabs` 越境隔離、運転中破損直後の `.local` 継続、および
/// DB コミット失敗時のランタイム非破棄を守る。
///
/// 壊れると何が起きるか。解放前同期削除で OS ストア削除が毎回失敗して Cookie が残留する、
/// 再試行が無限化・停止漏れする、連続削除でキュー重複や取りこぼしが起きる、複数スペースを跨ぐ
/// プロファイル削除で旧 Cookie や閉じたタブ履歴が別プロファイルへ越境する、運転中破損直後に
/// `.local` が操作不能になる、あるいは DB 書込失敗なのに閲覧中 WebView だけ破壊される。
extension BrowserSessionTests {
  // MARK: - 遅延 OS ストア削除・有限回再試行・stop キャンセル

  private struct ScheduledRemoval {
    let delay: TimeInterval
    let work: @MainActor () -> Void
    var cancelled = false
  }

  /// `deleteProfile` の OS ストア削除は同一ターンで同期実行せず `delay: 0` で遅延起動し（解放後）、
  /// 失敗時は `storeRemovalRetryDelays` に従って有限回だけ遅延再試行し、`stop()` で予約を取り消す。
  func testDeleteProfileDefersRemovalRetriesFinitelyAndCancelsOnStop() throws {
    let store = openPersistentStore()
    let survivor = store.profiles[0]
    let victimA = store.profiles[1]
    let victimB = try XCTUnwrap(
      store.createProfile(name: "extra", color: .teal, mcpAllowed: false, now: Self.baseTime).value)

    var scheduled: [ScheduledRemoval] = []
    var removerCalls: [UUID] = []
    var shouldSucceed = false
    let registry = BrowserDataStoreRegistry(
      isIsolated: { false },
      remover: { id, done in
        removerCalls.append(id)
        done(shouldSucceed)
      })
    let session = BrowserSession(
      store: store, dataStores: registry,
      scheduleStoreRemoval: { delay, work in
        let idx = scheduled.count
        scheduled.append(ScheduledRemoval(delay: delay, work: work))
        return { scheduled[idx].cancelled = true }
      })
    session.storeRemovalRetryDelays = [0.25, 0.5]
    session.start(initialWorkspaceId: UUID())
    weak var weakOldRuntime: BrowserTabRuntime?
    weak var weakOldWebView: WKWebView?
    autoreleasepool {
      let browser = makeHostedLayer(session: session).browser
      var finishes = 0
      browser.onNavigationFinish = { finishes += 1 }
      browser.setMode(.sheet, animated: false)
      browser.loadHTMLString("<p>victim</p>", baseURL: nil)
      pumpMain(until: { finishes >= 1 }, timeout: 5, "victim ページ読み込み完了")
      weakOldRuntime = browser.mountedRuntime
      weakOldWebView = browser.webView
      XCTAssertNotNil(weakOldRuntime)
      XCTAssertNotNil(weakOldWebView)
    }

    // 1. deleteProfile 直後は同期で remover を呼ばず、delay: 0 の遅延実行を予約する。
    XCTAssertTrue(session.deleteProfile(victimA.id, reassigningTo: survivor.id))
    XCTAssertTrue(removerCalls.isEmpty, "同一ターンでは OS ストア削除を同期起動しない")
    XCTAssertEqual(scheduled.map(\.delay), [0], "次 RunLoop 遅延（delay: 0）を予約する")
    XCTAssertNil(weakOldRuntime, "deleteProfile 内の autoreleasepool 完了時点で旧ランタイムは解放済み")
    pumpMain(until: { weakOldWebView == nil }, timeout: 5, "旧 WKWebView が解放される")

    // 2. 初回・1 回目・2 回目の失敗で [0.25, 0.5] を有限回再試行し、上限到達後は再予約しない。
    scheduled[0].work()
    XCTAssertEqual(removerCalls, [victimA.id])
    XCTAssertEqual(scheduled.map(\.delay), [0, 0.25])
    scheduled[1].work()
    XCTAssertEqual(scheduled.map(\.delay), [0, 0.25, 0.5])
    scheduled[2].work()
    XCTAssertEqual(removerCalls, [victimA.id, victimA.id, victimA.id])
    XCTAssertEqual(scheduled.count, 3, "有限回（2 回の再試行）上限を超えたら再予約しない")
    XCTAssertEqual(store.pendingStoreRemovals.map(\.storeId), [victimA.id])

    // 3. stop() は予約済み再試行をキャンセルし、別プロファイル削除後に成功すればキューを消化する。
    XCTAssertTrue(session.deleteProfile(victimB.id, reassigningTo: survivor.id))
    let pendingIdx = scheduled.count - 1
    XCTAssertFalse(scheduled[pendingIdx].cancelled)
    session.stop()
    XCTAssertTrue(scheduled[pendingIdx].cancelled, "stop() で予約済み OS ストア削除をキャンセルする")

    shouldSucceed = true
    session.start(initialWorkspaceId: UUID())
    XCTAssertTrue(store.pendingStoreRemovals.isEmpty, "再開時の再試行成功で全キューが消化される")
  }

  // MARK: - 非同期直列ドレイン・追加再ドレイン・途中隔離

  /// `drainPendingStoreRemovals` は非同期実行中の重複起動を抑止し、処理中に追加された削除対象を
  /// 完了後に再ドレインし、処理途中で隔離へ転落した場合は残件の OS 削除を中断する。
  func testDrainPendingStoreRemovalsSerializesRequeuesAndStopsOnMidflightIsolation() throws {
    let store = openPersistentStore()
    let survivor = store.profiles[0]
    let p1 = store.profiles[1]
    let p2 = try XCTUnwrap(
      store.createProfile(name: "p2", color: .amber, mcpAllowed: false, now: Self.baseTime).value)
    let p3 = try XCTUnwrap(
      store.createProfile(name: "p3", color: .purple, mcpAllowed: false, now: Self.baseTime).value)

    var isolated = false
    var pendingCallbacks: [(id: UUID, done: (Bool) -> Void)] = []
    var scheduled: [@MainActor () -> Void] = []
    let registry = BrowserDataStoreRegistry(
      isIsolated: { isolated },
      remover: { id, done in pendingCallbacks.append((id, done)) })
    let session = BrowserSession(
      store: store, dataStores: registry,
      scheduleStoreRemoval: { _, work in
        scheduled.append(work)
        return {}
      })
    session.start(initialWorkspaceId: UUID())

    // 1. p1 削除開始（非同期保留中）に p2 削除＋手動 drain を重ねても同時実行は 1 件のまま。
    XCTAssertTrue(session.deleteProfile(p1.id, reassigningTo: survivor.id))
    scheduled.removeFirst()()
    XCTAssertEqual(pendingCallbacks.map(\.id), [p1.id])

    XCTAssertTrue(session.deleteProfile(p2.id, reassigningTo: survivor.id))
    session.drainPendingStoreRemovals()
    XCTAssertEqual(pendingCallbacks.count, 1, "実行中は重複起動せず直列化する")

    // p1 完了で処理中追加分 p2 の再ドレインが予約され、実行すると p2 が消化される。
    pendingCallbacks.removeFirst().done(true)
    XCTAssertFalse(scheduled.isEmpty, "処理中追加分があれば次パスを再予約する")
    while !scheduled.isEmpty { scheduled.removeFirst()() }
    XCTAssertEqual(pendingCallbacks.map(\.id), [p2.id], "処理中追加分 p2 を再ドレインする")
    pendingCallbacks.removeFirst().done(true)
    XCTAssertTrue(store.pendingStoreRemovals.isEmpty)

    // 2. 2 件連続キューの 1 件目処理途中で隔離へ転落すると、2 件目の remover を呼ばず中断する。
    let p4 = try XCTUnwrap(
      store.createProfile(name: "p4", color: .pink, mcpAllowed: false, now: Self.baseTime).value)
    XCTAssertTrue(
      store.deleteProfile(p3.id, reassigningTo: survivor.id, now: Self.baseTime).didPersist)
    XCTAssertTrue(
      store.deleteProfile(p4.id, reassigningTo: survivor.id, now: Self.baseTime).didPersist)
    session.drainPendingStoreRemovals()
    XCTAssertEqual(pendingCallbacks.map(\.id), [p3.id])

    isolated = true
    pendingCallbacks.removeFirst().done(true)
    XCTAssertTrue(pendingCallbacks.isEmpty, "途中隔離転落後は残件 p4 の OS ストア削除を呼ばない")
    XCTAssertEqual(store.pendingStoreRemovals.map(\.storeId), [p4.id], "未削除分はキューに残る")
  }

  // MARK: - 複数スペース一括破棄・再 materialize・Cookie 非継承・閉じたタブ履歴隔離

  /// プロファイル削除は参照する 2 スペースすべてのランタイムを一括破棄し、アクティブスペースの URL タブを
  /// 付け替え先プロファイルで再 materialize して Cookie / `localStorage` を継承させず、
  /// 付け替え対象スペースの `closed_tabs` も消去して越境復元を防ぐ。
  func testDeleteProfileInvalidatesTwoSpacesReMaterializesWithoutCookieAndPurgesHistory() throws {
    let server = try LocalLoopbackHTTPServer(routes: [
      "/a": "<!doctype html><title>A</title><p>a</p>",
      "/b": "<!doctype html><title>B</title><p>b</p>",
    ])
    defer { server.stop() }
    let urlA = server.url(for: "/a")
    let urlB = server.url(for: "/b")

    let session = BrowserSession.inMemory()
    let browser = makeHostedLayer(session: session).browser
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    browser.setMode(.sheet, animated: false)

    let work = session.store.profiles[1]
    let doomed = try XCTUnwrap(
      session.createProfile(name: "private-temp", color: .amber, mcpAllowed: false))
    let spaceA = try XCTUnwrap(
      session.createFreeSpace(name: "S-A", icon: .globe, profileId: doomed.id))
    let spaceB = try XCTUnwrap(
      session.createFreeSpace(name: "S-B", icon: .code, profileId: doomed.id))

    let tabA = try XCTUnwrap(session.openTab(in: spaceA.id, url: urlA, activate: false))
    let tabB = try XCTUnwrap(session.openTab(in: spaceB.id, url: urlB, activate: false))
    let closedA = try XCTUnwrap(session.openTab(in: spaceA.id, url: urlA, activate: false))
    XCTAssertTrue(session.closeTab(closedA.id, recordClosed: true))

    // 両スペースを materialize し、spaceA に旧プロファイルの Cookie / localStorage を書く。
    let oldViewB = try loadTab(tabB.id, session: session, browser: browser, finishes: { finishes })
    let oldRuntimeB = try XCTUnwrap(session.runtimes[tabB.id])
    let oldViewA = try loadTab(tabA.id, session: session, browser: browser, finishes: { finishes })
    let oldRuntimeA = try XCTUnwrap(session.runtimes[tabA.id])
    _ = try evalJSString(
      "document.cookie = 'secret=1; path=/'; localStorage.setItem('secret', '1'); 'ok'",
      in: oldViewA)

    // doomed を work へ付け替え削除 → 両スペースの旧ランタイム破棄・tabA 再 materialize・履歴消去。
    let beforeDelete = finishes
    XCTAssertTrue(session.deleteProfile(doomed.id, reassigningTo: work.id))
    XCTAssertTrue(oldRuntimeA.isInvalidated, "アクティブスペースの旧ランタイムを破棄")
    XCTAssertTrue(oldRuntimeB.isInvalidated, "非アクティブ 2 つ目スペースの旧ランタイムも一括破棄")
    XCTAssertNil(session.runtimes[tabB.id], "非アクティブスペースは遅延 materialize のまま")
    XCTAssertNil(oldViewA.superview)
    XCTAssertNil(oldViewB.superview)

    let newRuntimeA = try XCTUnwrap(session.runtimes[tabA.id])
    XCTAssertEqual(newRuntimeA.profileId, work.id, "付け替え先プロファイルで再 materialize")
    XCTAssertFalse(newRuntimeA === oldRuntimeA)
    pumpMain(until: { finishes > beforeDelete }, timeout: 5, "付け替え先での再ロード完了")
    XCTAssertEqual(try evalJSString("document.cookie", in: newRuntimeA.webView), "")
    XCTAssertEqual(
      try evalJSString("localStorage.getItem('secret') ?? ''", in: newRuntimeA.webView), "")
    XCTAssertNil(session.reopenClosedTab(), "付け替え対象スペースの閉じたタブ履歴を越境復元できない")

    // setSpaceProfile 経由でも対象スペースの閉じたタブ履歴が消去され越境復元できない。
    let personal = session.store.profiles[0]
    let extraClosed = try XCTUnwrap(session.openTab(in: spaceA.id, url: urlB, activate: false))
    XCTAssertTrue(session.closeTab(extraClosed.id, recordClosed: true))
    XCTAssertTrue(session.setSpaceProfile(spaceA.id, profileId: personal.id))
    XCTAssertNil(session.reopenClosedTab(), "setSpaceProfile 後も旧プロファイル由来履歴を復元できない")
  }

  // MARK: - 運転中破損後の .local 継続と DB コミット失敗時のランタイム非破棄

  /// 運転中 DB 破損が `syncCurrentWorkspace` の瞬間に起きて非永続転落しても 1 回再同期で `.local` が
  /// 機能継続し、`setSpaceProfile` / `removeLocalSpace` の DB 書込失敗時は既存ランタイムを破棄しない。
  func testRuntimeCorruptionResyncsLocalAndCommitFailureKeepsRuntimesAlive() throws {
    // 1. syncCurrentWorkspace 実行中の SQLITE_CORRUPT で非永続転落しても即 1 回再同期し .local が継続する。
    let wsA = UUID()
    let wsB = UUID()
    do {
      let seeded = openPersistentStore()
      _ = seeded.setCurrentWorkspace(wsA, name: "alpha", now: Self.baseTime)
    }
    let corruptDB = try SQLiteDatabase(url: browserFolder().appendingPathComponent("db.sqlite"))
    try corruptDB.exec("PRAGMA journal_mode = DELETE; PRAGMA cache_size = 0;")
    let loaded = try BrowserDatabase.loadOrSeed(corruptDB, language: .ja, now: Self.baseTime)
    let corruptStore = BrowserStore(
      opening: .opened(
        BrowserDatabase.Opened(
          database: BrowserDatabase(corruptDB), memory: loaded.memory,
          seededLanguage: loaded.seededLanguage)))
    let brokenSession = BrowserSession(store: corruptStore)
    brokenSession.start(initialWorkspaceId: wsA, workspaceName: "alpha")
    XCTAssertTrue(corruptStore.available)
    // db.sqlite 全体を破損させてキャッシュを捨て、未訪問 wsB のローカルスペース INSERT で SQLITE_NOTADB/CORRUPT を発生させる。
    let dbFile = try browserFolder().appendingPathComponent("db.sqlite")
    let size = try FileManager.default.attributesOfItem(atPath: dbFile.path)[.size] as? Int ?? 4096
    let handle = try FileHandle(forUpdating: dbFile)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data(repeating: 0xFF, count: size))
    try handle.close()
    try corruptDB.exec("PRAGMA shrink_memory;")
    brokenSession.syncCurrentWorkspace(wsB, name: "beta")
    XCTAssertFalse(corruptStore.available, "INSERT 時の DB 破損検知で非永続モードへ転落する")
    XCTAssertEqual(corruptStore.currentWorkspaceId, wsB, "転落直後の 1 回再同期で .local が機能継続する")
    XCTAssertEqual(corruptStore.currentWorkspaceName, "beta")
    XCTAssertNotNil(corruptStore.localSpace(for: wsB))

    // 2. setSpaceProfile / removeLocalSpace の DB コミット失敗時は既存ランタイムを破棄しない。
    try assertDBFailurePreservesRuntimesOnSetSpaceProfileAndRemoveLocalSpace()
  }

  private func assertDBFailurePreservesRuntimesOnSetSpaceProfileAndRemoveLocalSpace() throws {
    let originalOverride = BrowserPersistence.folderOverride
    defer { BrowserPersistence.folderOverride = originalOverride }
    let folder = TestScratch.caseDir.appendingPathComponent("fail-ops/browser", isDirectory: true)
    BrowserPersistence.folderOverride = folder

    let wsId = UUID()
    do {
      let seeded = openPersistentStore()
      _ = seeded.setCurrentWorkspace(wsId, name: "ws", now: Self.baseTime)
    }
    let rawDB = try SQLiteDatabase(url: folder.appendingPathComponent("db.sqlite"))
    try rawDB.exec(
      """
      PRAGMA foreign_keys = ON;
      CREATE TRIGGER block_space_update BEFORE UPDATE OF profile_id ON spaces
      BEGIN SELECT RAISE(ABORT, 'blocked-update'); END;
      CREATE TRIGGER block_space_delete BEFORE DELETE ON spaces
      BEGIN SELECT RAISE(ABORT, 'blocked-delete'); END;
      """)
    let loaded = try BrowserDatabase.loadOrSeed(rawDB, language: .ja, now: Self.baseTime)
    let store = BrowserStore(
      opening: .opened(
        BrowserDatabase.Opened(
          database: BrowserDatabase(rawDB), memory: loaded.memory,
          seededLanguage: loaded.seededLanguage)))
    let session = BrowserSession(store: store)
    session.start(initialWorkspaceId: wsId, workspaceName: "ws")
    let browser = makeHostedLayer(session: session).browser
    browser.setMode(.sheet, animated: false)
    browser.loadHTMLString("<p>keep</p>", baseURL: nil)
    let runtime = try XCTUnwrap(browser.mountedRuntime)
    let localSpace = try XCTUnwrap(store.localSpace(for: wsId))
    let otherProfile = try XCTUnwrap(store.profiles.first { $0.id != localSpace.profileId })

    XCTAssertFalse(session.setSpaceProfile(localSpace.id, profileId: otherProfile.id))
    XCTAssertFalse(runtime.isInvalidated, "setSpaceProfile の DB 失敗時にランタイムを破棄しない")
    XCTAssertTrue(session.runtimes[runtime.tabId] === runtime)
    XCTAssertTrue(browser.mountedRuntime === runtime)

    session.removeLocalSpace(for: wsId)
    XCTAssertFalse(runtime.isInvalidated, "removeLocalSpace の DB 失敗時にランタイムを破棄しない")
    XCTAssertTrue(session.runtimes[runtime.tabId] === runtime)
    XCTAssertNotNil(store.localSpace(for: wsId))
  }

  private func loadTab(
    _ tabId: UUID, session: BrowserSession, browser: BrowserLayerView, finishes: () -> Int,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> WKWebView {
    let before = finishes()
    XCTAssertTrue(session.selectTab(tabId), file: file, line: line)
    let webView = try XCTUnwrap(browser.webView, file: file, line: line)
    pumpMain(until: { finishes() > before }, timeout: 5, "タブ読み込み完了", file: file, line: line)
    return webView
  }
}
