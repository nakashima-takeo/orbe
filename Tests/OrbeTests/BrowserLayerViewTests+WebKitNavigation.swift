import AppKit
import OrbeTestSupport
import WebKit
import XCTest

@testable import Orbe

/// `WKNavigation` 単位の遷移状態追跡・同一／異オリジン暫定遷移保護・同一文書遷移（`pushState` / `#hash`）・
/// 重複遷移キャンセル耐性・ローカル HTML `baseURL` 非昇格・WebContent 異常終了復帰を本物の `WKWebView` で守る。
extension BrowserLayerViewTests {
  /// コミット済みページ上での異オリジン無応答先への暫定遷移中および失敗後は元の URL と鍵表示を維持し、
  /// 同一オリジンの `history.pushState` は反映する。初回未到達 `https://` 失敗時は鍵アイコンを点灯しない。
  func testProvisionalNavigationProtectsAddressBarAndSecureLock() throws {
    let (browser, runtime) = try makeSheetBrowserWithRuntime()
    let webView = runtime.webView
    let spy = BrowserNavigationPolicySpy(target: runtime)
    webView.navigationDelegate = spy
    defer { webView.navigationDelegate = runtime }

    let server = try LocalLoopbackHTTPServer(routes: ["/safe": "<!doctype html><p>safe</p>"])
    defer { server.stop() }
    let hanging = try HangingLoopbackServer()
    defer { hanging.stop() }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    browser.load(server.url(for: "/safe"))
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "安全な初期ページ読み込み完了")

    // 同一オリジンの history.pushState は URL 欄へ反映する。
    webView.evaluateJavaScript("history.pushState({}, '', '/pushed?k=1')")
    pumpMain(
      until: { browser.toolbar.displayURL?.path == "/pushed?k=1" }, timeout: 5,
      "同一オリジンの pushState がツールバーへ反映される")
    XCTAssertEqual(browser.toolbar.displayURL?.isSecure, false)
    XCTAssertFalse(browser.isProvisionalNavigation, "同一文書遷移後に pending へ停滞しない")

    // 無応答ポートへの暫定遷移中は、didStartProvisionalNavigation 到着後も URL・鍵アイコンを書き換えない。
    let startsBefore = spy.provisionalStartCount
    let failBefore = spy.failProvisionalCount
    let decoy = URL(string: "https://127.0.0.1:\(hanging.port)/login")!
    browser.load(decoy)
    XCTAssertTrue(browser.isProvisionalNavigation, "load 直後から同期的に暫定遷移として追跡する")
    pumpMain(until: { spy.provisionalStartCount > startsBefore }, timeout: 5, "暫定ナビゲーション開始")
    nextTurn()
    XCTAssertTrue(browser.isProvisionalNavigation, "暫定開始後もコミット・失敗まで暫定状態を保つ")
    XCTAssertEqual(browser.toolbar.displayURL?.host, "127.0.0.1:\(server.port)")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/pushed?k=1")
    XCTAssertEqual(browser.toolbar.displayURL?.isSecure, false, "未確定の https:// で鍵を点灯しない")

    // 暫定遷移が失敗（接続閉鎖）しても元のコミット済み表示を保つ。
    hanging.stop()
    pumpMain(
      until: { spy.failProvisionalCount > failBefore && !browser.isProvisionalNavigation },
      timeout: 5, "暫定遷移の失敗完了")
    nextTurn()
    XCTAssertEqual(browser.toolbar.displayURL?.host, "127.0.0.1:\(server.port)")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/pushed?k=1")

    // 初回（未コミット）で到達不能な https:// が失敗したとき、要求 URL は残すが鍵アイコンは出さない。
    let fresh = hostBrowser().browser
    fresh.setMode(.sheet, animated: false)
    let closedPort = try LocalLoopbackHTTPServer.reserveClosedPort()
    let unreachableHTTPS = URL(string: "https://127.0.0.1:\(closedPort)/secret")!
    try loadAndWaitForInitialFailure(unreachableHTTPS, in: fresh, "初回到達不能の失敗完了")
    XCTAssertEqual(fresh.toolbar.displayURL?.raw, unreachableHTTPS.absoluteString)
    XCTAssertEqual(fresh.toolbar.displayURL?.isSecure, false, "未到達の https:// では鍵を出さない")
  }

  /// 同一オリジンの `#hash` 同一文書遷移は `committedURL` とアドレスバーへ追従して pending に停滞せず、
  /// 同一オリジンの無応答エンドポイントへの暫定遷移では `didStartProvisionalNavigation` 前の KVO 窓から
  /// 失敗完了まで `committedURL`・アドレスバー・鍵表示を上書きせず元ページを保つ。
  func testSameOriginProvisionalNavigationProtectsCommittedURLAndTracksHashChange() throws {
    let (browser, runtime) = try makeSheetBrowserWithRuntime()
    let webView = runtime.webView
    let spy = BrowserNavigationPolicySpy(target: runtime)
    webView.navigationDelegate = spy
    defer { webView.navigationDelegate = runtime }

    let server = try LocalLoopbackHTTPServer(responses: [
      "/page-a": .html("<!doctype html><h1 id='sec'>Page A</h1>"),
      "/hang": .hang,
    ])
    defer { server.stop() }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    browser.load(server.url(for: "/page-a"))
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "page-a 読み込み完了")

    // 同一文書遷移（#hash）は committedURL とアドレスバーへ反映され、pending に停滞しない。
    webView.evaluateJavaScript("location.hash = '#sec'")
    pumpMain(
      until: { browser.toolbar.displayURL?.path == "/page-a#sec" }, timeout: 5,
      "#hash 遷移がアドレスバーへ反映される")
    XCTAssertEqual(browser.committedURL?.fragment, "sec")
    XCTAssertFalse(browser.isProvisionalNavigation)

    // 同一オリジン /hang へ暫定遷移: didStartProvisionalNavigation 到着前の KVO 窓でも上書きされない。
    let startsBefore = spy.provisionalStartCount
    let failBefore = spy.failProvisionalCount
    let expectedURL = server.url(for: "/page-a#sec")
    browser.load(server.url(for: "/hang"))
    XCTAssertTrue(browser.isProvisionalNavigation, "load 直後から同期的に暫定遷移として追跡する")
    nextTurn()
    XCTAssertEqual(browser.committedURL, expectedURL, "KVO 窓で同一オリジン未確定 URL に上書きされない")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/page-a#sec")
    XCTAssertEqual(browser.toolbar.displayURL?.isSecure, false)

    pumpMain(until: { spy.provisionalStartCount > startsBefore }, timeout: 5, "暫定遷移開始通知が到着")
    nextTurn()
    XCTAssertEqual(browser.committedURL, expectedURL)
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/page-a#sec")

    // サーバー停止で暫定遷移が失敗した後も元ページ URL と lastRequestedURL を保つ。
    server.stop()
    pumpMain(
      until: { spy.failProvisionalCount > failBefore && !browser.isProvisionalNavigation },
      timeout: 5, "同一オリジン暫定遷移の失敗完了")
    nextTurn()
    XCTAssertEqual(browser.committedURL, expectedURL)
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/page-a#sec")
    XCTAssertEqual(browser.lastRequestedURL, expectedURL)
  }

  /// 読込中ページや暫定遷移中に別遷移を重ねた際、旧遷移のキャンセル通知（`didFail` / `didFailProvisionalNavigation`）
  /// で新遷移の暫定保護・`lastRequestedURL`・`allowsInternalBlankLoad` が壊されない。
  func testOverlappingNavigationsPreserveNewPendingStateAndBlankBaseHTML() throws {
    let (browser, runtime) = try makeSheetBrowserWithRuntime()
    let webView = runtime.webView
    let spy = BrowserNavigationPolicySpy(target: runtime)
    webView.navigationDelegate = spy
    defer { webView.navigationDelegate = runtime }

    let server = try LocalLoopbackHTTPServer(responses: [
      "/stream": .partial("<!doctype html><html><body><p>streaming</p>"),
      "/hang1": .hang,
      "/hang2": .hang,
    ])
    defer { server.stop() }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    let streamURL = server.url(for: "/stream")

    // 1. 読込中 /stream → loadHTMLString(baseURL: nil): 旧 /stream の didFail(-999) で allowsInternalBlankLoad を潰さない。
    browser.load(streamURL)
    pumpMain(until: { browser.committedURL == streamURL }, timeout: 5, "/stream がコミットされる")
    XCTAssertTrue(webView.isLoading, "前提: /stream はコミット済みかつ読込継続中")
    let failBeforeBlank = spy.failCount
    let finishBeforeStreamBlank = finishCount
    browser.loadHTMLString("<!doctype html><p>from-stream</p>", baseURL: nil)
    pumpMain(
      until: { spy.failCount > failBeforeBlank && finishCount > finishBeforeStreamBlank },
      timeout: 5, "旧 /stream の didFail を経ても baseURL nil のローカル HTML が完了する")

    // 2. 読込中 /stream → /hang1 開始で旧 /stream の didFail(-999) 到着時点でも新暫定保護が解除されない。
    browser.load(streamURL)
    pumpMain(until: { browser.committedURL == streamURL }, timeout: 5, "2 回目の /stream コミット")
    var provisionalDuringDidFail: Bool?
    spy.onDidFail = { provisionalDuringDidFail = browser.isProvisionalNavigation }
    let failBefore = spy.failCount
    browser.load(server.url(for: "/hang1"))
    pumpMain(until: { spy.failCount > failBefore }, timeout: 5, "旧 /stream の didFail 到着")
    spy.onDidFail = nil
    XCTAssertEqual(provisionalDuringDidFail, true, "旧 didFail 処理直後も新 /hang1 の暫定保護が解除されない")
    nextTurn()
    XCTAssertTrue(browser.isProvisionalNavigation)
    XCTAssertEqual(browser.committedURL, streamURL)
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/stream")

    // 3. /hang1 暫定中に /hang2 → 旧 didFailProvisional(-999) で保護と lastRequestedURL が壊れず、
    // 続く loadHTMLString(baseURL: nil) も完了する。
    let provFailBefore = spy.failProvisionalCount
    let hang2URL = server.url(for: "/hang2")
    browser.load(hang2URL)
    pumpMain(
      until: { spy.failProvisionalCount > provFailBefore }, timeout: 5,
      "旧 /hang1 の didFailProvisional 到着")
    nextTurn()
    XCTAssertTrue(browser.isProvisionalNavigation, "旧暫定失敗で新 /hang2 の暫定保護が消えない")
    XCTAssertEqual(browser.lastRequestedURL, hang2URL, "旧暫定失敗で lastRequestedURL が巻き戻らない")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/stream")

    let finishBeforeBlank = finishCount
    browser.loadHTMLString("<!doctype html><p>blank-base</p>", baseURL: nil)
    pumpMain(until: { finishCount > finishBeforeBlank }, timeout: 5, "baseURL nil のローカル HTML が完了")
    XCTAssertNil(browser.committedURL)
    XCTAssertNil(browser.toolbar.displayURL)
  }

  /// ローカル HTML（`baseURL: https://...`）コミット後に別 URL への暫定遷移が失敗しても、
  /// 架空のローカル `baseURL` が `lastRequestedURL` へ昇格しない。
  func testLocalHTMLBaseURLIsNotPromotedToLastRequestedURLAfterFailedNavigation() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    let fakeBaseURL = URL(string: "https://docs.orbe.dev/guide")!
    browser.loadHTMLString("<!doctype html><p>local</p>", baseURL: fakeBaseURL)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "ローカル HTML 読み込み完了")
    XCTAssertNil(browser.lastRequestedURL, "前提: ローカル HTML コミット後は lastRequestedURL が nil")

    let closedPort = try LocalLoopbackHTTPServer.reserveClosedPort()
    let failURL = URL(string: "http://127.0.0.1:\(closedPort)/missing")!
    browser.load(failURL)
    pumpMain(until: { !browser.isProvisionalNavigation }, timeout: 5, "未起動ポートへの暫定遷移が失敗")
    nextTurn()

    XCTAssertEqual(browser.committedURL, fakeBaseURL)
    XCTAssertEqual(browser.toolbar.displayURL?.host, "docs.orbe.dev")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/guide")
    XCTAssertNil(browser.lastRequestedURL, "失敗時に架空のローカル baseURL を lastRequestedURL へ昇格しない")
  }

  private func makeSheetBrowserWithRuntime() throws -> (BrowserLayerView, BrowserTabRuntime) {
    let browser = hostBrowser().browser
    browser.setMode(.sheet, animated: false)
    let runtime = try XCTUnwrap(browser.session.ensureActiveRuntime())
    return (browser, runtime)
  }

  /// WebContent 異常終了時はリモート／ローカル HTML 暫定中・初回未確定 `https://` 要求のいずれも
  /// 暫定状態と読込表示をリセットして URL・鍵保護・`lastRequestedURL` を整え、再読込や後続遷移で復帰できる。
  func testWebContentProcessTerminationResetsStateProtectsURLAndRecovers() throws {
    let server = try LocalLoopbackHTTPServer(responses: [
      "/page-a": .html("<!doctype html><p>page-a</p>"),
      "/hang": .hang,
    ])
    defer { server.stop() }
    let pageA = server.url(for: "/page-a")

    // 1. リモートコミット済み /page-a 上で /hang 暫定遷移中に異常終了 → 状態復元し reloadPage で /page-a へ復帰。
    let (remote, remoteRuntime) = try makeSheetBrowserWithRuntime()
    var remoteFinish = 0
    remote.onNavigationFinish = { remoteFinish += 1 }
    remote.load(pageA)
    pumpMain(until: { remoteFinish >= 1 }, timeout: 5, "page-a 完了")

    remote.load(server.url(for: "/hang"))
    XCTAssertTrue(remote.isProvisionalNavigation, "前提: /hang 暫定中")
    remote.toolbar.isLoading = true
    remote.toolbar.estimatedProgress = 0.6
    remoteRuntime.webViewWebContentProcessDidTerminate(remoteRuntime.webView)
    XCTAssertFalse(remote.isProvisionalNavigation)
    XCTAssertFalse(remote.toolbar.isLoading)
    XCTAssertEqual(remote.toolbar.estimatedProgress, 0)
    XCTAssertEqual(remote.toolbar.displayURL?.path, "/page-a")
    XCTAssertEqual(remote.lastRequestedURL, pageA, "暫定先 /hang ではなくコミット済み /page-a へ戻す")

    let beforeReload = remoteFinish
    remote.reloadPage()
    pumpMain(until: { remoteFinish > beforeReload }, timeout: 5, "異常終了後に reloadPage で /page-a へ復帰")
    XCTAssertEqual(remoteRuntime.webView.url, pageA)

    // 2. ローカル HTML コミット済み上で /hang 暫定遷移中に異常終了 → lastRequestedURL を nil に戻し表示維持。
    let (local, localRuntime) = try makeSheetBrowserWithRuntime()
    var localFinish = 0
    local.onNavigationFinish = { localFinish += 1 }
    local.loadHTMLString("<p>local</p>", baseURL: URL(string: "https://docs.orbe.dev/guide"))
    pumpMain(until: { localFinish >= 1 }, timeout: 5, "ローカル HTML 完了")
    local.load(server.url(for: "/hang"))
    localRuntime.webViewWebContentProcessDidTerminate(localRuntime.webView)
    XCTAssertFalse(local.isProvisionalNavigation)
    XCTAssertNil(local.lastRequestedURL, "ローカル HTML コミット時は暫定先も架空 baseURL も残さない")
    XCTAssertEqual(local.toolbar.displayURL?.host, "docs.orbe.dev")

    // 3. 初回未確定 https:// 要求状態で異常終了 → 鍵非点灯で要求 URL を維持し、後続遷移で復帰できる。
    let hanging = try HangingLoopbackServer()
    defer { hanging.stop() }
    let (fresh, freshRuntime) = try makeSheetBrowserWithRuntime()
    var freshFinish = 0
    fresh.onNavigationFinish = { freshFinish += 1 }
    let secureTarget = URL(string: "https://127.0.0.1:\(hanging.port)/secure")!
    fresh.load(secureTarget)
    fresh.toolbar.isLoading = true
    fresh.toolbar.estimatedProgress = 0.4
    fresh.toolbar.displayURL = nil
    freshRuntime.webViewWebContentProcessDidTerminate(freshRuntime.webView)
    XCTAssertFalse(fresh.isProvisionalNavigation)
    XCTAssertFalse(fresh.toolbar.isLoading)
    XCTAssertEqual(fresh.toolbar.estimatedProgress, 0)
    XCTAssertEqual(fresh.toolbar.displayURL?.raw, secureTarget.absoluteString)
    XCTAssertEqual(fresh.toolbar.displayURL?.isSecure, false, "未確定 https:// では鍵アイコンを出さない")

    fresh.load(pageA)
    pumpMain(until: { freshFinish >= 1 }, timeout: 5, "異常終了後の後続遷移で正常復帰する")
    XCTAssertEqual(freshRuntime.webView.url, pageA)
  }

  /// `#hash` / `pushState` の同一文書 `goBack()` / `goForward()` と別文書間の履歴移動で
  /// `isProvisionalNavigation` が解放され、コミット済み URL とアドレスバーが追従する。
  func testHistoryNavigationReleasesPendingStateAcrossSameAndCrossDocumentSteps() throws {
    let browser = hostBrowser().browser
    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.session.ensureActiveRuntime()).webView

    let server = try LocalLoopbackHTTPServer(routes: [
      "/p1": "<!doctype html><h1 id='sec'>P1</h1>",
      "/p2": "<!doctype html><p>P2</p>",
    ])
    defer { server.stop() }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    let (p1, p2) = (server.url(for: "/p1"), server.url(for: "/p2"))
    browser.load(p1)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "p1 完了")

    // 1. 同一文書履歴（/p1 → /p1/s2 → /p1/s2#sec）の goBack / goForward で pending 解放と URL 追従を確認。
    webView.evaluateJavaScript("history.pushState({}, '', '/p1/s2')")
    pumpMain(until: { browser.toolbar.displayURL?.path == "/p1/s2" }, timeout: 5, "pushState 反映")
    webView.evaluateJavaScript("location.hash = '#sec'")
    pumpMain(until: { browser.toolbar.displayURL?.path == "/p1/s2#sec" }, timeout: 5, "#hash 反映")

    browser.goBack()
    XCTAssertTrue(browser.isProvisionalNavigation, "同一文書 #hash goBack 直後から暫定遷移として追跡する")
    pumpMain(
      until: { !browser.isProvisionalNavigation && browser.toolbar.displayURL?.path == "/p1/s2" },
      timeout: 5, "同一文書 #hash からの goBack が pending を解放し URL 追従する")
    XCTAssertEqual(browser.committedURL?.path, "/p1/s2")

    browser.goBack()
    XCTAssertTrue(browser.isProvisionalNavigation, "同一文書 pushState goBack 直後から暫定遷移として追跡する")
    pumpMain(
      until: { !browser.isProvisionalNavigation && browser.toolbar.displayURL?.path == "/p1" },
      timeout: 5, "同一文書 pushState からの goBack が pending を解放し URL 追従する")
    XCTAssertEqual(browser.committedURL, p1)

    browser.goForward()
    XCTAssertTrue(browser.isProvisionalNavigation, "同一文書 goForward 直後から暫定遷移として追跡する")
    pumpMain(
      until: { !browser.isProvisionalNavigation && browser.toolbar.displayURL?.path == "/p1/s2" },
      timeout: 5, "同一文書 goForward が pending を解放し URL 追従する")
    XCTAssertEqual(browser.committedURL?.path, "/p1/s2")

    // 2. 別文書間（/p1/s2 ⇄ /p2）の goBack / goForward で pending 解放と URL 追従を確認。
    let beforeP2 = finishCount
    browser.load(p2)
    pumpMain(until: { finishCount > beforeP2 }, timeout: 5, "p2 完了")

    let beforeBack = finishCount
    browser.goBack()
    XCTAssertTrue(browser.isProvisionalNavigation, "別文書 goBack 直後から暫定遷移として追跡する")
    pumpMain(
      until: { finishCount > beforeBack && !browser.isProvisionalNavigation },
      timeout: 5, "別文書 goBack が完了し pending を解放する")
    XCTAssertEqual(browser.committedURL?.path, "/p1/s2")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/p1/s2")

    let beforeForward = finishCount
    browser.goForward()
    XCTAssertTrue(browser.isProvisionalNavigation, "別文書 goForward 直後から暫定遷移として追跡する")
    pumpMain(
      until: { finishCount > beforeForward && !browser.isProvisionalNavigation },
      timeout: 5, "別文書 goForward が完了し pending を解放する")
    XCTAssertEqual(browser.committedURL, p2)
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/p2")
  }

  /// `browser.load` で非 HTTP(S) スキームがポリシー遮断されたとき、未開始 `pendingNavigation` を
  /// 解放し `lastRequestedURL` とアドレスバーをコミット済みページへ復元する。
  func testBlockedMainFrameLoadReleasesPendingAndRestoresLastRequestedURL() throws {
    let (browser, runtime) = try makeSheetBrowserWithRuntime()
    let webView = runtime.webView
    let spy = BrowserNavigationPolicySpy(target: runtime)
    webView.navigationDelegate = spy
    defer { webView.navigationDelegate = runtime }

    let server = try LocalLoopbackHTTPServer(routes: ["/p": "<!doctype html><p>ok</p>"])
    defer { server.stop() }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    let committed = server.url(for: "/p")
    browser.load(committed)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "初期ページ完了")

    let decisionsBefore = spy.decisions.count
    browser.load(URL(string: "orbe-blocked://launch")!)
    pumpMain(until: { spy.decisions.count > decisionsBefore }, timeout: 5, "カスタムスキームのポリシー判定")
    XCTAssertEqual(spy.decisions.last?.policy, .cancel)
    nextTurn()
    XCTAssertFalse(browser.isProvisionalNavigation, "ポリシー遮断後に暫定状態が残らない")
    XCTAssertEqual(browser.lastRequestedURL, committed, "ポリシー遮断後に lastRequestedURL がコミット済みへ復元される")
    XCTAssertEqual(browser.committedURL, committed)
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/p")
  }
}
