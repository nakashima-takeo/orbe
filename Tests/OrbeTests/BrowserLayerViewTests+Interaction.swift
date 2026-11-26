import AppKit
import Darwin
import OrbeTestSupport
import WebKit
import XCTest

@testable import Orbe

/// `BrowserLayerView` の左端ドラッグハンドル・キー分類・URL インライン編集の焦点契約・
/// 最小 `WKWebView` 統合（ローカル HTML・JS ダイアログ即応答・`target="_blank"` 同一面遷移・
/// WebContent 異常終了復帰）を守る。
extension BrowserLayerViewTests {
  private func mouse(_ type: NSEvent.EventType, x: CGFloat, in hosted: Hosted, clickCount: Int = 1)
    -> NSEvent
  {
    let point = hosted.browser.convert(NSPoint(x: x, y: 200), to: nil)
    return NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0,
      clickCount: clickCount, pressure: 1)!
  }

  // MARK: - 左端ドラッグとダブルクリック

  /// 左端ドラッグで幅更新・異常離脱キャンセル（カーソル復元）・全面吸着・右投げ閉じ・ダブルクリック全面切替が働く。
  func testResizeHandleSupportsDragSnapDoubleClickAndResignKeyCancellation() {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let handle = browser.resizeHandle
    var requestedModes: [BrowserMode] = []
    browser.onRequestModeChange = { mode, _ in
      requestedModes.append(mode)
      browser.setMode(mode, animated: false)
    }
    browser.setMode(.sheet, animated: false)

    // 通常域ドラッグ: 1000pt の窓で x=400 → 幅 600pt (60%)。
    NSCursor.arrow.set()
    handle.mouseDown(with: mouse(.leftMouseDown, x: browser.sheetView.frame.minX + 4, in: hosted))
    XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight, "ドラッグ中は左右リサイズカーソルを push")
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 400, in: hosted))
    handle.mouseUp(with: mouse(.leftMouseUp, x: 400, in: hosted))
    XCTAssertEqual(browser.sheetRatio, 0.60, accuracy: 0.001)
    XCTAssertTrue(NSCursor.current === NSCursor.arrow, "ドラッグ終了でカーソルが戻る")

    // 全面吸着域まで引いた途中で windowDidResignKey が来たら安全中断し、60%・右シートのまま戻る。
    handle.mouseDown(with: mouse(.leftMouseDown, x: browser.sheetView.frame.minX + 4, in: hosted))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 100, in: hosted))
    XCTAssertEqual(browser.snapBadge.kind, .snapFull, "前提: 全面吸着プレビュー中")
    window.isKey = false
    XCTAssertEqual(browser.mode, .sheet, "異常離脱では全面確定しない")
    XCTAssertNil(browser.snapBadge.kind, "スナップバッジが消える")
    XCTAssertEqual(browser.sheetRatio, 0.60, accuracy: 0.001, "開始前の確定比率を保つ")
    XCTAssertTrue(NSCursor.current === NSCursor.arrow, "異常離脱でもカーソルを pop する")

    // 右投げ閉じ → 閉じ要求かつ 60% 保持。
    window.isKey = true
    handle.mouseDown(with: mouse(.leftMouseDown, x: browser.sheetView.frame.minX + 4, in: hosted))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 820, in: hosted))
    handle.mouseUp(with: mouse(.leftMouseUp, x: 820, in: hosted))
    XCTAssertEqual(requestedModes.last, .closed)
    XCTAssertEqual(browser.sheetRatio, 0.60, accuracy: 0.001)

    // 開き直してダブルクリック → 全面切替。
    browser.setMode(.sheet, animated: false)
    handle.mouseDown(
      with: mouse(.leftMouseDown, x: browser.sheetView.frame.minX + 4, in: hosted, clickCount: 2))
    XCTAssertEqual(requestedModes.last, .full)
  }

  // MARK: - キー分類と URL 編集中ガード

  /// ブラウザ焦点中は安全遷移系のみ上位転送し、⌘R は再読込、⌘W・端末/エディター専用・⌘F は無動作消費する。
  /// URL 編集中は ⌘B 以外の遷移・再読込も抑止し、焦点外は素通しする。
  func testPerformKeyEquivalentClassifiesChromeKeysAndGuardsURLEditing() {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    var commands: [WindowCommand] = []
    browser.onWindowCommand = { commands.append($0) }
    browser.setMode(.sheet, animated: false)
    browser.focusBrowser()

    // 背後誤爆防止: ⌘W・端末ズーム・エディター専用・⌘F は消費して上位へ流さない。
    let blocked: [NSEvent] = [
      .key("w"), .key("+"), .key("-"), .key("0"),
      .key("s"), .key("B", [.command, .shift]), .key("p"), .key("f"),
    ]
    for event in blocked {
      XCTAssertTrue(browser.performKeyEquivalent(with: event))
    }
    XCTAssertTrue(commands.isEmpty, "遮断キーは onWindowCommand を呼ばない")

    // ⌘R はタブリネームではなくページ再読込として消費する。
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("r")))
    XCTAssertTrue(commands.isEmpty, "⌘R で renameTab を発火しない")

    // 安全遷移系は上位へ転送する。
    for event in [
      NSEvent.key("e"), .key("F", [.command, .shift]), .key("}", [.command, .shift]),
      .key("{", [.command, .shift]), .key("E", [.command, .shift]),
    ] {
      XCTAssertTrue(browser.performKeyEquivalent(with: event))
    }
    XCTAssertEqual(commands, [.toggleEditorFace, .findInProject, .nextTab, .prevTab, .openEditor])

    // ⌘↑/⌘↓ と未分類（⌘C）は super へ素通しし、onWindowCommand を呼ばない。
    commands.removeAll()
    let up = NSEvent.key(String(UnicodeScalar(NSEvent.SpecialKey.upArrow.rawValue)!))
    _ = browser.performKeyEquivalent(with: up)
    _ = browser.performKeyEquivalent(with: .key("c"))
    XCTAssertTrue(commands.isEmpty)

    // URL 編集中は遷移・再読込・パレットを抑止し、⌘B だけ編集を外因終了して閉じる。
    browser.beginURLEditing()
    for event in [NSEvent.key("e"), .key("r"), .key("t")] {
      XCTAssertTrue(browser.performKeyEquivalent(with: event))
    }
    XCTAssertTrue(commands.isEmpty, "URL 編集中は ⌘E/⌘R/⌘T を発火しない")
    XCTAssertTrue(browser.isEditingURL)

    XCTAssertTrue(browser.performKeyEquivalent(with: .key("b")))
    XCTAssertFalse(browser.isEditingURL, "⌘B は URL 編集を外因終了する")
    XCTAssertEqual(commands, [.toggleBrowser])

    // 焦点がブラウザの外にあるときは素通しする。
    commands.removeAll()
    window.makeFirstResponder(nil)
    XCTAssertFalse(browser.performKeyEquivalent(with: .key("w")))
    XCTAssertFalse(browser.performKeyEquivalent(with: .key("e")))
    XCTAssertTrue(commands.isEmpty)
  }

  // MARK: - URL インライン編集の明示終了と外因終了

  /// URL 編集の無効確定は編集欄に留まり、明示取消（Esc）はブラウザへ焦点を戻す。
  /// 外因終了（blur 等）は他所へ移った焦点を奪い返さない。
  func testURLEditingExplicitVsExternalEndFocusContract() {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    hosted.underlay.addSubview(outsider)
    browser.setMode(.sheet, animated: false)

    browser.beginURLEditing()
    XCTAssertTrue(browser.isEditingURL)
    XCTAssertFalse(browser.commitURLEditing("not a url"), "不正入力は受理せず編集を継続する")
    XCTAssertTrue(browser.isEditingURL)

    window.makeFirstResponder(nil)
    browser.cancelURLEditing()
    XCTAssertFalse(browser.isEditingURL)
    XCTAssertTrue(window.firstResponder === browser.focusTarget, "明示取消はブラウザへ焦点を戻す")

    browser.beginURLEditing()
    XCTAssertTrue(window.makeFirstResponder(outsider))
    let externalResponder = window.firstResponder
    browser.endURLEditingExternally()
    XCTAssertFalse(browser.isEditingURL)
    XCTAssertTrue(window.firstResponder === externalResponder, "外因終了は他所の焦点を奪い返さない")
  }

  // MARK: - 最小 WKWebView 統合（外部通信ゼロ）

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
}

/// 外部通信ゼロで `http://127.0.0.1:<port>` を提供するテスト用ループバック HTTP サーバー。
private final class LocalLoopbackHTTPServer: @unchecked Sendable {
  private let listenFD: Int32
  private let routes: [String: String]
  let port: UInt16

  init(routes: [String: String]) throws {
    self.routes = routes
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 8) == 0 else {
      close(fd)
      throw POSIXError(.EADDRINUSE)
    }

    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &len)
      }
    }
    self.listenFD = fd
    self.port = UInt16(bigEndian: actual.sin_port)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.acceptLoop()
    }
  }

  func url(for path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
  }

  func stop() {
    shutdown(listenFD, SHUT_RDWR)
    close(listenFD)
  }

  private func acceptLoop() {
    while true {
      let client = accept(listenFD, nil, nil)
      if client < 0 { break }
      handleClient(client)
      close(client)
    }
  }

  private func handleClient(_ fd: Int32) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0, let request = String(bytes: buffer.prefix(count), encoding: .utf8) else {
      return
    }
    let path =
      request.split(separator: "\r\n").first?
      .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    let body = routes[path] ?? ""
    let status = routes[path] != nil ? "200 OK" : "404 Not Found"
    let payload = Data(body.utf8)
    let header =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    let response = Data(header.utf8) + payload
    response.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var written = 0
      while written < response.count {
        let n = write(fd, base.advanced(by: written), response.count - written)
        if n <= 0 { break }
        written += n
      }
    }
  }
}
