import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 非フォーカス右シートからのサイドバー操作焦点揃え、広幅横並び閉鎖時の新タブ入力保護、
/// およびサイドバーヘッダのプロファイルピル非圧迫・Favorites 多数×低高ウィンドウでのスクロール到達性を守る。
///
/// 壊れると何が起きるか。下層端末に焦点がある状態でサイドバーを開いても `Esc` で閉じられない、
/// ホバー `×` や `Clear · 12h` の後も下層へ打鍵が抜ける、広幅で新タブ入力欄編集中に `⌘S` で
/// 入力焦点が奪われる、長いスペース名でプロファイルピルが押し潰されて押せない、あるいは
/// Favorites 多数×低高ウィンドウで `PINNED` / `TODAY` が 0pt に潰れて到達不能になる。
extension BrowserLayerViewTests {
  /// 非フォーカス右シート（下層に焦点）からのサイドバー開・スペース切替・ホバー `×`・`Clear · 12h`・
  /// コンテキストメニュー実行のすべてで焦点がブラウザへ揃い、広幅横並び閉鎖では新タブ入力欄編集を奪わない。
  func testUnfocusedSheetSidebarActionsFocusBrowserAndWideClosePreservesNewTabEditing() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    hosted.underlay.addSubview(outsider)
    let free = try XCTUnwrap(session.store.freeSpaces.first)
    XCTAssertTrue(session.selectSpace(.free(free.id)))
    let tab1 = try XCTUnwrap(
      session.openTab(in: free.id, section: .today, url: nil, activate: true))
    let tab2 = try XCTUnwrap(
      session.openTab(in: free.id, section: .today, url: nil, activate: false))
    let tab3 = try XCTUnwrap(
      session.openTab(in: free.id, section: .today, url: nil, activate: false))

    browser.setSheetRatio(0.40)  // 400pt 狭幅オーバーレイ
    browser.setMode(.sheet, animated: false)
    XCTAssertTrue(window.makeFirstResponder(outsider), "前提: 下層に焦点")
    XCTAssertFalse(browser.focusIsInside)

    // 1. 非フォーカスから toggleSidebar() でオーバーレイ開 → 焦点がブラウザへ揃い Esc で即閉じられる。
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOverlay)
    XCTAssertTrue(window.firstResponder === browser, "サイドバー開で焦点がブラウザへ移る")
    let esc = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false, keyCode: 53)!
    XCTAssertTrue(browser.performKeyEquivalent(with: esc), "直後の Esc でオーバーレイを閉じられる")
    XCTAssertFalse(browser.isSidebarOpen)

    // 2. スペース切替・ホバー ×・コンテキストメニュー・Clear · 12h も非フォーカスからブラウザへ焦点を揃える。
    assertSidebarActionsReclaimFocusFromUnderlay(
      browser: browser, window: window, outsider: outsider,
      freeId: free.id, tabIds: [tab1.id, tab2.id, tab3.id])

    // 3. 広幅横並びで新タブ入力欄編集中に setSidebarOpen(false) しても入力焦点を奪わない（対の確認付き）。
    browser.setSheetRatio(0.60)  // 600pt 横並び
    hosted.stage.layoutSubtreeIfNeeded()
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOpen && !browser.isSidebarOverlay)
    browser.openNewTab()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      }, "前提: 新タブ入力欄編集中")
    let newTabEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertTrue(browser.isEditingNewTabURL)

    browser.setSidebarOpen(false)
    XCTAssertFalse(browser.isSidebarOpen)
    XCTAssertTrue(window.firstResponder === newTabEditor, "広幅閉鎖で新タブ入力欄の焦点を奪わない")

    // 対の確認: 非編集中なら下層焦点からの閉鎖で focusBrowser() が走る。
    browser.setSidebarOpen(true)
    XCTAssertTrue(window.makeFirstResponder(outsider))
    XCTAssertFalse(browser.isEditingAnyURL)
    browser.setSidebarOpen(false)
    XCTAssertTrue(window.firstResponder === browser, "非編集中は setSidebarOpen(false) でブラウザへ焦点")
  }

  private func assertSidebarActionsReclaimFocusFromUnderlay(
    browser: BrowserLayerView, window: NSWindow, outsider: NSTextField,
    freeId: UUID, tabIds: [UUID]
  ) {
    XCTAssertTrue(window.makeFirstResponder(outsider))
    browser.sidebarActions.onSelectSpace(.local)
    XCTAssertTrue(window.firstResponder === browser, "スペース切替でブラウザへ焦点が揃う")

    XCTAssertTrue(window.makeFirstResponder(outsider))
    browser.sidebarActions.onSelectSpace(.free(freeId))
    XCTAssertTrue(window.firstResponder === browser)

    XCTAssertTrue(window.makeFirstResponder(outsider))
    browser.sidebarActions.onCloseTab(tabIds[0])
    XCTAssertTrue(window.firstResponder === browser, "ホバー × 閉鎖でブラウザへ焦点が揃う")

    XCTAssertTrue(window.makeFirstResponder(outsider))
    browser.sidebarActions.onTabMenuAction(.pin, tabIds[1])
    XCTAssertTrue(window.firstResponder === browser, "右クリックメニュー実行でブラウザへ焦点が揃う")

    XCTAssertTrue(window.makeFirstResponder(outsider))
    browser.sidebarActions.onClearToday(freeId)
    XCTAssertTrue(window.firstResponder === browser, "Clear · 12h でブラウザへ焦点が揃う")
    XCTAssertNil(browser.session.store.tab(id: tabIds[2]))
  }

  /// 長いスペース名／ローカル workspace 名でも 256pt ヘッダ右端のプロファイルピルが押し潰されず押下でき、
  /// Favorites 多数＋低高ウィンドウでも単一スクロール領域で `PINNED` / `TODAY` / `+ 新しいタブ` へ到達できる。
  func testSidebarHeaderKeepsProfilePillWidthAndTabListScrollsWithManyFavorites() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session

    // 1. BrowserMaxWidthLayout は自然幅 <= 上限なら膨張せず、上限超えのみクランプする。
    let narrowHost = NSHostingView(
      rootView: Color.clear.frame(width: 48, height: 20).browserMaxWidth(104))
    XCTAssertEqual(narrowHost.fittingSize.width, 48, accuracy: 0.5, "自然幅が上限以下なら膨張しない")
    let wideHost = NSHostingView(
      rootView: Text(String(repeating: "W", count: 40))
        .lineLimit(1)
        .browserMaxWidth(104))
    XCTAssertLessThanOrEqual(wideHost.fittingSize.width, 104.5, "上限超えは maxWidth にクランプ")
    XCTAssertGreaterThan(wideHost.fittingSize.width, 80, "0 に潰れず maxWidth 近傍を使う")

    // 2. 長い自由スペース名・長いローカル workspace 名でもプロファイルピル幅が潰れず実クリックできる。
    browser.setMode(.full, animated: false)
    browser.focusBrowser()
    placeOffscreen(window)

    let longFree = try XCTUnwrap(session.store.freeSpaces.first)
    XCTAssertNotNil(
      session.updateFreeSpace(
        longFree.id, name: "Documentation & Specifications Long Archive", icon: .globe))
    XCTAssertTrue(session.selectSpace(.free(longFree.id)))
    flush(window)
    assertProfilePillClickableWidth(in: hosted, label: "長い自由スペース名")

    let wsId = try XCTUnwrap(session.store.currentWorkspaceId)
    session.syncCurrentWorkspace(wsId, name: "frontend-dashboard-monorepo-workspace")
    XCTAssertTrue(session.selectSpace(.local))
    flush(window)
    assertProfilePillClickableWidth(in: hosted, label: "長いローカル workspace 名")

    // 3. Favorites 24 件＋PINNED＋TODAY＋低高ウィンドウ（320pt）で tabList が潰れず末尾へスクロール到達できる。
    try assertManyFavoritesStillReachPinnedTodayAndNewTab(in: hosted, freeId: longFree.id)
  }

  private func assertProfilePillClickableWidth(in hosted: Hosted, label: String) {
    let (window, browser) = (hosted.window, hosted.browser)
    let sidebarW = Theme.Layout.browserSidebarWidth
    let headerMidY = Theme.Layout.browserSidebarHeader / 2
    // 右端 trailing 10pt の内側: ピル左寄り（右端から 52pt）でもヒットしポップオーバーが開く。
    let pillLeftLocal = NSPoint(
      x: sidebarW - Theme.Layout.browserSidebarHeaderTrailing - 44, y: headerMidY)
    let windowPoint = browser.sidebarContainer.convert(pillLeftLocal, to: nil)
    browser.closePopover()
    flush(window)
    clickWindowPoint(windowPoint, in: window)
    XCTAssertEqual(
      browser.popoverState, .profile,
      "\(label): プロファイルピルが押し潰されず右端から 44pt 内側のクリックで開く")
    browser.closePopover()
  }

  private func assertManyFavoritesStillReachPinnedTodayAndNewTab(
    in hosted: Hosted, freeId: UUID
  ) throws {
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    XCTAssertTrue(session.selectSpace(.free(freeId)))
    for i in 0..<24 {
      _ = try XCTUnwrap(
        session.openTab(
          in: freeId, section: .favorite, url: nil, title: "Fav\(i)", activate: false))
    }
    _ = try XCTUnwrap(
      session.openTab(in: freeId, section: .pinned, url: nil, title: "PinnedDoc", activate: false))
    _ = try XCTUnwrap(
      session.openTab(in: freeId, section: .today, url: nil, title: "TodayDoc", activate: false))

    let lowSize = NSSize(width: 1000, height: 320)
    window.setFrame(NSRect(origin: window.frame.origin, size: lowSize), display: false)
    hosted.stage.frame = NSRect(origin: .zero, size: lowSize)
    hosted.stage.layoutSubtreeIfNeeded()
    flush(window)

    let verticalScroll = try XCTUnwrap(
      collectScrollViews(in: browser.sidebarHost).max(by: { $0.frame.height < $1.frame.height }),
      "tabList の垂直 ScrollView が見つかる")
    XCTAssertGreaterThan(
      verticalScroll.frame.height, 150,
      "Favorites 24 件・低高 320pt でも tabList 表示領域が 0pt に潰れずヘッダ/切替バー以外を専有する")
    let docView = try XCTUnwrap(verticalScroll.documentView)
    XCTAssertGreaterThan(
      docView.frame.height, verticalScroll.contentView.bounds.height + 150,
      "Favorites 6 行＋PINNED＋TODAY＋新しいタブの全高が単一スクロール内に収まる")

    // 最下部までスクロールし、末尾の `+ 新しいタブ` 行を実クリックして到達可能であることを検証する。
    let maxScrollY = max(0, docView.frame.height - verticalScroll.contentView.bounds.height)
    verticalScroll.contentView.scroll(to: NSPoint(x: 0, y: maxScrollY))
    verticalScroll.reflectScrolledClipView(verticalScroll.contentView)
    flush(window)

    let countBefore = session.store.tabs(in: freeId).count
    let newTabLocal = NSPoint(
      x: docView.bounds.midX,
      y: docView.isFlipped ? docView.bounds.maxY - 22 : docView.bounds.minY + 22)
    clickWindowPoint(docView.convert(newTabLocal, to: nil), in: window)
    XCTAssertEqual(
      session.store.tabs(in: freeId).count, countBefore + 1,
      "Favorites 24 件の末尾へスクロールして + 新しいタブ へ到達・クリックできる")
  }

  private func collectScrollViews(in view: NSView) -> [NSScrollView] {
    var result: [NSScrollView] = []
    if let sv = view as? NSScrollView { result.append(sv) }
    for sub in view.subviews { result.append(contentsOf: collectScrollViews(in: sub)) }
    return result
  }
}
