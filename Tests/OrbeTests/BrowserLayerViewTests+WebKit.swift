import AppKit
import OrbeTestSupport
import WebKit
import XCTest

@testable import Orbe

/// 本物の `WKWebView` とローカルループバック TCP/HTTP サーバー（外部通信ゼロ）で、
/// スキーム制限（`decidePolicyFor`）・ポップアップ遮断と同一オリジン iframe 許可（`createWebViewWith`）・
/// JS ダイアログ即応答・初回失敗後の `⌘R` / 再読込復帰を守る。
extension BrowserLayerViewTests {
  /// ローカル HTML 遷移後の焦点移行・JS ダイアログの非モーダル即キャンセル応答・
  /// `target="_blank"` 同一面遷移を本物の `WKWebView` で確かめる。
  func testWebKitIntegrationLocalHTMLDialogsAndPopup() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.webView)

    let server = try LocalLoopbackHTTPServer(routes: [
      "/page1.html": "<!doctype html><a id='go' href='/page2.html' target='_blank'>go</a>",
      "/page2.html": "<!doctype html><title>Page2</title><p>second</p>",
    ])
    defer { server.stop() }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    browser.loadHTMLString("<p>local</p>", baseURL: URL(string: "https://docs.orbe.dev/guide"))
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "ローカル HTML の読み込み完了")
    XCTAssertTrue(browser.hasNavigated)
    XCTAssertTrue(browser.emptyOverlay.isHidden)
    XCTAssertTrue(browser.focusTarget === webView, "遷移後の焦点宛先は WKWebView")
    XCTAssertEqual(browser.toolbar.displayURL?.host, "docs.orbe.dev")
    XCTAssertEqual(browser.toolbar.displayURL?.isSecure, true)

    // JS alert / confirm / prompt は実シートを出さず即座にキャンセル応答を返す。
    var dialogResult: String?
    webView.evaluateJavaScript(
      "(() => { alert('a'); return JSON.stringify({c: confirm('b'), p: prompt('c', 'd')}); })()"
    ) { value, _ in
      dialogResult = value as? String
    }
    pumpMain(until: { dialogResult != nil }, timeout: 5, "JS ダイアログがハングせず即応答する")
    XCTAssertEqual(dialogResult, #"{"c":false,"p":null}"#)

    // target="_blank"（新規ウィンドウ要求）は別窓を出さず同一 webView で開く。
    let beforePop = finishCount
    browser.load(server.url(for: "/page1.html"))
    pumpMain(until: { finishCount > beforePop }, timeout: 5, "page1 読み込み完了")
    let beforeBlank = finishCount
    webView.evaluateJavaScript("document.getElementById('go').click()")
    pumpMain(until: { finishCount > beforeBlank }, timeout: 5, "target=_blank が同一面へ遷移する")
    XCTAssertEqual(webView.url?.path, "/page2.html")
  }

  /// メインフレームの非 HTTP(S) スキーム（`file:`・`data:` 通常遷移・未登録カスタムスキーム）と自動 `window.open`、
  /// および `data:` / `about:blank` / クロスオリジン iframe（200 OK 先）/ sandboxed iframe の `target="_blank"` を
  /// 独立して遮断し、許可されたサブフレーム（`data:`）と同一オリジン iframe からの `target="_blank"` HTTP リンクのみ通す。
  func testNavigationPolicyAndPopupGuardsBlockUnsafeTargetsAndAllowSameOriginSubframe() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.webView)
    XCTAssertFalse(
      webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically,
      "スクリプト自動ポップアップは WebKit 設定で抑止する")
    let spy = BrowserNavigationPolicySpy(target: browser)
    webView.navigationDelegate = spy
    defer { webView.navigationDelegate = browser }

    let crossServer = try LocalLoopbackHTTPServer(routes: [
      "/cross": Self.crossOriginFrameHTML,
      "/cross-hijack": "<!doctype html><p>cross hijacked</p>",
    ])
    defer { crossServer.stop() }
    let mainServer = try LocalLoopbackHTTPServer(
      routes: Self.policyTestRoutes(crossURL: crossServer.url(for: "/cross").absoluteString))
    defer { mainServer.stop() }

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    let mainURL = mainServer.url(for: "/main")
    browser.load(mainURL)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "メインページ読み込み完了")
    XCTAssertEqual(webView.url, mainURL, "読み込み時の自動 window.open で遷移しない")

    waitForJS(
      "return await window.__waitFor(() => window.__dataLoaded === true);",
      in: webView, "サブフレームの data: は読み込める")

    // メインフレーム非 HTTP(S) 3 経路を互いに上書きせず独立に遮断検証する。
    let blockedFile = try caseFile("blocked.html", "<p>file</p>")
    let ctx = BlockedNavigationCheck(webView: webView, spy: spy, mainURL: mainURL)
    assertBlockedMainNavigation("メインフレーム file:", in: ctx) {
      webView.loadFileURL(
        blockedFile, allowingReadAccessTo: blockedFile.deletingLastPathComponent())
    }
    assertBlockedMainNavigation("メインフレーム data: 通常遷移", in: ctx) {
      webView.load(URLRequest(url: URL(string: "data:text/html,<h1>evil</h1>")!))
    }
    assertBlockedMainNavigation("未登録カスタムスキーム", in: ctx) {
      webView.load(URLRequest(url: URL(string: "orbe-blocked://launch")!))
    }
    XCTAssertEqual(finishCount, 1, "遮断したメインフレーム遷移で完了回数が増えない")

    // 危険な target="_blank"（about:blank / data: / カスタム / 異オリジン・sandbox iframe）を遮断する。
    webView.evaluateJavaScript(Self.triggerBlockedNavigationsJS)
    waitForJS(
      "return await window.__waitFor(() => window.__acks.length >= 2);",
      in: webView, "クロスオリジン・sandboxed 両 iframe がクリックを実行した")
    XCTAssertTrue(
      holds(for: 0.2) { webView.url == mainURL && finishCount == 1 },
      "非 HTTP(S)・自動ポップアップ・クロスオリジン/sandboxed iframe からの遷移はすべて遮断される")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/main")

    // 対の経路: 同一オリジン iframe からの target="_blank" HTTP リンクは同一面で開ける。
    let startsBeforeAllow = spy.provisionalStartCount
    webView.evaluateJavaScript(
      "document.getElementById('sameFrame').contentDocument.getElementById('go').click()")
    pumpMain(until: { finishCount >= 2 }, timeout: 5, "同一オリジン iframe の target=_blank が開く")
    XCTAssertGreaterThan(spy.provisionalStartCount, startsBeforeAllow)
    XCTAssertEqual(webView.url?.path, "/same-target")
  }

  /// 初回遷移が接続拒否で失敗（`webView.url == nil`）した後、サーバーが起動してから `⌘R` や再読込ボタンを
  /// 押すと、要求済み URL を再試行してページが表示される。
  func testInitialFailureCanBeReloadedWithCommandRAndReloadButton() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    browser.focusBrowser()

    let port = try LocalLoopbackHTTPServer.reserveClosedPort()
    let url = URL(string: "http://127.0.0.1:\(port)/app")!
    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }

    // 1. サーバー未起動で初回遷移が失敗する。
    try loadAndWaitForInitialFailure(url, in: browser, "初回接続拒否で失敗終了")
    XCTAssertEqual(finishCount, 0)
    XCTAssertNil(browser.webView?.url, "前提: 初回失敗後は webView.url が nil")
    XCTAssertEqual(browser.toolbar.displayURL?.raw, url.absoluteString)
    XCTAssertEqual(browser.toolbar.displayURL?.isSecure, false)

    // 2. サーバー起動後に ⌘R を押すと lastRequestedURL で再読込して成功する。
    let server = try LocalLoopbackHTTPServer(
      port: port, routes: ["/app": "<!doctype html><p>ok</p>"])
    defer { server.stop() }
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("r")), "⌘R で再読込を起動する")
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "⌘R 再読込でページ読み込みが完了する")
    XCTAssertEqual(browser.webView?.url, url)
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/app")

    // 3. ツールバー再読込ボタン（reloadOrStop）でも初回失敗から復帰できる。
    let second = hostBrowser().browser
    second.setMode(.sheet, animated: false)
    let port2 = try LocalLoopbackHTTPServer.reserveClosedPort()
    let url2 = URL(string: "http://127.0.0.1:\(port2)/btn")!
    var finish2 = 0
    second.onNavigationFinish = { finish2 += 1 }
    try loadAndWaitForInitialFailure(url2, in: second, "2 件目の初回失敗完了")
    let server2 = try LocalLoopbackHTTPServer(port: port2, routes: ["/btn": "<p>btn</p>"])
    defer { server2.stop() }
    second.reloadOrStop()
    pumpMain(until: { finish2 >= 1 }, timeout: 5, "再読込ボタンでページ読み込みが完了する")
    XCTAssertEqual(second.webView?.url, url2)
  }

  // MARK: - WebKit テスト補助

  private struct BlockedNavigationCheck {
    let webView: WKWebView
    let spy: BrowserNavigationPolicySpy
    let mainURL: URL
  }

  private func waitForJS(
    _ body: String, in webView: WKWebView, _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    var settled = false
    webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
      if case .failure(let error) = result {
        XCTFail("JS 待機失敗（\(label)）: \(error)", file: file, line: line)
      }
      settled = true
    }
    pumpMain(until: { settled }, timeout: 5, label, file: file, line: line)
  }

  private func assertBlockedMainNavigation(
    _ label: String, in ctx: BlockedNavigationCheck, trigger: () -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let decisionsBefore = ctx.spy.decisions.count
    let startsBefore = ctx.spy.provisionalStartCount
    trigger()
    pumpMain(
      until: { ctx.spy.decisions.count > decisionsBefore }, timeout: 5, label,
      file: file, line: line)
    XCTAssertEqual(
      ctx.spy.decisions.last?.policy, .cancel, "\(label) は decidePolicyFor で .cancel される",
      file: file, line: line)
    nextTurn(file: file, line: line)
    XCTAssertEqual(
      ctx.spy.provisionalStartCount, startsBefore, "\(label) は didStartProvisionalNavigation へ進まない",
      file: file, line: line)
    XCTAssertEqual(ctx.webView.url, ctx.mainURL, "\(label) で現在ページが変わらない", file: file, line: line)
  }

  /// `webView.isLoading` の `true → false` 遷移を KVO で確実に捕まえてから `browser.load(_:)` を呼び、
  /// 読み込み開始前の素通りを防いだうえで初回失敗と main キュー上のツールバー反映の完了まで待つ。
  func loadAndWaitForInitialFailure(
    _ url: URL, in browser: BrowserLayerView, _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let webView = try XCTUnwrap(browser.webView, file: file, line: line)
    var sawLoading = false
    let observation = webView.observe(\.isLoading, options: [.new]) { _, change in
      if change.newValue == true { sawLoading = true }
    }
    defer { observation.invalidate() }
    browser.load(url)
    if webView.isLoading { sawLoading = true }
    pumpMain(
      until: { sawLoading && !webView.isLoading && !browser.isProvisionalNavigation },
      timeout: 5, label, file: file, line: line)
    nextTurn(file: file, line: line)
  }

  private static let crossOriginFrameHTML = """
    <!doctype html>
    <a id='cross' href='/cross-hijack' target='_blank'>x</a>
    <script>
    window.addEventListener('message', () => {
      document.getElementById('cross').click();
      parent.postMessage('cross-clicked', '*');
    });
    </script>
    """

  private static let triggerBlockedNavigationsJS = """
    document.getElementById('blank').click();
    document.getElementById('data').click();
    document.getElementById('custom').click();
    document.getElementById('crossFrame').contentWindow.postMessage('go', '*');
    document.getElementById('sandFrame').contentWindow.postMessage('go', '*');
    """

  private static func policyTestRoutes(crossURL: String) -> [String: String] {
    [
      "/main": """
      <!doctype html>
      <script>window.open('/auto-popup', '_blank');</script>
      <a id='blank' href='about:blank' target='_blank'>b</a>
      <a id='data' href='data:text/html,<h1>evil</h1>' target='_blank'>d</a>
      <a id='custom' href='orbe-blocked://launch' target='_blank'>c</a>
      <iframe id='dataFrame' src='data:text/html,<script>parent.postMessage("data-loaded","*")</script>'></iframe>
      <iframe id='sameFrame' src='/same-child'></iframe>
      <iframe id='crossFrame' src='\(crossURL)'></iframe>
      <iframe id='sandFrame' sandbox='allow-scripts allow-popups' srcdoc="
        <a id='s' href='/sand-hijack' target='_blank'>s</a>
        <script>
        window.addEventListener('message', () => {
          document.getElementById('s').click();
          parent.postMessage('sand-clicked', '*');
        });
        </script>"></iframe>
      <script>
      window.__acks = [];
      window.__dataLoaded = false;
      window.__waiters = [];
      window.__notify = () => {
        window.__waiters = window.__waiters.filter(fn => !fn());
      };
      window.__waitFor = pred => new Promise(resolve => {
        const check = () => { if (pred()) { resolve(true); return true; } return false; };
        if (!check()) { window.__waiters.push(check); }
      });
      window.addEventListener('message', e => {
        if (e.data === 'data-loaded') { window.__dataLoaded = true; }
        else { window.__acks.push(e.data); }
        window.__notify();
      });
      </script>
      """,
      "/same-child": "<!doctype html><a id='go' href='/same-target' target='_blank'>go</a>",
      "/same-target": "<!doctype html><p>allowed</p>",
      "/auto-popup": "<!doctype html><p>should not open</p>",
      "/sand-hijack": "<!doctype html><p>should not open</p>",
    ]
  }
}

/// 本番 `BrowserLayerView` の `WKNavigationDelegate` 判定を丸ごと転送しつつ、
/// テストから `.cancel` 返却値と暫定開始・失敗イベントの到達を観測する薄いラッパー。
@MainActor
final class BrowserNavigationPolicySpy: NSObject, WKNavigationDelegate {
  weak var target: BrowserLayerView?
  var decisions: [(url: URL?, policy: WKNavigationActionPolicy)] = []
  var provisionalStartCount = 0
  var commitCount = 0
  var failCount = 0
  var failProvisionalCount = 0
  var onBeforeDecidePolicy: ((WKNavigationAction) -> Void)?
  var onBeforeDidCommit: ((WKNavigation) -> Void)?
  var onDidFail: (() -> Void)?

  init(target: BrowserLayerView) {
    self.target = target
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    onBeforeDecidePolicy?(navigationAction)
    let url = navigationAction.request.url
    guard let target else {
      decisionHandler(.cancel)
      return
    }
    target.webView(webView, decidePolicyFor: navigationAction) { policy in
      self.decisions.append((url: url, policy: policy))
      decisionHandler(policy)
    }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    provisionalStartCount += 1
    target?.webView(webView, didStartProvisionalNavigation: navigation)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    if let navigation {
      onBeforeDidCommit?(navigation)
    }
    commitCount += 1
    target?.webView(webView, didCommit: navigation)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    target?.webView(webView, didFinish: navigation)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failCount += 1
    target?.webView(webView, didFail: navigation, withError: error)
    onDidFail?()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    failProvisionalCount += 1
    target?.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    target?.webViewWebContentProcessDidTerminate(webView)
  }
}
