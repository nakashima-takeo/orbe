import AppKit
import OrbeTestSupport
import WebKit
import XCTest

@testable import Orbe

/// WebKit 遷移の競合・連続 API 呼び出し・非メインフレームポリシー拒否における
/// メタデータ復元と未開始 `pendingNavigation` 保護を本物の `WKWebView` で守る。
extension BrowserLayerViewTests {
  /// 先行する異オリジン遷移のコミット直前に後続の無応答遷移が重なって後続が失敗しても、
  /// `committedURL`・アドレスバー・`isSameOriginAsMainFrame`・`reloadPage()` がすべて
  /// 先行コミット先のオリジン基準へ更新され、旧オリジンへ取り残されない。
  func testSupersededOriginCommitUpdatesBarOriginPolicyAndReloadAfterTrailingFailure() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.webView)
    let spy = BrowserNavigationPolicySpy(target: browser)
    webView.navigationDelegate = spy
    defer { webView.navigationDelegate = browser }

    let serverA = try LocalLoopbackHTTPServer(routes: [
      "/page-a": "<!doctype html><p>origin-a</p>",
      "/a-child": Self.iframeClickPageHTML(target: "/a-hijack", ack: "a-clicked"),
      "/a-hijack": "<!doctype html><p>a-hijacked</p>",
    ])
    defer { serverA.stop() }
    let serverB = try LocalLoopbackHTTPServer(routes: [
      "/page-b": Self.dynamicFrameHostHTML,
      "/b-child": Self.iframeClickPageHTML(target: "/b-target", ack: "b-clicked"),
      "/b-target": "<!doctype html><p>b-allowed</p>",
    ])
    defer { serverB.stop() }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    let urlA = serverA.url(for: "/page-a")
    let urlB = serverB.url(for: "/page-b")

    // 1. オリジン A → 別オリジン B のコミット直前に無応答遷移を重ね、後続失敗後の表示とオリジン判定を検証。
    browser.load(urlA)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "オリジン A 読み込み完了")
    try triggerSupersededCommit(in: browser, spy: spy) { browser.load(urlB) }
    XCTAssertEqual(browser.committedURL, urlB, "後続失敗後も先行コミット先 B を保持する")
    XCTAssertEqual(browser.toolbar.displayURL?.host, "127.0.0.1:\(serverB.port)")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/page-b")
    XCTAssertEqual(browser.lastRequestedURL, urlB)

    // B 上で旧オリジン A の iframe からの target="_blank" は遮断され、B 同一オリジン iframe からは開ける。
    appendIframe(id: "aFrame", src: serverA.url(for: "/a-child"), in: webView)
    appendIframe(id: "bFrame", src: serverB.url(for: "/b-child"), in: webView)
    triggerCrossOriginIframeBlankClick(frameId: "aFrame", ack: "a-clicked", in: webView)
    XCTAssertTrue(
      holds(for: 0.2) { webView.url == urlB },
      "isSameOriginAsMainFrame が B 基準のため旧オリジン A の iframe からの target=_blank を遮断する")

    let finishBeforeB = finishCount
    webView.evaluateJavaScript(
      "document.getElementById('bFrame').contentDocument.getElementById('go').click()")
    pumpMain(
      until: { finishCount > finishBeforeB }, timeout: 5, "同一オリジン B iframe の target=_blank が開く")
    XCTAssertEqual(webView.url?.path, "/b-target")

    // 2. 競合直後の reloadPage() は旧オリジン A へ逆戻りせず、表示中のオリジン B を再読込する。
    let finishBeforeA2 = finishCount
    browser.load(urlA)
    pumpMain(until: { finishCount > finishBeforeA2 }, timeout: 5, "オリジン A 再読み込み完了")
    try triggerSupersededCommit(in: browser, spy: spy) { browser.load(urlB) }

    let finishBeforeReload = finishCount
    browser.reloadPage()
    pumpMain(until: { finishCount > finishBeforeReload }, timeout: 5, "reloadPage でオリジン B を再読込する")
    XCTAssertEqual(webView.url, urlB, "reloadPage が旧オリジン A へ逆戻りしない")
    XCTAssertEqual(browser.committedURL, urlB)
    XCTAssertEqual(browser.toolbar.displayURL?.host, "127.0.0.1:\(serverB.port)")
  }

  /// 先行するローカル HTML（`baseURL` あり／`nil`）のコミット直前に後続の無応答遷移が重なっても、
  /// 退避メタデータから `committedPage` と表示が正しく反映され、旧オリジン残留や架空 `baseURL` 昇格が起きない。
  func testSupersededLocalHTMLCommitAppliesMetadataAfterTrailingFailure() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.webView)
    let spy = BrowserNavigationPolicySpy(target: browser)
    webView.navigationDelegate = spy
    defer { webView.navigationDelegate = browser }

    let serverA = try LocalLoopbackHTTPServer(routes: ["/page-a": "<!doctype html><p>a</p>"])
    defer { serverA.stop() }
    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    let urlA = serverA.url(for: "/page-a")

    // 1. baseURL ありローカル HTML の先行コミット＋後続失敗 → backForwardList の旧 A ではなく baseURL を反映。
    browser.load(urlA)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "オリジン A 完了")
    let localBase = URL(string: "https://docs.orbe.dev/local")!
    try triggerSupersededCommit(in: browser, spy: spy) {
      browser.loadHTMLString("<!doctype html><p>local-base</p>", baseURL: localBase)
    }
    XCTAssertEqual(browser.committedURL, localBase, "退避メタデータのローカル baseURL を反映する")
    XCTAssertEqual(browser.toolbar.displayURL?.host, "docs.orbe.dev")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/local")
    XCTAssertNil(browser.lastRequestedURL, "ローカル HTML の架空 baseURL を lastRequestedURL へ昇格しない")

    // 2. baseURL nil ローカル HTML の先行コミット → 後続暫定中の時点で旧オリジン A をクリアする。
    let finishBeforeA2 = finishCount
    browser.load(urlA)
    pumpMain(until: { finishCount > finishBeforeA2 }, timeout: 5, "オリジン A 再完了")
    let hanging = try HangingLoopbackServer()
    defer { hanging.stop() }
    let hangURL = URL(string: "http://127.0.0.1:\(hanging.port)/hang")!
    let commitsBefore = spy.commitCount
    var injected = false
    spy.onBeforeDidCommit = { _ in
      guard !injected else { return }
      injected = true
      browser.load(hangURL)
    }
    browser.loadHTMLString("<!doctype html><p>local-blank</p>", baseURL: nil)
    pumpMain(until: { spy.commitCount > commitsBefore }, timeout: 5, "baseURL nil の先行コミット到着")
    spy.onBeforeDidCommit = nil
    XCTAssertTrue(browser.isProvisionalNavigation, "後続 hang は暫定進行中のまま")
    XCTAssertNil(browser.committedURL, "baseURL nil の先行コミットで旧オリジン A を消去する")
    XCTAssertNil(browser.toolbar.displayURL, "アドレスバーから旧オリジン A が消える")
  }

  /// `didStartProvisionalNavigation` 到着前に連続して API 遷移を重ねても、1 本目キャンセルに伴う
  /// 過渡的な `isLoading == false` 窓で新遷移の `pendingNavigation`・`lastRequestedURL`・
  /// `allowsInternalBlankLoad` が誤消去されない。
  func testRapidAPINavigationsBeforeProvisionalStartSurviveTransientNotLoadingWindow() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.webView)
    let spy = BrowserNavigationPolicySpy(target: browser)
    webView.navigationDelegate = spy
    defer { webView.navigationDelegate = browser }

    let server = try LocalLoopbackHTTPServer(responses: [
      "/page-a": .html("<!doctype html><p>a</p>"),
      "/hang1": .hang,
      "/hang2": .hang,
    ])
    defer { server.stop() }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    let pageA = server.url(for: "/page-a")
    let hang1 = server.url(for: "/hang1")
    let hang2 = server.url(for: "/hang2")

    // 1. load(hang1) 直後に load(hang2) を重ねても過渡的 isLoading == false で巻き戻らない。
    browser.load(pageA)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "page-a 完了")
    let startsBefore = spy.provisionalStartCount
    browser.load(hang1)
    browser.load(hang2)
    pumpMain(until: { spy.provisionalStartCount > startsBefore }, timeout: 5, "hang2 の暫定開始到着")
    nextTurn()
    XCTAssertTrue(browser.isProvisionalNavigation, "過渡的 isLoading == false 窓で暫定保護が消えない")
    XCTAssertEqual(browser.lastRequestedURL, hang2, "過渡窓で lastRequestedURL が旧 URL へ巻き戻らない")
    XCTAssertEqual(browser.committedURL, pageA)
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/page-a")

    // 2. load(hang1) 直後に loadHTMLString(..., baseURL: nil) を重ねても allowsInternalBlankLoad が消えない。
    let finishBeforeA2 = finishCount
    browser.load(pageA)
    pumpMain(until: { finishCount > finishBeforeA2 }, timeout: 5, "page-a 再完了")
    let finishBeforeBlank = finishCount
    browser.load(hang1)
    browser.loadHTMLString("<!doctype html><p id='ok'>rapid-blank</p>", baseURL: nil)
    pumpMain(
      until: { finishCount > finishBeforeBlank }, timeout: 5,
      "過渡窓を経ても baseURL nil のローカル HTML が読み込める")
    XCTAssertNil(browser.committedURL)
    XCTAssertNil(browser.toolbar.displayURL)
    XCTAssertEqual(
      evaluateString("document.getElementById('ok')?.textContent", in: webView), "rapid-blank")
  }

  /// 同一ターンの連続 `loadHTMLString(..., baseURL: nil)` で 2 回目の本命が `.cancel` されず完了し、
  /// 未開始メインフレーム `pendingNavigation` 進行中の `target="_blank"` 拒否でも本命が誤消去されない。
  func testConsecutiveBlankLocalHTMLAndNonMainFrameCancelPreservePendingNavigation() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.webView)
    let spy = BrowserNavigationPolicySpy(target: browser)
    webView.navigationDelegate = spy
    defer { webView.navigationDelegate = browser }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }

    // 1. 同一ターンで baseURL nil を 2 回続けて呼んでも 1 回目の decidePolicyFor で許可枠を消費しない。
    let decisionsBefore = spy.decisions.count
    let finishBefore = finishCount
    browser.loadHTMLString("<!doctype html><p id='ver'>first</p>", baseURL: nil)
    browser.loadHTMLString("<!doctype html><p id='ver'>second</p>", baseURL: nil)
    pumpMain(until: { finishCount > finishBefore }, timeout: 5, "2 回目の baseURL nil が完了する")
    let newDecisions = spy.decisions.dropFirst(decisionsBefore)
    XCTAssertFalse(
      newDecisions.contains { $0.url?.absoluteString == "about:blank" && $0.policy == .cancel },
      "連続 loadHTMLString(baseURL: nil) で本命が .cancel されない")
    XCTAssertEqual(
      evaluateString("document.getElementById('ver')?.textContent", in: webView), "second")

    // 2. 未開始 pendingNavigation 進行中に target="_blank" (about:blank) が拒否されても本命を誤消去しない。
    let server = try LocalLoopbackHTTPServer(routes: [
      "/links": "<!doctype html><a id='blank' href='about:blank' target='_blank'>b</a>"
    ])
    defer { server.stop() }
    let finishBeforeLinks = finishCount
    browser.load(server.url(for: "/links"))
    pumpMain(until: { finishCount > finishBeforeLinks }, timeout: 5, "links ページ完了")

    var injected = false
    var interceptedBlankDecisionIndex: Int?
    let finishBeforeProtected = finishCount
    spy.onBeforeDecidePolicy = { action in
      guard !injected, action.targetFrame == nil,
        action.request.url?.absoluteString == "about:blank"
      else { return }
      injected = true
      interceptedBlankDecisionIndex = spy.decisions.count
      browser.loadHTMLString("<!doctype html><p id='ver'>kept</p>", baseURL: nil)
    }
    webView.evaluateJavaScript("document.getElementById('blank').click()")
    pumpMain(
      until: { finishCount > finishBeforeProtected }, timeout: 5,
      "target=_blank 拒否後も本命 loadHTMLString(baseURL: nil) が完了する")
    spy.onBeforeDecidePolicy = nil

    let blankIndex = try XCTUnwrap(
      interceptedBlankDecisionIndex, "target=_blank の decidePolicyFor を捕捉")
    XCTAssertEqual(
      spy.decisions[blankIndex].policy, .cancel,
      "target=_blank の about:blank は allowsInternalBlankLoad を横取りせず .cancel される")
    XCTAssertEqual(
      evaluateString("document.getElementById('ver')?.textContent", in: webView), "kept")
  }

  // MARK: - 競合テスト補助

  private func triggerSupersededCommit(
    in browser: BrowserLayerView, spy: BrowserNavigationPolicySpy,
    commitTrigger: () -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let hanging = try HangingLoopbackServer()
    defer { hanging.stop() }
    let hangURL = URL(string: "http://127.0.0.1:\(hanging.port)/trailing-hang")!
    let commitsBefore = spy.commitCount
    var injected = false
    var startsBefore = 0
    var failBefore = 0
    spy.onBeforeDidCommit = { _ in
      guard !injected else { return }
      injected = true
      startsBefore = spy.provisionalStartCount
      failBefore = spy.failProvisionalCount
      browser.load(hangURL)
    }
    commitTrigger()
    pumpMain(
      until: { injected && spy.commitCount > commitsBefore }, timeout: 5, "先行コミット到着",
      file: file, line: line)
    spy.onBeforeDidCommit = nil
    XCTAssertTrue(browser.isProvisionalNavigation, "先行コミット直後は後続 hang が暫定中", file: file, line: line)
    XCTAssertEqual(browser.lastRequestedURL, hangURL, file: file, line: line)
    pumpMain(
      until: { spy.provisionalStartCount > startsBefore }, timeout: 5, "後続 hang の暫定開始",
      file: file, line: line)
    hanging.stop()
    pumpMain(
      until: { spy.failProvisionalCount > failBefore && !browser.isProvisionalNavigation },
      timeout: 5, "後続 hang の失敗完了", file: file, line: line)
    nextTurn(file: file, line: line)
  }

  private func appendIframe(
    id: String, src: URL, in webView: WKWebView,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    var done = false
    webView.callAsyncJavaScript(
      "return await window.__appendFrame(id, src);",
      arguments: ["id": id, "src": src.absoluteString], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result {
        XCTFail("iframe 追加失敗: \(error)", file: file, line: line)
      }
      done = true
    }
    pumpMain(until: { done }, timeout: 5, "iframe 読み込み完了 (\(id))", file: file, line: line)
  }

  private func triggerCrossOriginIframeBlankClick(
    frameId: String, ack: String, in webView: WKWebView,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    // ユーザー操作コンテキストを保った同期 evaluateJavaScript から直接 postMessage を送る。
    webView.evaluateJavaScript(
      "document.getElementById('\(frameId)').contentWindow.postMessage('go', '*')")
    var done = false
    webView.callAsyncJavaScript(
      "return await window.__waitAck(ack);", arguments: ["ack": ack], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result {
        XCTFail("iframe ack 待機失敗: \(error)", file: file, line: line)
      }
      done = true
    }
    pumpMain(until: { done }, timeout: 5, "iframe クリック応答 (\(ack))", file: file, line: line)
  }

  private func evaluateString(
    _ expression: String, in webView: WKWebView,
    file: StaticString = #filePath, line: UInt = #line
  ) -> String? {
    var resultValue: String?
    var done = false
    webView.evaluateJavaScript(expression) { value, _ in
      resultValue = value as? String
      done = true
    }
    pumpMain(until: { done }, timeout: 5, "JS 評価完了", file: file, line: line)
    return resultValue
  }

  private static func iframeClickPageHTML(target: String, ack: String) -> String {
    """
    <!doctype html>
    <a id='go' href='\(target)' target='_blank'>go</a>
    <script>
    window.addEventListener('message', () => {
      document.getElementById('go').click();
      parent.postMessage('\(ack)', '*');
    });
    </script>
    """
  }

  private static let dynamicFrameHostHTML = """
    <!doctype html>
    <p>origin-b</p>
    <script>
    window.__acks = [];
    window.__waiters = [];
    window.addEventListener('message', e => {
      window.__acks.push(e.data);
      window.__waiters = window.__waiters.filter(fn => !fn());
    });
    window.__waitAck = ack => new Promise(resolve => {
      const check = () => {
        if (window.__acks.includes(ack)) { resolve(true); return true; }
        return false;
      };
      if (!check()) { window.__waiters.push(check); }
    });
    window.__appendFrame = (id, src) => new Promise(resolve => {
      const f = document.createElement('iframe');
      f.id = id;
      f.onload = () => resolve(true);
      f.src = src;
      document.body.appendChild(f);
    });
    </script>
    """
}
