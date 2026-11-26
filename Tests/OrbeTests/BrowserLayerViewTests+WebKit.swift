import AppKit
import OrbeTestSupport
import WebKit
import XCTest

@testable import Orbe

/// 本物の `WKWebView` とローカルループバック TCP/HTTP サーバー（外部通信ゼロ）で、
/// スキーム制限（`decidePolicyFor`）・ポップアップ遮断と同一オリジン iframe 許可（`createWebViewWith`）・
/// 暫定ナビゲーション中の URL / 鍵アイコン保護・初回失敗後の `⌘R` / 再読込復帰・
/// JS ダイアログ即応答・WebContent 異常終了復帰を守る。
extension BrowserLayerViewTests {
  /// ローカル HTML 遷移後の焦点移行・JS ダイアログの非モーダル即キャンセル応答・
  /// `target="_blank"` 同一面遷移・WebContent 異常終了時の読込状態解除を本物の `WKWebView` で確かめる。
  func testWebKitIntegrationLocalHTMLDialogsPopupAndProcessTermination() throws {
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

    // WebContent プロセス異常終了時は読込中フラグを解除し無限リロードしない。
    browser.toolbar.isLoading = true
    browser.toolbar.estimatedProgress = 0.7
    browser.webViewWebContentProcessDidTerminate(webView)
    XCTAssertFalse(browser.toolbar.isLoading)
    XCTAssertEqual(browser.toolbar.estimatedProgress, 0)
  }

  /// メインフレームの非 HTTP(S) スキーム（`file:`・カスタムスキーム・`data:`）と自動 `window.open`、
  /// および `data:` / `about:blank` / クロスオリジン iframe / sandboxed iframe の `target="_blank"` を遮断し、
  /// 許可されたサブフレーム（`data:`）と同一オリジン iframe からの `target="_blank"` HTTP リンクのみ通す。
  func testNavigationPolicyAndPopupGuardsBlockUnsafeTargetsAndAllowSameOriginSubframe() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.webView)
    XCTAssertFalse(
      webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically,
      "スクリプト自動ポップアップは WebKit 設定で抑止する")

    let crossServer = try LocalLoopbackHTTPServer(routes: ["/cross": Self.crossOriginFrameHTML])
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

    // サブフレームの許可スキーム（data:）は通る（opaque origin のため postMessage で観測する）。
    var dataLoaded = false
    pumpMain(
      until: {
        webView.evaluateJavaScript("window.__dataLoaded === true") { val, _ in
          if let ok = val as? Bool, ok { dataLoaded = true }
        }
        return dataLoaded
      }, timeout: 5, "サブフレームの data: は読み込める")

    // 非 HTTP(S) と危険な target="_blank"（about:blank / data: / カスタム / 異オリジン・sandbox iframe）を遮断する。
    webView.load(URLRequest(url: try caseFile("blocked.html", "<p>file</p>")))
    webView.load(URLRequest(url: URL(string: "orbe-blocked://launch")!))
    webView.evaluateJavaScript(Self.triggerBlockedNavigationsJS)
    var ackCount = 0
    pumpMain(
      until: {
        webView.evaluateJavaScript("window.__acks.length") { val, _ in
          if let n = val as? Int { ackCount = n }
        }
        return ackCount >= 2
      }, timeout: 5, "クロスオリジン・sandboxed 両 iframe がクリックを実行した")
    XCTAssertTrue(
      holds(for: 0.2) { webView.url == mainURL && finishCount == 1 },
      "非 HTTP(S)・自動ポップアップ・クロスオリジン/sandboxed iframe からの遷移はすべて遮断される")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/main")

    // 対の経路: 同一オリジン iframe からの target="_blank" HTTP リンクは同一面で開ける。
    webView.evaluateJavaScript(
      "document.getElementById('sameFrame').contentDocument.getElementById('go').click()")
    pumpMain(until: { finishCount >= 2 }, timeout: 5, "同一オリジン iframe の target=_blank が開く")
    XCTAssertEqual(webView.url?.path, "/same-target")
  }

  /// コミット済みページ上での無応答先への暫定遷移中および失敗後は元の URL と鍵表示を維持し、
  /// 同一オリジンの `history.pushState` は反映する。初回未到達 `https://` 失敗時は鍵アイコンを点灯しない。
  func testProvisionalNavigationProtectsAddressBarAndSecureLock() throws {
    let hosted = hostBrowser()
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.webView)

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

    // 無応答ポートへの暫定遷移中は、webView.url が変わってもツールバーの URL・鍵アイコンを書き換えない。
    let decoy = URL(string: "https://127.0.0.1:\(hanging.port)/login")!
    browser.load(decoy)
    pumpMain(until: { browser.isProvisionalNavigation }, timeout: 5, "暫定ナビゲーション開始")
    nextTurn()
    XCTAssertEqual(browser.toolbar.displayURL?.host, "127.0.0.1:\(server.port)")
    XCTAssertEqual(browser.toolbar.displayURL?.path, "/pushed?k=1")
    XCTAssertEqual(browser.toolbar.displayURL?.isSecure, false, "未確定の https:// で鍵を点灯しない")

    // 暫定遷移が失敗（接続閉鎖）しても元のコミット済み表示を保つ。
    hanging.stop()
    pumpMain(until: { !browser.isProvisionalNavigation }, timeout: 5, "暫定遷移の失敗完了")
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

  /// `webView.isLoading` の `true → false` 遷移を KVO で確実に捕まえてから `browser.load(_:)` を呼び、
  /// 読み込み開始前の素通りを防いだうえで初回失敗と main キュー上のツールバー反映の完了まで待つ。
  private func loadAndWaitForInitialFailure(
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
    <a id='cross' href='http://127.0.0.1:1/blocked' target='_blank'>x</a>
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
      window.addEventListener('message', e => {
        if (e.data === 'data-loaded') { window.__dataLoaded = true; }
        else { window.__acks.push(e.data); }
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
