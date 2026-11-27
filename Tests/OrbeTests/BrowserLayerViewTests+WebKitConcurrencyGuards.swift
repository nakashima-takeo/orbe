import AppKit
import OrbeTestSupport
import WebKit
import XCTest

@testable import Orbe

/// 非 BFCache 履歴移動失敗後の先行 `reload`（302 リダイレクト経由含む）URL 解決、
/// 未開始 API 遷移と先行 WebContent 遷移キャンセルの本命復帰、および先行同一文書遷移・
/// ページ内 `pushState`/`#hash` からの無関係後続 `load` 保護を本物の `WKWebView` で守る。
extension BrowserLayerViewTests {
  private struct ConcurrencyHarness {
    let browser: BrowserLayerView
    let runtime: BrowserTabRuntime
    let webView: WKWebView
    let spy: BrowserNavigationPolicySpy
  }

  private struct NonBFCacheTransition {
    let serverA: LocalLoopbackHTTPServer
    let urlA: URL
    let urlB: URL
  }

  private struct PendingGuardCase {
    let targetURL: URL
    let label: String
    let trigger: () -> Void
    var afterDefer: (() -> Void)?
    let waitMutation: () -> Bool
    var expectsStartOnResume = true
  }

  /// 非 BFCache オリジン A への `goBack()` 暫定失敗で `backForwardList.currentItem` が A へ張り付いた後、
  /// 表示中オリジン B の `reloadPage()` コミット直前に後続失敗遷移が重なっても、`committedURL`・
  /// アドレスバー・`isSameOriginAsMainFrame`・`reloadPage()` は未到達 A へ乖離せず B を保つ。
  func testSupersededReloadAfterFailedNonBFCacheHistoryNavigationKeepsDisplayedOrigin() throws {
    let harness = try makeConcurrencyHarness()
    defer { harness.webView.navigationDelegate = harness.runtime }

    let serverA1 = try LocalLoopbackHTTPServer(responses: [
      "/page-a": .partial("<!doctype html><p>origin-a</p>")
    ])
    let portA = serverA1.port
    let urlA = serverA1.url(for: "/page-a")
    let serverB = try LocalLoopbackHTTPServer(routes: [
      "/page-b": Self.dynamicFrameHostHTML,
      "/b-child": Self.iframeClickPageHTML(target: "/b-target", ack: "b-clicked"),
      "/b-target": "<!doctype html><p>b-allowed</p>",
    ])
    defer { serverB.stop() }
    let urlB = serverB.url(for: "/page-b")

    var finishCount = 0
    harness.browser.onNavigationFinish = { finishCount += 1 }
    prepareFailedNonBFCacheGoBack(
      NonBFCacheTransition(serverA: serverA1, urlA: urlA, urlB: urlB),
      in: harness, finishCount: { finishCount })

    // 同一ポートでオリジン A を再起動し、iframe 検証と reloadPage の非逆戻りを本物サーバーで確かめる。
    let serverA2 = try LocalLoopbackHTTPServer(
      port: portA,
      routes: [
        "/page-a": "<!doctype html><p>origin-a-restarted</p>",
        "/a-child": Self.iframeClickPageHTML(target: "/a-hijack", ack: "a-clicked"),
        "/a-hijack": "<!doctype html><p>a-hijacked</p>",
      ])
    defer { serverA2.stop() }

    try triggerSupersededCommit(in: harness.browser, spy: harness.spy) {
      harness.browser.reloadPage()
    }
    XCTAssertEqual(harness.browser.committedURL, urlB, "未到達オリジン A ではなく実表示中の B を保持する")
    XCTAssertEqual(harness.browser.toolbar.displayURL?.host, "127.0.0.1:\(serverB.port)")
    XCTAssertEqual(harness.browser.toolbar.displayURL?.path, "/page-b")
    XCTAssertEqual(harness.browser.lastRequestedURL, urlB)

    // isSameOriginAsMainFrame が B 基準のため A iframe は遮断され、B への reloadPage も A へ戻らない。
    appendIframe(id: "aFrame", src: serverA2.url(for: "/a-child"), in: harness.webView)
    triggerCrossOriginIframeBlankClick(frameId: "aFrame", ack: "a-clicked", in: harness.webView)
    XCTAssertTrue(
      holds(for: 0.2) { harness.webView.url == urlB },
      "isSameOriginAsMainFrame が B 基準のまま未到達オリジン A の iframe を遮断する")

    let finishBeforeReload = finishCount
    harness.browser.reloadPage()
    pumpMain(until: { finishCount > finishBeforeReload }, timeout: 5, "reloadPage で B を再読込する")
    XCTAssertEqual(harness.webView.url, urlB, "reloadPage が未到達オリジン A へ逆戻りしない")
    XCTAssertEqual(harness.browser.committedURL, urlB)

    appendIframe(id: "bFrame", src: serverB.url(for: "/b-child"), in: harness.webView)
    let finishBeforeB = finishCount
    harness.webView.evaluateJavaScript(
      "document.getElementById('bFrame').contentDocument.getElementById('go').click()")
    pumpMain(
      until: { finishCount > finishBeforeB }, timeout: 5, "同一オリジン B iframe の target=_blank が開く")
    XCTAssertEqual(harness.webView.url?.path, "/b-target")
  }

  /// 非 BFCache 履歴移動失敗後の `reloadPage()` が 302 リダイレクトを経由し `didCommit` 直前に
  /// 後続失敗遷移が重なっても、リダイレクト先 URL を `committedURL`・アドレスバーへ反映する。
  func testSupersededRedirectReloadAfterFailedNonBFCacheHistoryNavigationKeepsRedirectTarget()
    throws
  {
    let harness = try makeConcurrencyHarness()
    defer { harness.webView.navigationDelegate = harness.runtime }

    let serverA = try LocalLoopbackHTTPServer(responses: [
      "/page-a": .partial("<!doctype html><p>origin-a</p>")
    ])
    let urlA = serverA.url(for: "/page-a")
    let serverB = try LocalLoopbackHTTPServer(responses: [
      "/page-b": .sequence([
        .html("<!doctype html><p>origin-b-initial</p>"),
        .redirect("/page-b-redirected"),
      ]),
      "/page-b-redirected": .html("<!doctype html><p>origin-b-redirected</p>"),
    ])
    defer { serverB.stop() }
    let urlB = serverB.url(for: "/page-b")
    let redirectedURL = serverB.url(for: "/page-b-redirected")

    var finishCount = 0
    harness.browser.onNavigationFinish = { finishCount += 1 }
    prepareFailedNonBFCacheGoBack(
      NonBFCacheTransition(serverA: serverA, urlA: urlA, urlB: urlB),
      in: harness, finishCount: { finishCount })

    let redirectsBefore = harness.spy.redirectCount
    try triggerSupersededCommit(in: harness.browser, spy: harness.spy) {
      harness.browser.reloadPage()
    }
    XCTAssertGreaterThan(harness.spy.redirectCount, redirectsBefore, "前提: 302 リダイレクト経路を通過する")
    XCTAssertEqual(harness.browser.committedURL, redirectedURL, "リダイレクト後の最終到達 URL を保持する")
    XCTAssertEqual(harness.browser.toolbar.displayURL?.host, "127.0.0.1:\(serverB.port)")
    XCTAssertEqual(harness.browser.toolbar.displayURL?.path, "/page-b-redirected")
    XCTAssertEqual(harness.browser.lastRequestedURL, redirectedURL)
  }

  /// 先行 WebContent 遷移（`nav1`）の `didStartProvisionalNavigation` が未開始の本命 API 遷移（`nav2`）を
  /// 上書きして直後に `nav1` がキャンセルされても、`nav2` の暫定開始が握り潰されず
  /// `isProvisionalNavigation == true` と本命の `lastRequestedURL` が復元される。
  func testCanceledWebContentNavigationDoesNotSupersedeUnstartedAPINavigation() throws {
    let harness = try makeConcurrencyHarness()
    defer { harness.webView.navigationDelegate = harness.runtime }

    let originServer = try LocalLoopbackHTTPServer(responses: [
      "/origin": .html("<!doctype html><a id='go' href='/link-hang'>go</a>"),
      "/link-hang": .hang,
    ])
    defer { originServer.stop() }
    let targetServer = try HangingLoopbackServer()
    defer { targetServer.stop() }

    var finishCount = 0
    harness.browser.onNavigationFinish = { finishCount += 1 }
    let originURL = originServer.url(for: "/origin")
    let targetURL = URL(string: "http://127.0.0.1:\(targetServer.port)/target")!
    harness.browser.load(originURL)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "origin 完了")

    var events: [String] = []
    weak var firstNav: WKNavigation?
    var injectedTarget = false
    harness.spy.onBeforeDidStartProvisional = { navigation in
      guard !injectedTarget else { return }
      injectedTarget = true
      firstNav = navigation
      harness.browser.load(targetURL)
    }
    harness.spy.onDidStartProvisional = { navigation in
      events.append(navigation === firstNav ? "start:nav1" : "start:nav2")
    }
    harness.spy.onDidFailProvisional = { navigation in
      events.append(navigation === firstNav ? "fail:nav1" : "fail:nav2")
    }

    harness.webView.evaluateJavaScript("document.getElementById('go').click()")
    pumpMain(
      until: { events.contains("fail:nav1") && events.contains("start:nav2") }, timeout: 5,
      "先行 nav1 キャンセルと本命 nav2 暫定開始の完了")
    harness.spy.onBeforeDidStartProvisional = nil
    harness.spy.onDidStartProvisional = nil
    nextTurn()

    XCTAssertEqual(
      events.prefix(3), ["start:nav1", "fail:nav1", "start:nav2"],
      "前提: 先行開始→先行キャンセル→本命開始の競合順を通過する")
    XCTAssertTrue(harness.browser.isProvisionalNavigation, "本命 nav2 の暫定追跡が握り潰されず復帰する")
    XCTAssertEqual(harness.browser.lastRequestedURL, targetURL, "本命 nav2 の lastRequestedURL が復元される")
    XCTAssertEqual(harness.browser.committedURL, originURL)
    XCTAssertEqual(harness.browser.toolbar.displayURL?.path, "/origin")

    let failBeforeStop = harness.spy.failProvisionalCount
    targetServer.stop()
    pumpMain(
      until: {
        harness.spy.failProvisionalCount > failBeforeStop
          && !harness.browser.isProvisionalNavigation
      }, timeout: 5, "本命 nav2 失敗後に暫定追跡が解除される")
    XCTAssertEqual(harness.browser.lastRequestedURL, originURL)
  }

  /// 同一文書 `goBack()` や `#hash` `load` の直後に別ページへ `browser.load(target)` を重ねても、
  /// 先行同一文書遷移の完了通知で無関係な `target` の `pendingNavigation` と `lastRequestedURL` が
  /// 誤消去されない。対として正当な同一文書 `#hash` `load` は完了時に回収される。
  func testSameDocumentNavigationDoesNotEraseTrailingUnrelatedPendingLoad() throws {
    let harness = try makeConcurrencyHarness()
    defer { harness.webView.navigationDelegate = harness.runtime }

    let server = try LocalLoopbackHTTPServer(responses: [
      "/p1": .html("<!doctype html><h1 id='sec'>P1</h1>"),
      "/target": .hang,
    ])
    defer { server.stop() }

    var finishCount = 0
    harness.browser.onNavigationFinish = { finishCount += 1 }
    let page1 = server.url(for: "/p1")
    let page1Hash = server.url(for: "/p1#sec")
    let targetURL = server.url(for: "/target")

    harness.browser.load(page1)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "p1 完了")

    // 対の動作: 正当な同一文書 #hash load は同期的に暫定開始し完了時に回収される。
    harness.browser.load(page1Hash)
    XCTAssertTrue(harness.browser.isProvisionalNavigation, "同一文書 #hash load も直後は暫定追跡する")
    pumpMain(
      until: {
        !harness.browser.isProvisionalNavigation && harness.browser.committedURL?.fragment == "sec"
      }, timeout: 5, "正当な同一文書 #hash load は回収される")

    // 1. 同一文書 goBack() 直後に別ページ load(target) を重ねても target が誤消去されない。
    harness.webView.evaluateJavaScript("history.pushState({}, '', '/p1/s2')")
    pumpMain(
      until: { harness.browser.toolbar.displayURL?.path == "/p1/s2" }, timeout: 5, "pushState 反映")
    assertPendingSurvives(
      PendingGuardCase(
        targetURL: targetURL, label: "同一文書 goBack 直後の別ページ load",
        trigger: {
          harness.browser.goBack()
          harness.browser.load(targetURL)
        },
        waitMutation: { harness.webView.url?.fragment == "sec" }),
      in: harness)

    // 2. 同一文書 #hash load 直後に別ページ load(target) を重ねても target が誤消去されない。
    let finishBeforeReset = finishCount
    harness.browser.load(page1)
    pumpMain(until: { finishCount > finishBeforeReset }, timeout: 5, "p1 再読込完了")
    assertPendingSurvives(
      PendingGuardCase(
        targetURL: targetURL, label: "同一文書 #hash load 直後の別ページ load",
        trigger: {
          harness.browser.load(page1Hash)
          harness.browser.load(targetURL)
        },
        waitMutation: { harness.webView.url?.fragment == "sec" }),
      in: harness)
  }

  /// 別ページ `browser.load(target)` の未開始窓でページ内 JS の `history.pushState` や
  /// `location.hash` が起きても、`target` の `pendingNavigation` と `lastRequestedURL` が誤消去されない。
  func testInPageScriptStateChangesInUnstartedWindowPreservePendingLoad() throws {
    let harness = try makeConcurrencyHarness()
    defer { harness.webView.navigationDelegate = harness.runtime }

    let server = try LocalLoopbackHTTPServer(responses: [
      "/p1": .html("<!doctype html><h1 id='sec'>P1</h1>"),
      "/target": .hang,
    ])
    defer { server.stop() }

    var finishCount = 0
    harness.browser.onNavigationFinish = { finishCount += 1 }
    let page1 = server.url(for: "/p1")
    let targetURL = server.url(for: "/target")

    harness.browser.load(page1)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "p1 完了")

    // 1. 未開始窓での JS history.pushState で target の暫定保護と要求 URL が消えない。
    assertPendingSurvives(
      PendingGuardCase(
        targetURL: targetURL, label: "未開始窓の JS pushState",
        trigger: { harness.browser.load(targetURL) },
        afterDefer: {
          harness.webView.evaluateJavaScript("history.pushState({}, '', '/p1/pushed')")
        },
        waitMutation: { harness.webView.url?.path == "/p1/pushed" },
        expectsStartOnResume: true),
      in: harness)

    // 2. 未開始窓での JS location.hash で target の暫定保護と要求 URL が消えない。
    let finishBeforeReset = finishCount
    harness.browser.load(page1)
    pumpMain(until: { finishCount > finishBeforeReset }, timeout: 5, "p1 再読込完了")
    assertPendingSurvives(
      PendingGuardCase(
        targetURL: targetURL, label: "未開始窓の JS location.hash",
        trigger: { harness.browser.load(targetURL) },
        afterDefer: { harness.webView.evaluateJavaScript("location.hash = '#sec'") },
        waitMutation: { harness.webView.url?.fragment == "sec" },
        expectsStartOnResume: false),
      in: harness)
  }

  // MARK: - 競合ガード補助

  private func makeConcurrencyHarness() throws -> ConcurrencyHarness {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    let runtime = try prepareEmptyRuntimeForObservation(in: browser)
    let webView = runtime.webView
    let spy = BrowserNavigationPolicySpy(target: runtime)
    webView.navigationDelegate = spy
    return ConcurrencyHarness(browser: browser, runtime: runtime, webView: webView, spy: spy)
  }

  private func prepareFailedNonBFCacheGoBack(
    _ transition: NonBFCacheTransition,
    in harness: ConcurrencyHarness,
    finishCount: @escaping () -> Int,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    // 読込未完了（partial）でコミットしたページは BFCache に入らず、サーバー停止後の goBack が暫定失敗する。
    harness.browser.load(transition.urlA)
    pumpMain(
      until: { harness.browser.committedURL == transition.urlA }, timeout: 5,
      "非 BFCache オリジン A コミット", file: file, line: line)

    let beforeB = finishCount()
    harness.browser.load(transition.urlB)
    pumpMain(
      until: { finishCount() > beforeB }, timeout: 5, "オリジン B 完了",
      file: file, line: line)

    transition.serverA.stop()
    let failBefore = harness.spy.failProvisionalCount
    harness.browser.goBack()
    pumpMain(
      until: {
        harness.spy.failProvisionalCount > failBefore && !harness.browser.isProvisionalNavigation
      }, timeout: 5, "非 BFCache オリジン A への goBack 暫定失敗", file: file, line: line)
    nextTurn(file: file, line: line)
    XCTAssertEqual(
      harness.webView.backForwardList.currentItem?.url, transition.urlA,
      "前提: 非 BFCache goBack 失敗後に currentItem が未到達オリジン A へ張り付く",
      file: file, line: line)
    XCTAssertEqual(
      harness.webView.url, transition.urlB, "前提: 実表示と webView.url は B に留まる",
      file: file, line: line)
  }

  private func assertPendingSurvives(
    _ spec: PendingGuardCase,
    in harness: ConcurrencyHarness,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    var resumeTarget: (@MainActor () -> Void)?
    harness.spy.deferDecision = { action, proceed in
      guard action.request.url == spec.targetURL else { return false }
      resumeTarget = proceed
      return true
    }
    spec.trigger()
    pumpMain(
      until: { resumeTarget != nil }, timeout: 5, "\(spec.label): target の未開始窓へ到達",
      file: file, line: line)
    spec.afterDefer?()
    pumpMain(
      until: spec.waitMutation, timeout: 5, "\(spec.label): 同一文書変更が URL へ反映される",
      file: file, line: line)
    nextTurn(file: file, line: line)
    XCTAssertTrue(
      harness.browser.isProvisionalNavigation, "\(spec.label): 暫定保護が誤消去されない",
      file: file, line: line)
    XCTAssertEqual(
      harness.browser.lastRequestedURL, spec.targetURL, "\(spec.label): 要求 URL が巻き戻らない",
      file: file, line: line)

    let startsBefore = harness.spy.provisionalStartCount
    harness.spy.deferDecision = nil
    resumeTarget?()
    if spec.expectsStartOnResume {
      pumpMain(
        until: { harness.spy.provisionalStartCount > startsBefore }, timeout: 5,
        "\(spec.label): target 暫定開始", file: file, line: line)
      XCTAssertTrue(harness.browser.isProvisionalNavigation, file: file, line: line)
      XCTAssertEqual(harness.browser.lastRequestedURL, spec.targetURL, file: file, line: line)
    }
  }
}
