import AppKit
import OrbeTestSupport
import SQLite3
import WebKit
import XCTest

@testable import Orbe

/// プロファイル間の実 `WKWebView` Cookie / `localStorage` 隔離と同一プロファイル共有、
/// スペースのプロファイル変更時の破棄・再 materialize、動的隔離判定、およびプロファイル削除時の
/// WebView 解放先行・明示削除キュー再試行を守る。
///
/// 壊れると何が起きるか。私用と業務のログインセッションや `localStorage` が別プロファイルへ漏洩する。
/// 同じプロファイル内の複数タブでログイン状態が共有されない。DB 破損後や隔離環境から OS の
/// 永続データストアを誤削除・汚染する、または `WKWebView` 生存中にストア削除を走らせて失敗する。
extension BrowserSessionTests {
  // MARK: - 実 WKWebView の Cookie / localStorage 隔離と共有

  /// 別プロファイル（`personal` vs `work`）に紐づくタブ間では `document.cookie`・`localStorage` が
  /// 共有されず、同一プロファイルに紐づく複数タブ（同一スペースおよび異スペース）間では共有される。
  func testProfilesIsolateCookiesAndLocalStorageAndShareWithinSameProfile() throws {
    let server = try LocalLoopbackHTTPServer(routes: [
      "/app": "<!doctype html><title>App</title><p>storage</p>"
    ])
    defer { server.stop() }
    let appURL = server.url(for: "/app")

    let session = BrowserSession.inMemory()
    let browser = makeHostedLayer(session: session).browser
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    browser.setMode(.sheet, animated: false)

    // 既定自由スペース: [0] 個人 (personal), [1] 仕事 (work), [2] 調査 (work)。
    let free = session.store.freeSpaces
    let personalSpace = free[0]
    let workSpace = free[1]
    let researchSpace = free[2]
    XCTAssertNotEqual(personalSpace.profileId, workSpace.profileId)
    XCTAssertEqual(workSpace.profileId, researchSpace.profileId)

    let pTab1 = try XCTUnwrap(session.openTab(in: personalSpace.id, url: appURL, activate: false))
    let pTab2 = try XCTUnwrap(session.openTab(in: personalSpace.id, url: appURL, activate: false))
    let wTab1 = try XCTUnwrap(session.openTab(in: workSpace.id, url: appURL, activate: false))
    let wTab2 = try XCTUnwrap(session.openTab(in: researchSpace.id, url: appURL, activate: false))

    // 1. personal タブ 1 で Cookie / localStorage を書き込む。
    let pView1 = try activateAndLoad(
      pTab1.id, session: session, browser: browser, finishes: { finishes })
    XCTAssertFalse(pView1.configuration.websiteDataStore.isPersistent, "隔離環境では非永続ストア")
    _ = try evalJSString(
      "document.cookie = 'acct=personal; path=/'; localStorage.setItem('acct', 'personal'); 'ok'",
      in: pView1)

    // 2. work タブ 1 では personal の値が一切見えず、独立して work の値を書ける。
    let wView1 = try activateAndLoad(
      wTab1.id, session: session, browser: browser, finishes: { finishes })
    XCTAssertEqual(try evalJSString("document.cookie", in: wView1), "", "別プロファイルへ Cookie が漏れない")
    XCTAssertEqual(
      try evalJSString("localStorage.getItem('acct') ?? ''", in: wView1), "",
      "別プロファイルへ localStorage が漏れない")
    _ = try evalJSString(
      "document.cookie = 'acct=work; path=/'; localStorage.setItem('acct', 'work'); 'ok'",
      in: wView1)

    // 3. 同一プロファイル（personal）の別タブ pTab2 は personal の値を共有する。
    let pView2 = try activateAndLoad(
      pTab2.id, session: session, browser: browser, finishes: { finishes })
    XCTAssertTrue(try evalJSString("document.cookie", in: pView2).contains("acct=personal"))
    XCTAssertEqual(try evalJSString("localStorage.getItem('acct') ?? ''", in: pView2), "personal")

    // 4. 同一プロファイル（work）の別スペース（調査）タブ wTab2 は work の値を共有し、personal は見えない。
    let wView2 = try activateAndLoad(
      wTab2.id, session: session, browser: browser, finishes: { finishes })
    XCTAssertTrue(try evalJSString("document.cookie", in: wView2).contains("acct=work"))
    XCTAssertFalse(try evalJSString("document.cookie", in: wView2).contains("acct=personal"))
    XCTAssertEqual(try evalJSString("localStorage.getItem('acct') ?? ''", in: wView2), "work")
  }

  /// `setSpaceProfile` でスペースのプロファイルを変更すると配下の既存ランタイムが全破棄され、
  /// アクティブ表示中タブは新プロファイルのデータストアで再 materialize されて旧セッションを引き継がない。
  func testSetSpaceProfileInvalidatesRuntimesAndReMaterializesWithNewProfile() throws {
    let server = try LocalLoopbackHTTPServer(routes: [
      "/profile": "<!doctype html><title>Profile</title><p>ok</p>"
    ])
    defer { server.stop() }
    let pageURL = server.url(for: "/profile")

    let session = BrowserSession.inMemory()
    let browser = makeHostedLayer(session: session).browser
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    browser.setMode(.sheet, animated: false)

    let personal = session.store.profiles[0]
    let work = session.store.profiles[1]
    let space = session.store.freeSpaces[0]
    XCTAssertEqual(space.profileId, personal.id)

    let tab1 = try XCTUnwrap(session.openTab(in: space.id, url: pageURL, activate: false))
    let tab2 = try XCTUnwrap(session.openTab(in: space.id, url: pageURL, activate: false))
    let oldView2 = try activateAndLoad(
      tab2.id, session: session, browser: browser, finishes: { finishes })
    let oldRuntime2 = try XCTUnwrap(session.runtimes[tab2.id])
    let oldView1 = try activateAndLoad(
      tab1.id, session: session, browser: browser, finishes: { finishes })
    let oldRuntime1 = try XCTUnwrap(session.runtimes[tab1.id])
    _ = try evalJSString(
      "document.cookie = 'role=personal; path=/'; localStorage.setItem('role', 'personal'); 'ok'",
      in: oldView1)

    let beforeSwitch = finishes
    XCTAssertTrue(session.setSpaceProfile(space.id, profileId: work.id))
    XCTAssertTrue(oldRuntime1.isInvalidated, "アクティブタブの旧ランタイムを即破棄")
    XCTAssertTrue(oldRuntime2.isInvalidated, "非アクティブタブの旧ランタイムも全破棄")
    XCTAssertNil(session.runtimes[tab2.id], "非アクティブタブは再 materialize しない")
    XCTAssertNil(oldView1.superview)
    XCTAssertNil(oldView2.superview)

    let newRuntime1 = try XCTUnwrap(session.runtimes[tab1.id])
    XCTAssertEqual(newRuntime1.profileId, work.id)
    XCTAssertFalse(newRuntime1 === oldRuntime1)
    pumpMain(until: { finishes > beforeSwitch }, timeout: 5, "新プロファイルで再ロード完了")
    XCTAssertEqual(
      try evalJSString("document.cookie", in: newRuntime1.webView), "",
      "旧プロファイルの Cookie を引き継がない")
    XCTAssertEqual(
      try evalJSString("localStorage.getItem('role') ?? ''", in: newRuntime1.webView), "",
      "旧プロファイルの localStorage を引き継がない")
  }

  // MARK: - 動的隔離とプロファイル削除の順序・再試行

  /// 運転中に DB が破損し `!store.available` へ転落すると、`BrowserDataStoreRegistry` は動的に
  /// 隔離モードへ切り替わり、以降は非永続ストアのみを返して OS ストア削除を一切実行しない。
  func testDynamicIsolationEngagesImmediatelyWhenStoreBecomesUnavailable() throws {
    let store = openPersistentStore()
    var removedIds: [UUID] = []
    let registry = BrowserDataStoreRegistry(
      isIsolated: { !store.available },
      remover: { id, completion in
        removedIds.append(id)
        completion(true)
      })
    let session = BrowserSession(store: store, dataStores: registry)
    session.start(initialWorkspaceId: UUID())
    XCTAssertFalse(registry.isIsolated, "前提: DB 利用可能時は非隔離判定")

    // 運転中破損で store.available == false へ転落。
    let broken: BrowserStoreCommitResult<Void> = store.commit { _, _ in
      throw SQLiteError(code: SQLITE_CORRUPT, message: "runtime corruption")
    }
    XCTAssertFalse(broken.didSucceed)
    XCTAssertFalse(store.available)
    XCTAssertTrue(registry.isIsolated, "!store.available への転落で即座に動的隔離へ切り替わる")

    // 転落後の store(for:) は非永続キャッシュへ倒れ、removePersistentStore / deleteProfile とも OS 削除を呼ばない。
    let p0 = store.profiles[0]
    let p1 = store.profiles[1]
    XCTAssertFalse(registry.store(for: p0.id).isPersistent)
    var directRemoved: Bool?
    registry.removePersistentStore(for: p1.id) { directRemoved = $0 }
    XCTAssertEqual(directRemoved, false, "隔離状態の removePersistentStore は即座に false で打ち切る")
    XCTAssertEqual(removedIds, [], "隔離状態の removePersistentStore は remover を呼ばない")
    XCTAssertTrue(session.deleteProfile(p1.id, reassigningTo: p0.id))
    XCTAssertEqual(removedIds, [], "非永続モードのプロファイル削除では OS ストア削除を呼ばない")
  }

  private struct DeletionObservation {
    let mountedIsNil: Bool
    let runtimesEmpty: Bool
    let invalidated: Bool
    let superviewIsNil: Bool
    let delegateIsNil: Bool
  }

  /// プロファイル削除は対象 `WKWebView` の全解放・アンマウント完了後に DB 削除し、
  /// `.persisted` かつ非隔離時のみ OS ストア削除を実行する。削除失敗時はキューに残り次回起動で再試行する。
  func testProfileDeletionReleasesWebViewsBeforeRemovalAndRetriesPendingQueueOnRestart() throws {
    let wsId = UUID()
    let victimId = try runProfileDeletionWithFailingRemover(wsId: wsId)

    // 再起動後の start で未完了キューが再試行され、成功で DB キューから除去される。
    var retryIds: [UUID] = []
    autoreleasepool {
      let store = openPersistentStore()
      XCTAssertTrue(store.available, "1 代目解放後に排他ロック競合なく再オープンできる")
      XCTAssertEqual(store.pendingStoreRemovals.map(\.storeId), [victimId])
      let registry = BrowserDataStoreRegistry(
        isIsolated: { false },
        remover: { id, completion in
          retryIds.append(id)
          completion(true)
        })
      let session = BrowserSession(store: store, dataStores: registry)
      session.start(initialWorkspaceId: wsId)
      XCTAssertEqual(retryIds, [victimId])
      XCTAssertTrue(store.pendingStoreRemovals.isEmpty, "再試行成功でキューから除去")
    }
    XCTAssertTrue(openPersistentStore().pendingStoreRemovals.isEmpty, "キュー除去が DB へ永続化される")
  }

  private func runProfileDeletionWithFailingRemover(wsId: UUID) throws -> UUID {
    try autoreleasepool {
      var isolated = true
      var observations: [DeletionObservation] = []
      var removerCalls: [UUID] = []
      let store = openPersistentStore()
      let survivorId = store.profiles[0].id
      let victimId = store.profiles[1].id

      weak var oldRuntime: BrowserTabRuntime?
      weak var oldWebView: WKWebView?
      weak var weakBrowser: BrowserLayerView?
      weak var weakSession: BrowserSession?
      let registry = BrowserDataStoreRegistry(
        isIsolated: { isolated || !store.available },
        remover: { id, completion in
          removerCalls.append(id)
          observations.append(
            DeletionObservation(
              mountedIsNil: weakBrowser?.mountedRuntime == nil,
              runtimesEmpty: weakSession?.runtimes.isEmpty == true,
              invalidated: oldRuntime == nil || oldRuntime?.isInvalidated == true,
              superviewIsNil: oldWebView?.superview == nil,
              delegateIsNil: oldWebView?.navigationDelegate == nil))
          completion(false)
        })
      let session = BrowserSession(store: store, dataStores: registry)
      weakSession = session
      session.start(initialWorkspaceId: wsId)
      let hosted = makeHostedLayer(session: session)
      defer { hosted.window.contentView = nil }
      let browser = hosted.browser
      weakBrowser = browser
      browser.setMode(.sheet, animated: false)

      browser.loadHTMLString("<p>victim</p>", baseURL: nil)
      do {
        let mounted = try XCTUnwrap(browser.mountedRuntime)
        oldRuntime = mounted
        oldWebView = mounted.webView
        XCTAssertEqual(mounted.profileId, victimId)
      }

      isolated = false
      XCTAssertTrue(session.deleteProfile(victimId, reassigningTo: survivorId))
      XCTAssertEqual(removerCalls, [victimId])
      let obs = try XCTUnwrap(observations.first)
      XCTAssertTrue(obs.mountedIsNil, "OS ストア削除時点で BrowserLayerView のマウント解除済み")
      XCTAssertTrue(obs.runtimesEmpty, "OS ストア削除時点で session.runtimes から解放済み")
      XCTAssertTrue(obs.invalidated, "OS ストア削除時点で対象ランタイム invalidate 済み")
      XCTAssertTrue(obs.superviewIsNil, "OS ストア削除時点で WKWebView アンマウント済み")
      XCTAssertTrue(obs.delegateIsNil, "OS ストア削除時点で navigationDelegate 解除済み")
      XCTAssertEqual(store.pendingStoreRemovals.map(\.storeId), [victimId], "失敗時はキューに残る")
      return victimId
    }
  }

  /// プロファイル削除は隔離モード・`.inMemory`・DB 書込失敗（`.failed`）のいずれでも OS ストア削除を呼ばない。
  func testProfileDeletionSkipsOSRemovalWhenIsolatedInMemoryOrDBCommitFailed() throws {
    // 1. 隔離モード: 実 DB へ .persisted でも isIsolated == true なら OS 削除は呼ばない。
    var isolatedCalls = 0
    let persistentStore = openPersistentStore()
    let isolatedSession = BrowserSession(
      store: persistentStore,
      dataStores: BrowserDataStoreRegistry(
        isIsolated: { true },
        remover: { _, done in
          isolatedCalls += 1
          done(true)
        }))
    isolatedSession.start(initialWorkspaceId: UUID())
    XCTAssertTrue(
      isolatedSession.deleteProfile(
        persistentStore.profiles[1].id, reassigningTo: persistentStore.profiles[0].id))
    XCTAssertEqual(isolatedCalls, 0, "隔離モードでは OS 削除を呼ばない")

    // 2. .inMemory モード: DB 非接続では OS 削除を呼ばない。
    var inMemoryCalls = 0
    let memStore = BrowserStore.inMemory()
    let memSession = BrowserSession(
      store: memStore,
      dataStores: BrowserDataStoreRegistry(
        isIsolated: { false },
        remover: { _, done in
          inMemoryCalls += 1
          done(true)
        }))
    memSession.start(initialWorkspaceId: UUID())
    XCTAssertTrue(
      memSession.deleteProfile(memStore.profiles[1].id, reassigningTo: memStore.profiles[0].id))
    XCTAssertEqual(inMemoryCalls, 0, ".inMemory 結果では OS 削除を呼ばない")

    // 3. DB 書込失敗（.failed）: トリガーで DELETE を失敗させ、削除中止かつ OS 削除不実行を確認。
    try assertFailedDBDeleteSkipsOSRemoval()
  }

  private func assertFailedDBDeleteSkipsOSRemoval() throws {
    let originalOverride = BrowserPersistence.folderOverride
    defer { BrowserPersistence.folderOverride = originalOverride }
    let folder = TestScratch.caseDir.appendingPathComponent(
      "fail-delete/browser", isDirectory: true)
    BrowserPersistence.folderOverride = folder

    let (victimId, survivorId): (UUID, UUID) = {
      let seeded = openPersistentStore()
      return (seeded.profiles[1].id, seeded.profiles[0].id)
    }()
    let rawDB = try SQLiteDatabase(url: folder.appendingPathComponent("db.sqlite"))
    try rawDB.exec(
      """
      PRAGMA foreign_keys = ON;
      CREATE TRIGGER block_profile_delete BEFORE DELETE ON profiles
      BEGIN SELECT RAISE(ABORT, 'blocked'); END;
      """)
    let memory = try BrowserDatabase.loadOrSeed(rawDB, language: .ja, now: Self.baseTime)
    let store = BrowserStore(
      opening: .opened(BrowserDatabase.Opened(database: BrowserDatabase(rawDB), memory: memory)))
    var failedCalls = 0
    let failSession = BrowserSession(
      store: store,
      dataStores: BrowserDataStoreRegistry(
        isIsolated: { false },
        remover: { _, done in
          failedCalls += 1
          done(true)
        }))
    failSession.start(initialWorkspaceId: UUID())

    XCTAssertFalse(failSession.deleteProfile(victimId, reassigningTo: survivorId))
    XCTAssertEqual(failedCalls, 0, "DB 書込失敗（.failed）時は OS ストア削除を一切呼ばない")
    XCTAssertNotNil(store.profile(id: victimId), "失敗時はメモリからも削除しない")
  }

  private func activateAndLoad(
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
