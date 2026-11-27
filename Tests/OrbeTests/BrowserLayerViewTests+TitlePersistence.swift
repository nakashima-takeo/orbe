import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 遅延 materialize の初回 `didCommit` における永続済みタイトル保持・別 URL 遷移時のリセット・
/// 同一文書遷移時のタイトル維持を守る。
extension BrowserLayerViewTests {
  /// 遅延 materialize の初回 `didCommit` で DB 永続済みの `tab.title` が空文字で上書きされず、
  /// 別 URL への遷移時は前ページの旧タイトルを残さず空へリセットされ、同一文書遷移では現在タイトルを保つ。
  func testLazyMaterializePreservesPersistedTitleOnDidCommitAndResetsOnNewURL() throws {
    let server = try LocalLoopbackHTTPServer(routes: [
      "/saved": "<!doctype html><p>no title tag</p>",
      "/other": "<!doctype html><p>other without title</p>",
      "/titled": "<!doctype html><title>Titled Page</title><p>body</p>",
    ])
    defer { server.stop() }
    let savedURL = server.url(for: "/saved")
    let otherURL = server.url(for: "/other")
    let titledURL = server.url(for: "/titled")

    // 1. BrowserStore 単体: 同一 URL + nil は既存タイトル保持、別 URL + nil は空リセット、非空は更新。
    let store = BrowserStore.inMemory()
    let space = try XCTUnwrap(store.freeSpaces.first)
    let unitTab = try XCTUnwrap(
      store.openTab(in: space.id, url: savedURL, title: "Persisted").value)
    XCTAssertEqual(
      store.updateTabNavigation(unitTab.id, url: savedURL, title: nil).value?.title, "Persisted")
    XCTAssertEqual(
      store.updateTabNavigation(unitTab.id, url: otherURL, title: nil).value?.title, "")
    XCTAssertEqual(
      store.updateTabNavigation(unitTab.id, url: otherURL, title: "Explicit").value?.title,
      "Explicit")

    // 2. 遅延 materialize 初回ロード: <title> 不在ページでも永続済みタイトルを失わない。
    let hosted = hostBrowser()
    let browser = hosted.browser
    let session = browser.session
    let tab = try XCTUnwrap(
      session.openTab(url: savedURL, title: "Saved Title", activate: true))
    XCTAssertNil(session.runtimes[tab.id], "前提: 閉鎖中は未 materialize")

    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    browser.setMode(.sheet, animated: false)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "遅延 materialize 初回ロード完了")
    XCTAssertEqual(
      session.store.tab(id: tab.id)?.title, "Saved Title",
      "遅延 materialize の初回 didCommit で永続済みタイトルを空文字で上書きしない")

    // 3. 別 URL（<title> なし）へ遷移すると前ページのタイトルを残さず空へリセットする。
    let beforeOther = finishCount
    browser.load(otherURL)
    pumpMain(until: { finishCount > beforeOther }, timeout: 5, "別 URL 読み込み完了")
    XCTAssertEqual(
      session.store.tab(id: tab.id)?.title, "",
      "別 URL 遷移で前ページの古いタイトルを残さない")

    // 4. タイトル付きページでの pushState 同一文書遷移は現在タイトルを消さない。
    let beforeTitled = finishCount
    browser.load(titledURL)
    pumpMain(
      until: {
        finishCount > beforeTitled && session.store.tab(id: tab.id)?.title == "Titled Page"
      }, timeout: 5, "タイトル付きページ読み込み完了")
    let webView = try XCTUnwrap(browser.webView)
    webView.evaluateJavaScript("history.pushState({}, '', '/titled/sub')")
    pumpMain(
      until: { session.store.tab(id: tab.id)?.url?.path == "/titled/sub" }, timeout: 5,
      "pushState がストアへ反映される")
    XCTAssertEqual(
      session.store.tab(id: tab.id)?.title, "Titled Page",
      "同一文書遷移で既存ページタイトルが消えない")
  }
}
