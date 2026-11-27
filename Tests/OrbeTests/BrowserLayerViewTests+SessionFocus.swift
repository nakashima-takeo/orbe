import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 未 materialize タブへの切替と空画面からの初回遷移における `WKWebView` への焦点昇格を守る。
extension BrowserLayerViewTests {
  /// 未 materialize の URL 付きタブへ切り替えた直後、および空画面焦点のまま初回遷移した直後の
  /// いずれも `firstResponder` が `BrowserLayerView` に取り残されず `WKWebView` へ昇格する。
  func testFocusPromotesToWebViewOnLazyMaterializeSwitchAndInitialLoad() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    let server = try LocalLoopbackHTTPServer(routes: [
      "/lazy": "<!doctype html><title>Lazy</title><p>lazy</p>",
      "/direct": "<!doctype html><title>Direct</title><p>direct</p>",
    ])
    defer { server.stop() }

    browser.setMode(.sheet, animated: false)
    browser.focusBrowser()
    XCTAssertTrue(window.firstResponder === browser, "前提: 空画面では BrowserLayerView が焦点を持つ")

    // 1. URL 付き未 materialize タブを作成して選択すると、同期で WKWebView へ焦点が昇格する。
    let lazyTab = try XCTUnwrap(
      session.openTab(url: server.url(for: "/lazy"), activate: false))
    XCTAssertNil(session.runtimes[lazyTab.id], "前提: 非アクティブタブは未 materialize")
    XCTAssertTrue(session.selectTab(lazyTab.id))
    let lazyWebView = try XCTUnwrap(browser.webView)
    XCTAssertTrue(browser.hasNavigated)
    XCTAssertTrue(window.firstResponder === lazyWebView, "未 materialize タブへの切替で WKWebView へ昇格する")

    // 2. 空タブへ戻して BrowserLayerView に焦点がある状態から load しても WKWebView へ昇格する。
    let emptyTab = try XCTUnwrap(session.openTab(url: nil, activate: true))
    XCTAssertEqual(session.store.activeTab?.id, emptyTab.id)
    XCTAssertTrue(window.firstResponder === browser, "前提: 空タブでは BrowserLayerView に焦点")
    browser.load(server.url(for: "/direct"))
    let directWebView = try XCTUnwrap(browser.webView)
    XCTAssertTrue(window.firstResponder === directWebView, "空画面からの初回 load で WKWebView へ昇格する")
  }
}
