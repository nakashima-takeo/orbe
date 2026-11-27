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

  /// アクティブ `WKWebView` 焦点中からの `closeTab`・`clearTodayTabs`・`sweepExpiredTodayTabs`・
  /// `setSpaceProfile`・`deleteProfile`・`removeLocalSpace` で 2 段階解放が機能し、
  /// ブラウザ焦点が一度も `NSWindow` へ落ちず、空ランタイム置換でも URL 編集・新タブ入力をリセットする。
  func testTwoStageReleasePreservesBrowserFocusAcrossCloseClearSweepProfileAndLocalRemoval() throws
  {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    var focusDropResponders: [String] = []
    window.onFirstResponderChange = { responder in
      let focused = window.isKeyWindow && browser.focusIsInside
      browser.setFocused(focused)
      if !focused { focusDropResponders.append(String(describing: responder)) }
    }

    let server = try LocalLoopbackHTTPServer(routes: [
      "/a": "<!doctype html><title>A</title><p>a</p>",
      "/b": "<!doctype html><title>B</title><p>b</p>",
    ])
    defer { server.stop() }
    let urlA = server.url(for: "/a")
    let urlB = server.url(for: "/b")

    browser.setMode(.full, animated: false)
    let free = try XCTUnwrap(session.store.freeSpaces.first)
    XCTAssertTrue(session.selectSpace(.free(free.id)))
    let tab1 = try XCTUnwrap(
      session.openTab(in: free.id, section: .today, url: urlA, activate: true))
    let tab2 = try XCTUnwrap(
      session.openTab(in: free.id, section: .today, url: urlB, activate: false))
    browser.focusBrowser()
    XCTAssertTrue(window.firstResponder === browser.webView, "前提: tab1 の WKWebView に焦点")
    focusDropResponders.removeAll()

    // 1. closeTab: 残タブありは次タブ WKWebView へ、0 枚は browser へ維持し一度も NSWindow へ落ちない。
    XCTAssertTrue(session.closeTab(tab1.id))
    XCTAssertEqual(session.store.activeTab?.id, tab2.id)
    XCTAssertTrue(window.firstResponder === browser.webView, "残タブありの closeTab で次 WKWebView を維持")
    XCTAssertEqual(focusDropResponders, [], "2 段階解放により closeTab 途中で焦点が NSWindow へ落ちない")

    // 2. clearTodayTabs: 全 TODAY 消去で browser へ焦点維持。
    _ = session.clearTodayTabs(in: free.id)
    XCTAssertNil(browser.webView)
    XCTAssertTrue(window.firstResponder === browser, "clearTodayTabs 後もブラウザ焦点が維持される")
    XCTAssertEqual(focusDropResponders, [])

    // 3. setSpaceProfile / deleteProfile（非遷移タブ＋URL 編集中含む）および removeLocalSpace でも維持。
    try assertProfileSwapSweepAndLocalRemovalPreserveFocus(
      hosted: hosted, freeId: free.id, urlA: urlA,
      resetDrops: { focusDropResponders.removeAll() },
      drops: { focusDropResponders })
  }

  private func assertProfileSwapSweepAndLocalRemovalPreserveFocus(
    hosted: Hosted, freeId: UUID, urlA: URL,
    resetDrops: () -> Void, drops: () -> [String]
  ) throws {
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session

    // setSpaceProfile: URL 付き WKWebView 焦点中 → 新プロファイルの WKWebView へ焦点維持。
    _ = try XCTUnwrap(session.openTab(in: freeId, section: .today, url: urlA, activate: true))
    browser.focusBrowser()
    resetDrops()
    let otherProfile = try XCTUnwrap(
      session.store.profiles.first { $0.id != session.store.activeSpace?.profileId })
    XCTAssertTrue(session.setSpaceProfile(freeId, profileId: otherProfile.id))
    XCTAssertTrue(window.firstResponder === browser.webView, "setSpaceProfile 後も新 WKWebView に焦点維持")
    XCTAssertEqual(drops(), [])

    // deleteProfile: 空タブ（url == nil）＋ローカル HTML 実行中＋URL 編集中でも mountRuntime(nil) が素通りしない。
    let doomed = try XCTUnwrap(
      session.createProfile(name: "tmp", color: .amber, mcpAllowed: false))
    let tmpSpace = try XCTUnwrap(
      session.createFreeSpace(name: "Tmp", icon: .globe, profileId: doomed.id))
    XCTAssertTrue(session.selectSpace(.free(tmpSpace.id)))
    browser.loadHTMLString("<p>tmp</p>", baseURL: nil)
    browser.newTabModel.inputText = "stale-draft"
    _ = try beginAndFocusURLField(in: hosted)
    resetDrops()
    XCTAssertTrue(session.deleteProfile(doomed.id, reassigningTo: otherProfile.id))
    XCTAssertFalse(browser.isEditingURL, "deleteProfile で mountRuntime(nil) が URL 編集を終了する")
    XCTAssertEqual(browser.newTabModel.inputText, "", "deleteProfile で新タブ下書きもリセットされる")
    XCTAssertTrue(window.firstResponder === browser, "deleteProfile 後もブラウザ焦点が維持される")
    XCTAssertEqual(drops(), [], "deleteProfile 途中で焦点が NSWindow へ落ちない")

    // sweepExpiredTodayTabs（非保護期限切れ）と removeLocalSpace でも焦点が落ちない。
    let wsId = try XCTUnwrap(session.store.currentWorkspaceId)
    XCTAssertTrue(session.selectSpace(.local))
    let localSpace = try XCTUnwrap(session.store.localSpace(for: wsId))
    _ = try XCTUnwrap(
      session.openTab(in: localSpace.id, section: .today, url: urlA, activate: true))
    browser.focusBrowser()
    XCTAssertTrue(window.firstResponder === browser.webView)
    resetDrops()
    session.visibleTabId = nil
    let swept = session.sweepExpiredTodayTabs(
      now: Date().addingTimeInterval(BrowserStore.todayTabTTL + 60))
    XCTAssertFalse(swept.isEmpty)
    XCTAssertTrue(window.firstResponder === browser, "sweepExpiredTodayTabs でもブラウザ焦点を維持")
    XCTAssertEqual(drops(), [])

    _ = try XCTUnwrap(
      session.openTab(in: localSpace.id, section: .today, url: urlA, activate: true))
    browser.focusBrowser()
    resetDrops()
    session.removeLocalSpace(for: wsId)
    XCTAssertTrue(window.firstResponder === browser, "removeLocalSpace でもブラウザ焦点を維持")
    XCTAssertEqual(drops(), [])
  }

  /// 未 materialize タブ切替で `onActiveDisplayChange` が 1 回のみ発火し、
  /// KVO 状態更新（`syncActiveRuntimeState`）がポップオーバー・狭幅オーバーレイ・URL 編集の焦点を奪わない。
  func testLazySwitchNotifiesDisplayOnceAndKVOStateSyncDoesNotStealFocus() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    let server = try LocalLoopbackHTTPServer(routes: [
      "/lazy": "<!doctype html><title>Lazy</title><p>ok</p>"
    ])
    defer { server.stop() }

    browser.setMode(.sheet, animated: false)
    let originalHandler = session.onActiveDisplayChange
    var displayChangeCount = 0
    session.onActiveDisplayChange = { runtime in
      displayChangeCount += 1
      originalHandler?(runtime)
    }

    let tab = try XCTUnwrap(session.openTab(url: server.url(for: "/lazy"), activate: false))
    displayChangeCount = 0
    XCTAssertTrue(session.selectTab(tab.id))
    XCTAssertEqual(displayChangeCount, 1, "未 materialize URL タブ切替で onActiveDisplayChange は 1 回のみ発火")
    let runtime = try XCTUnwrap(browser.mountedRuntime)

    // ポップオーバー表示中に KVO 状態更新が来ても焦点が背後 WKWebView へ奪われない。
    browser.openPopover(.profile)
    XCTAssertTrue(window.firstResponder === browser)
    runtime.isLoading = true
    runtime.estimatedProgress = 0.5
    session.onActiveRuntimeStateChange?(runtime)
    XCTAssertTrue(browser.toolbar.isLoading, "ツールバー投影は更新される")
    XCTAssertEqual(browser.toolbar.estimatedProgress, 0.5, accuracy: 0.001)
    XCTAssertTrue(window.firstResponder === browser, "KVO 状態更新でポップオーバーから焦点を奪わない")
    browser.closePopover()

    // URL 編集中に KVO 状態更新が来ても field editor 焦点を奪わない。
    let editor = try beginAndFocusURLField(in: hosted)
    runtime.isLoading = false
    runtime.estimatedProgress = 1.0
    session.onActiveRuntimeStateChange?(runtime)
    XCTAssertFalse(browser.toolbar.isLoading)
    XCTAssertTrue(window.firstResponder === editor, "KVO 状態更新で URL 編集中の焦点を奪わない")
  }

  /// サイドバー開状態（全面横並び・狭幅オーバーレイ）からのアニメーション付き閉鎖フェード中は
  /// `effectiveSidebarOpen`・本文位置・暗幕・影が凍結され、フェード完了後に解除される。
  func testClosingFadeFreezesSidebarLayoutAndOverlayUntilFadeCompletes() {
    let hosted = hostBrowser(reduceMotion: false)
    let browser = hosted.browser
    let sidebarW = Theme.Layout.browserSidebarWidth

    // 1. 全面（既定サイドバー開）からの閉鎖フェード中: サイドバー維持・contentView 横ジャンプなし。
    browser.setMode(.full, animated: false)
    hosted.stage.layoutSubtreeIfNeeded()
    XCTAssertTrue(browser.effectiveSidebarOpen)
    XCTAssertEqual(browser.contentView.frame.minX, sidebarW, accuracy: 0.5)

    browser.setMode(.closed, animated: true)
    XCTAssertTrue(browser.isFading)
    XCTAssertTrue(browser.effectiveSidebarOpen, "閉鎖フェード中はサイドバー開状態を凍結する")
    XCTAssertFalse(browser.sidebarContainer.isHidden, "閉鎖フェード開始 0ms でサイドバーが消えない")
    XCTAssertEqual(
      browser.contentView.frame.minX, sidebarW, accuracy: 0.5,
      "閉鎖フェード中に本文領域が左へ横ジャンプしない")
    pumpMain(until: { !browser.isFading }, timeout: 2, "全面閉鎖フェード完了")
    XCTAssertFalse(browser.effectiveSidebarOpen)
    XCTAssertTrue(browser.sheetView.isHidden)

    // 2. 狭幅右シート（オーバーレイ開）からの閉鎖フェード中も暗幕と影を凍結する。
    browser.setSheetRatio(0.40)  // 400pt < 520pt
    browser.setMode(.sheet, animated: false)
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOverlay)

    browser.setMode(.closed, animated: true)
    XCTAssertTrue(browser.isFading)
    XCTAssertTrue(browser.effectiveSidebarOverlay, "狭幅閉鎖フェード中はオーバーレイ状態を凍結する")
    XCTAssertFalse(browser.sidebarScrim.isHidden, "狭幅閉鎖フェード中に暗幕が瞬間消失しない")
    XCTAssertGreaterThan(browser.sidebarContainer.layer?.shadowOpacity ?? 0, 0)
    pumpMain(until: { !browser.isFading }, timeout: 2, "狭幅閉鎖フェード完了")
    XCTAssertFalse(browser.effectiveSidebarOverlay)
    XCTAssertTrue(browser.sheetView.isHidden)
  }
}
