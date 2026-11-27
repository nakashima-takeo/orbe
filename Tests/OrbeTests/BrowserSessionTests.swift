import AppKit
import OrbeTestSupport
import WebKit
import XCTest

@testable import Orbe

/// 内蔵ブラウザのランタイム調停（`BrowserSession` / `BrowserTabRuntime` / `BrowserLayerView` 連携）の
/// 起動開始ゲート・遅延 materialize・表示ライフサイクル・シート幅比率永続化・プロファイル実隔離・
/// 12 時間自動整理を守る。
///
/// 壊れると何が起きるか。起動時の 12 時間整理より先に初期 workspace 同期が走ってローカルスペースや
/// 期限切れタブの順序が壊れる。閉鎖中・非アクティブタブで不要な `WKWebView` が生成される、または
/// タブ切替でページ状態が失われる。閉鎖中のタブ閉鎖で破棄済み `WKWebView` やツールバー残像が残る。
/// 別プロファイル間で Cookie や `localStorage` が漏洩する、あるいは 12 時間自動整理が表示中タブを
/// 消したり閉鎖中に延命し続けたりする。
@MainActor
final class BrowserSessionTests: OrbeTestCase {
  nonisolated static let baseTime = Date(timeIntervalSince1970: 1_800_000_000)

  struct HostedLayer {
    let window: OrbeWindowFake
    let browser: BrowserLayerView
  }

  func openPersistentStore(language: Language = .ja, now: Date = baseTime) -> BrowserStore {
    BrowserStore(
      opening: BrowserPersistence.open(language: language, now: now),
      language: language,
      now: now)
  }

  func makeHostedLayer(session: BrowserSession) -> HostedLayer {
    let size = NSSize(width: 1000, height: 600)
    let window = OrbeWindowFake(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isKey = true
    let browser = BrowserLayerView(
      session: session, localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver())
    browser.reduceMotion = true
    browser.frame = NSRect(origin: .zero, size: size)
    window.contentView = browser
    browser.layoutSubtreeIfNeeded()
    holdUntilTestEnds(window)
    addTeardownBlock { MainActor.assumeIsolated { window.contentView = nil } }
    return HostedLayer(window: window, browser: browser)
  }

  func evalJSString(
    _ script: String, in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line
  ) throws -> String {
    var done = false
    var resultValue: Any?
    var resultError: Error?
    webView.evaluateJavaScript(script) { value, error in
      resultValue = value
      resultError = error
      done = true
    }
    pumpMain(until: { done }, timeout: 5, "JavaScript 評価完了", file: file, line: line)
    if let resultError {
      throw resultError
    }
    return try XCTUnwrap(resultValue as? String, file: file, line: line)
  }

  // MARK: - 起動開始ゲート

  /// `start` 完了前の `syncCurrentWorkspace` はローカルスペースを作らず DB へ書き込まない。
  /// `start` 実行で起動時 12 時間整理→初回 workspace 同期→削除キュー再試行→タイマー開始が順に動く。
  func testStartGateBlocksEarlyWorkspaceSyncAndRunsStartupPruneBeforeFirstSync() throws {
    let t0 = Self.baseTime
    let t12h = t0.addingTimeInterval(BrowserStore.todayTabTTL)
    let wsEarly = UUID()
    let wsInitial = UUID()
    let staleTabId: UUID
    let pendingProfileId: UUID

    do {
      let store = openPersistentStore(now: t0)
      let freeSpace = try XCTUnwrap(store.freeSpaces.first)
      let stale = try XCTUnwrap(
        store.openTab(
          in: freeSpace.id, section: .today, url: URL(string: "https://docs.orbe.dev/old")!,
          title: "Old", activate: true, now: t0
        ).value)
      staleTabId = stale.id
      let extra = try XCTUnwrap(
        store.createProfile(name: "old", color: .amber, mcpAllowed: false, now: t0).value)
      pendingProfileId = extra.id
      XCTAssertTrue(
        store.deleteProfile(extra.id, reassigningTo: store.profiles[0].id, now: t0).didPersist)
    }

    var removedIds: [UUID] = []
    var armedDate: Date?
    let store = openPersistentStore(now: t12h)
    let registry = BrowserDataStoreRegistry(
      isIsolated: { false },
      remover: { id, completion in
        removedIds.append(id)
        completion(true)
      })
    let cleaner = BrowserTabCleaner(
      now: { t12h },
      arm: { date, _ in
        armedDate = date
        return { armedDate = nil }
      })
    let session = BrowserSession(
      store: store, dataStores: registry, cleaner: cleaner, now: { t12h })

    // 開始前の syncCurrentWorkspace はゲートされ、ローカルスペースを作らない。
    XCTAssertFalse(session.isStarted)
    session.syncCurrentWorkspace(wsEarly)
    XCTAssertNil(store.localSpace(for: wsEarly), "start 前にローカルスペースを作成しない")
    XCTAssertNotNil(store.tab(id: staleTabId), "start 前は起動時整理もまだ走らない")

    // start 実行で 12h 整理→初回 WS 同期→削除キュー再試行→タイマー開始が揃う。
    session.start(initialWorkspaceId: wsInitial)
    XCTAssertTrue(session.isStarted)
    XCTAssertNil(store.tab(id: staleTabId), "起動時 12h 整理で期限切れアクティブタブを除去")
    XCTAssertNil(store.localSpace(for: wsEarly))
    XCTAssertNotNil(store.localSpace(for: wsInitial), "初回 workspace のローカルスペースを作成")
    XCTAssertEqual(removedIds, [pendingProfileId], "未完了の削除キューを起動時に再試行")
    XCTAssertTrue(store.pendingStoreRemovals.isEmpty, "削除成功でキューから除去")
    XCTAssertTrue(cleaner.isStarted)
    XCTAssertNil(armedDate, "残存 TODAY タブが無いため不要なタイマーは張らない")
  }

  // MARK: - 遅延 materialize・タブ切替・閉鎖中掃除

  /// 閉鎖中・非アクティブタブ・`url == nil` では `WKWebView` を作らず、開放時のアクティブ表示で初めて生成する。
  /// タブ切替では旧 `WKWebView` が `belowBar` から外れつつ JS 状態を保ち、再選択で同一実体が戻る。
  /// 閉鎖中のタブ閉鎖でも破棄済み `WKWebView` とツールバー残像を即座に外す。
  func testLazyMaterializationTabSwitchPreservationAndClosedCleanup() throws {
    let server = try LocalLoopbackHTTPServer(routes: [
      "/a": "<!doctype html><title>Page A</title><p>A</p>",
      "/b": "<!doctype html><title>Page B</title><p>B</p>",
    ])
    defer { server.stop() }

    let session = BrowserSession.inMemory()
    let hosted = makeHostedLayer(session: session)
    let browser = hosted.browser
    let space = try XCTUnwrap(session.store.freeSpaces.first)
    XCTAssertTrue(session.selectSpace(.free(space.id)))

    let emptyTab = try XCTUnwrap(session.openTab(in: space.id, url: nil, activate: true))
    let tabA = try XCTUnwrap(
      session.openTab(in: space.id, url: server.url(for: "/a"), activate: false))
    let tabB = try XCTUnwrap(
      session.openTab(in: space.id, url: server.url(for: "/b"), activate: false))
    XCTAssertTrue(session.runtimes.isEmpty, "閉鎖中は WKWebView を一切作らない")

    // 開放しても url == nil の空タブでは WKWebView を作らない。
    browser.setMode(.sheet, animated: false)
    XCTAssertEqual(session.store.activeTab?.id, emptyTab.id)
    XCTAssertNil(browser.webView, "url == nil の空タブは開放中でも WKWebView を作らない")
    XCTAssertTrue(session.runtimes.isEmpty)

    // tabA を選択すると tabA だけ遅延生成され、tabB は未生成のまま。
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    XCTAssertTrue(session.selectTab(tabA.id))
    let webViewA = try XCTUnwrap(browser.webView)
    XCTAssertEqual(Set(session.runtimes.keys), [tabA.id], "非アクティブ tabB は生成しない")
    pumpMain(until: { finishes >= 1 }, timeout: 5, "tabA 読み込み完了")
    XCTAssertEqual(try evalJSString("(window.__keep = 'alive')", in: webViewA), "alive")

    // tabB へ切り替えると webViewA は belowBar から外れつつ runtimes で状態を維持する。
    let beforeB = finishes
    XCTAssertTrue(session.selectTab(tabB.id))
    let webViewB = try XCTUnwrap(browser.webView)
    XCTAssertFalse(webViewA === webViewB)
    XCTAssertNil(webViewA.superview, "非アクティブへ移った旧 WKWebView は表示ツリーから外す")
    XCTAssertTrue(webViewB.superview === browser.belowBar)
    pumpMain(until: { finishes > beforeB }, timeout: 5, "tabB 読み込み完了")

    // tabA へ戻すと同一 WKWebView が再マウントされ JS 状態が保たれる。
    XCTAssertTrue(session.selectTab(tabA.id))
    XCTAssertTrue(browser.webView === webViewA, "既存ランタイムの同一 WKWebView が再マウントされる")
    XCTAssertTrue(webViewA.superview === browser.belowBar)
    XCTAssertEqual(try evalJSString("window.__keep", in: webViewA), "alive")

    // 閉鎖中に tabA を閉じても破棄済み WKWebView 参照とツールバー残像を残さない。
    browser.setMode(.closed, animated: false)
    XCTAssertTrue(session.closeTab(tabA.id))
    XCTAssertNil(session.runtimes[tabA.id])
    XCTAssertNil(webViewA.superview, "閉鎖中の閉鎖でも破棄済み WKWebView を外す")
    XCTAssertTrue(browser.mountedRuntime === session.runtimes[tabB.id], "次候補 tabB へ投影同期")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/b")
  }

  /// `loadHTMLString` は架空 `baseURL` やタイトルを DB へ書き込まず、
  /// 既存 URL を持つタブの暫定遷移失敗も永続 URL を上書きしない。
  func testLocalHTMLAndFailedProvisionalLoadDoNotOverwritePersistedTabURL() throws {
    let server = try LocalLoopbackHTTPServer(routes: [
      "/ok": "<!doctype html><title>Real Page</title><p>ok</p>"
    ])
    defer { server.stop() }
    let closedPort = try LocalLoopbackHTTPServer.reserveClosedPort()
    let failURL = URL(string: "http://127.0.0.1:\(closedPort)/fail")!
    let okURL = server.url(for: "/ok")

    let store = openPersistentStore()
    let session = BrowserSession(store: store)
    session.start(initialWorkspaceId: UUID())
    let browser = makeHostedLayer(session: session).browser
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    browser.setMode(.sheet, animated: false)

    // 1. loadHTMLString は DB の tab.url / title を汚染しない。
    browser.loadHTMLString(
      "<!doctype html><title>Fake</title><p>local</p>",
      baseURL: URL(string: "https://fake.orbe.dev/doc"))
    pumpMain(until: { finishes >= 1 }, timeout: 5, "ローカル HTML 完了")
    let localTab = try XCTUnwrap(store.activeTab)
    XCTAssertNil(localTab.url, "loadHTMLString の架空 baseURL は DB へ書き込まない")
    XCTAssertEqual(localTab.title, "", "loadHTMLString のタイトルは DB へ書き込まない")

    // 2. 実 HTTP ページ確定後、到達不能な別 URL へ暫定遷移して失敗しても永続 URL は維持される。
    let beforeOK = finishes
    browser.load(okURL)
    pumpMain(
      until: { finishes > beforeOK && store.tab(id: localTab.id)?.title == "Real Page" },
      timeout: 5, "実ページ確定")
    XCTAssertEqual(store.tab(id: localTab.id)?.url, okURL)

    browser.load(failURL)
    pumpMain(until: { !browser.isProvisionalNavigation }, timeout: 5, "暫定失敗完了")
    XCTAssertEqual(store.tab(id: localTab.id)?.url, okURL, "暫定失敗で永続 URL を上書きしない")
  }

  // MARK: - シート幅比率のドラッグ確定永続化

  /// シート幅比率はドラッグ通常域（`.keepSheet`）で離したときだけ DB へ確定保存し、
  /// ドラッグ中・キャンセル・全面吸着・右投げ閉じでは DB を書き換えない。再起動後も確定比率で開く。
  func testSheetRatioPersistsOnlyOnKeepSheetDragCommit() throws {
    let wsId = UUID()
    autoreleasepool {
      let store = openPersistentStore()
      let session = BrowserSession(store: store)
      session.start(initialWorkspaceId: wsId)
      let hosted = makeHostedLayer(session: session)
      defer { hosted.window.contentView = nil }
      let browser = hosted.browser
      browser.setMode(.sheet, animated: false)

      let initialBps = store.sheetRatioBps
      // ドラッグ中・キャンセルは DB 非保存。
      browser.dragDidStart()
      browser.dragDidMove(to: 300)  // width 700 -> ratio 0.70
      XCTAssertEqual(store.sheetRatioBps, initialBps, "ドラッグ中は DB へ保存しない")
      browser.dragDidEnd(cancelled: true)
      XCTAssertEqual(store.sheetRatioBps, initialBps, "キャンセル時は DB へ保存しない")

      // 全面吸着（左端近く）は DB 非保存。
      browser.dragDidStart()
      browser.dragDidMove(to: 50)
      browser.dragDidEnd(cancelled: false)
      XCTAssertEqual(browser.mode, .full)
      XCTAssertEqual(store.sheetRatioBps, initialBps, "全面吸着は DB 比率を書き換えない")

      // 右投げ閉じも DB 非保存。
      browser.setMode(.sheet, animated: false)
      browser.dragDidStart()
      browser.dragDidMove(to: 850)
      browser.dragDidEnd(cancelled: false)
      XCTAssertEqual(browser.mode, .closed)
      XCTAssertEqual(store.sheetRatioBps, initialBps, "右投げ閉じは DB 比率を書き換えない")

      // 通常域での確定（ratio = 0.68）のみ DB へ即時保存。
      browser.setMode(.sheet, animated: false)
      browser.dragDidStart()
      browser.dragDidMove(to: 320)
      browser.dragDidEnd(cancelled: false)
      XCTAssertEqual(store.sheetRatioBps, 6800, "通常域確定で DB へ即時保存")
    }

    // 再起動後に生成した BrowserLayerView は保存された比率で初期化する。
    let reopened = BrowserSession(store: openPersistentStore())
    XCTAssertTrue(reopened.store.available, "1 代目解放後に排他ロック競合なく再オープンできる")
    reopened.start(initialWorkspaceId: wsId)
    let reopenedLayer = makeHostedLayer(session: reopened).browser
    XCTAssertEqual(reopenedLayer.sheetRatio, 0.68, accuracy: 0.001)
  }
}
