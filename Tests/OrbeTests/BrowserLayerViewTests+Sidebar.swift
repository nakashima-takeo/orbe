import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// `BrowserLayerView` のサイドバー幾何（横並び `>= 520pt` vs 狭幅オーバーレイ `< 520pt`・`min(256, width)`）、
/// モード別開閉記憶と狭幅閉鎖リセット、オーバーレイ自動閉鎖、およびオーバーレイ出現時の
/// `contentView` 配下からの焦点退避を守る。
///
/// 壊れると何が起きるか。狭幅シートでサイドバーが WebView を潰す、あるいは広幅なのに暗幕が覆う。
/// 右シートを閉じて開き直したときに狭幅オーバーレイが残って視界を塞ぐ。外側クリック・タブ選択・
/// `Esc` でオーバーレイが閉じない、またはオーバーレイの背後にある新タブ入力欄・WebView へ
/// ゴースト入力が漏れる。
extension BrowserLayerViewTests {
  private func resizeStage(in hosted: Hosted, width: CGFloat, height: CGFloat = 600) {
    let size = NSSize(width: width, height: height)
    hosted.window.setFrame(NSRect(origin: .zero, size: size), display: false)
    hosted.stage.frame = NSRect(origin: .zero, size: size)
    hosted.stage.layoutSubtreeIfNeeded()
  }

  /// 横並び（`>= 520pt`）と狭幅オーバーレイ（`< 520pt`）の幾何境界・クランプ、
  /// モード別開閉記憶（初期: 右シート閉／全面開）、および狭幅オーバーレイ開中の閉鎖リセットを守る。
  func testSidebarLayoutThresholdsModeMemoryAndNarrowOverlayCloseReset() {
    let hosted = hostBrowser()
    let browser = hosted.browser
    let sidebarW = Theme.Layout.browserSidebarWidth
    let threshold = Theme.Layout.browserSidebarInlineThreshold

    // 1. 初期状態: 右シートは閉・全面は開。広幅（1000pt）の全面は 256pt 横並び。
    browser.setMode(.sheet, animated: false)
    XCTAssertFalse(browser.isSidebarOpen, "初期状態: 右シートはサイドバー閉")
    XCTAssertTrue(browser.sidebarContainer.isHidden)
    XCTAssertTrue(browser.sidebarScrim.isHidden)
    XCTAssertEqual(browser.contentView.frame.origin.x, 0, accuracy: 0.5)
    XCTAssertEqual(
      browser.contentView.frame.width, browser.belowBar.bounds.width, accuracy: 0.5)

    browser.setMode(.full, animated: false)
    XCTAssertTrue(browser.isSidebarOpen, "初期状態: 全面はサイドバー開")
    XCTAssertFalse(browser.isSidebarOverlay)
    XCTAssertFalse(browser.sidebarContainer.isHidden)
    XCTAssertTrue(browser.sidebarScrim.isHidden)
    XCTAssertEqual(browser.sidebarContainer.frame.width, sidebarW, accuracy: 0.5)
    XCTAssertEqual(browser.contentView.frame.origin.x, sidebarW, accuracy: 0.5)
    XCTAssertEqual(browser.contentView.frame.width, 1000 - sidebarW, accuracy: 0.5)
    XCTAssertEqual(browser.sidebarContainer.layer?.shadowOpacity ?? -1, 0, accuracy: 0.001)

    // 2. 閾値境界: 520pt は横並び、519pt はオーバーレイ（本文全幅＋暗幕＋右落ち影）、200pt は幅クランプ。
    resizeStage(in: hosted, width: threshold)
    XCTAssertFalse(browser.isSidebarOverlay, "520pt ちょうどは横並び")
    XCTAssertTrue(browser.sidebarScrim.isHidden)
    XCTAssertEqual(browser.contentView.frame.origin.x, sidebarW, accuracy: 0.5)
    XCTAssertEqual(browser.contentView.frame.width, threshold - sidebarW, accuracy: 0.5)

    resizeStage(in: hosted, width: threshold - 1)
    XCTAssertTrue(browser.isSidebarOverlay, "519pt は狭幅オーバーレイ")
    XCTAssertFalse(browser.sidebarScrim.isHidden)
    XCTAssertEqual(browser.sidebarContainer.frame.width, sidebarW, accuracy: 0.5)
    XCTAssertEqual(browser.contentView.frame.origin.x, 0, accuracy: 0.5, "オーバーレイ時は本文幅不変")
    XCTAssertEqual(browser.contentView.frame.width, threshold - 1, accuracy: 0.5)
    XCTAssertGreaterThan(browser.sidebarContainer.layer?.shadowOpacity ?? 0, 0)

    resizeStage(in: hosted, width: 200)
    XCTAssertTrue(browser.isSidebarOverlay)
    XCTAssertEqual(
      browser.sidebarContainer.frame.width, 200, accuracy: 0.5, "min(256, width) にクランプ")

    // 3. モード別記憶: 全面を閉じても、広幅右シートを開いた記憶と独立して保持される。
    resizeStage(in: hosted, width: 1000)
    browser.toggleSidebar()
    XCTAssertFalse(browser.isSidebarOpen, "全面サイドバーを閉じる")

    browser.setSheetRatio(0.60)  // 600pt >= 520pt（横並び）
    browser.setMode(.sheet, animated: false)
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOpen)
    XCTAssertFalse(browser.isSidebarOverlay, "前提: 広幅右シートは横並び")

    browser.setMode(.closed, animated: false)
    browser.setMode(.sheet, animated: false)
    XCTAssertTrue(browser.isSidebarOpen, "広幅右シート（横並び）の開記憶は閉鎖後も残る")
    browser.setMode(.full, animated: false)
    XCTAssertFalse(browser.isSidebarOpen, "全面を閉じた記憶も右シートとは独立して残る")

    // 4. 狭幅オーバーレイ開中の閉鎖は previous モード側の開閉フラグのみリセットし他モード記憶を壊さない。
    assertNarrowOverlayCloseResetsOnlyPreviousMode(in: hosted)
  }

  private func assertNarrowOverlayCloseResetsOnlyPreviousMode(in hosted: Hosted) {
    let browser = hosted.browser
    browser.setSheetRatio(0.40)  // 400pt < 520pt（狭幅オーバーレイ）
    browser.setMode(.sheet, animated: false)
    XCTAssertTrue(browser.isSidebarOverlay, "前提: 狭幅右シートでオーバーレイ開")
    browser.setMode(.closed, animated: false)
    browser.setMode(.sheet, animated: false)
    XCTAssertFalse(browser.isSidebarOpen, "狭幅オーバーレイ開中に閉じると次回は閉で始まる")

    // 広幅右シートの開記憶を保持したまま全面狭幅オーバーレイを閉じても、full 側のみリセットされる。
    browser.setSheetRatio(0.60)  // 600pt 横並び
    hosted.stage.layoutSubtreeIfNeeded()
    browser.toggleSidebar()
    XCTAssertTrue(browser.sheetSidebarOpen, "前提: 広幅右シートで開記憶")
    browser.setMode(.full, animated: false)
    browser.toggleSidebar()  // fullSidebarOpen = true
    resizeStage(in: hosted, width: 400)
    XCTAssertTrue(browser.isSidebarOverlay, "前提: 全面 400pt は狭幅オーバーレイ")
    browser.setMode(.closed, animated: false)
    XCTAssertFalse(browser.fullSidebarOpen, "previous(.full) 側の狭幅オーバーレイのみリセットする")
    XCTAssertTrue(browser.sheetSidebarOpen, "他モード(.sheet) の開記憶は壊さない")
    resizeStage(in: hosted, width: 1000)
    browser.setMode(.sheet, animated: false)
    XCTAssertTrue(browser.isSidebarOpen, "広幅右シートを開き直すと開記憶が維持されている")
  }

  /// 狭幅オーバーレイは暗幕クリック・タブ選択・`Esc` で自動閉鎖してブラウザへ焦点を戻し、
  /// スペース切替では開いたまま保つ。横並びではタブ選択や `Esc` で閉じない。
  func testSidebarOverlayAutoClosesOnScrimTabAndEscapeButKeepsOpenOnSpaceSwitch() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    let spaceA = try XCTUnwrap(session.store.freeSpaces.first)
    let tabA = try XCTUnwrap(session.openTab(in: spaceA.id, url: nil, activate: true))
    let tabB = try XCTUnwrap(session.openTab(in: spaceA.id, url: nil, activate: false))

    // 狭幅右シート（400pt < 520pt）でオーバーレイを開く。
    browser.setSheetRatio(0.40)
    browser.setMode(.sheet, animated: false)
    browser.focusBrowser()
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOverlay)

    // 1. スペース切替ではオーバーレイを閉じない。
    browser.sidebarActions.onSelectSpace(.local)
    XCTAssertEqual(session.store.activeSpaceSelection, .local)
    XCTAssertTrue(browser.isSidebarOverlay, "スペース切替時は続けてタブを選べるよう開いたまま")

    // 2. 暗幕クリックで閉じてブラウザへ焦点が戻る。
    let scrimClick = NSEvent.mouse(
      .leftMouseDown,
      at: browser.sidebarScrim.convert(NSPoint(x: 350, y: 100), to: nil),
      in: window)
    browser.sidebarScrim.mouseDown(with: scrimClick)
    XCTAssertFalse(browser.isSidebarOpen, "暗幕クリックでオーバーレイが閉じる")
    XCTAssertTrue(window.firstResponder === browser)

    // 3. タブ選択で対象タブへ切り替わった後にオーバーレイが自動閉鎖する。
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOverlay)
    browser.sidebarActions.onSelectTab(tabB.id)
    XCTAssertEqual(session.store.activeTab?.id, tabB.id)
    XCTAssertFalse(browser.isSidebarOpen, "狭幅オーバーレイ中のタブ選択で自動閉鎖する")
    XCTAssertTrue(window.firstResponder === browser)

    // 4. Esc でオーバーレイが自動閉鎖する。
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOverlay)
    let esc = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false, keyCode: 53)!
    XCTAssertTrue(browser.performKeyEquivalent(with: esc))
    XCTAssertFalse(browser.isSidebarOpen, "Esc でオーバーレイが閉じる")
    XCTAssertTrue(window.firstResponder === browser)

    // 5. 横並び（600pt >= 520pt）ではタブ選択や Esc でサイドバーを閉じない。
    browser.setSheetRatio(0.60)
    hosted.stage.layoutSubtreeIfNeeded()
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOpen)
    XCTAssertFalse(browser.isSidebarOverlay)
    browser.sidebarActions.onSelectTab(tabA.id)
    XCTAssertTrue(browser.isSidebarOpen, "横並びではタブ選択で閉じない")
    _ = browser.performKeyEquivalent(with: esc)
    XCTAssertTrue(browser.isSidebarOpen, "横並びでは Esc で閉じない")
  }

  /// 狭幅オーバーレイ出現時に `contentView` 配下（新タブ入力欄）から同期（`toggleSidebar`）および
  /// リサイズ遷移時（非同期）に焦点を `BrowserLayerView` へ退避し、オーバーレイ開中の `focusToken` を抑止する。
  func testSidebarOverlayReclaimsContentFocusOnToggleResizeAndBlocksGhostFocus() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)

    // 1. 狭幅右シート（オーバーレイ閉）で focusToken を進めると同じ flush + nextTurn 時点で焦点を取る（対の肯定）。
    browser.setSheetRatio(0.40)
    browser.setMode(.sheet, animated: false)
    browser.openNewTab()
    flush(window)
    nextTurn()
    XCTAssertTrue(
      (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true,
      "対の肯定: オーバーレイ閉時は flush + nextTurn で新タブ入力欄に焦点が当たる（不成立なら下の否定時点も無効）")

    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOverlay)
    XCTAssertTrue(
      window.firstResponder === browser,
      "toggleSidebar() でオーバーレイが出現した瞬間に contentView 配下から同期退避する")

    // 2. オーバーレイ開中に focusToken が進んでも canFocusInput ガードで暗幕裏へ焦点を入れない。
    browser.newTabModel.focusToken &+= 1
    flush(window)
    nextTurn()
    XCTAssertTrue(window.firstResponder === browser, "オーバーレイ開中は暗幕裏の入力欄へ焦点を奪われない")

    // 3. 横並び（600pt）でサイドバーを開き新タブ入力欄へ焦点を当てた状態から 400pt へリサイズ → 非同期で退避。
    browser.toggleSidebar()  // オーバーレイ閉
    browser.setSheetRatio(0.60)  // 600pt
    hosted.stage.layoutSubtreeIfNeeded()
    browser.toggleSidebar()  // 横並び開
    XCTAssertFalse(browser.isSidebarOverlay)
    browser.newTabModel.focusToken &+= 1
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      }, "前提: 横並び開中は新タブ入力欄へ焦点を当てられる")

    browser.setSheetRatio(0.40)  // 400pt へ縮めて横並び → オーバーレイ遷移
    hosted.stage.layoutSubtreeIfNeeded()
    XCTAssertTrue(browser.isSidebarOverlay)
    nextTurn()
    XCTAssertTrue(
      window.firstResponder === browser,
      "リサイズによる横並び→オーバーレイ遷移でも contentView 配下から焦点が退避される")
  }

  /// 遷移済み `WKWebView` 上の狭幅オーバーレイで、同期退避・スペース切替時の背後非流出・
  /// 暗幕/`Esc` 閉鎖後の `WKWebView` 焦点復帰・`+ 新しいタブ` 自動閉鎖、および暗幕/サイドバーの `hitTest` を守る。
  func testSidebarOverlayProtectsNavigatedWebViewFocusAutoClosesOnNewTabAndHitTests() throws {
    let hosted = hostBrowser()
    let (window, stage, browser) = (hosted.window, hosted.stage, hosted.browser)
    let session = browser.session
    let freeSpace = try XCTUnwrap(session.store.freeSpaces.first)
    let secondSpace = try XCTUnwrap(session.store.freeSpaces.dropFirst().first)

    browser.setSheetRatio(0.40)  // 400pt < 520pt
    browser.setMode(.sheet, animated: false)
    XCTAssertTrue(session.selectSpace(.free(freeSpace.id)))
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    browser.loadHTMLString("<title>SpaceA</title><p>a</p>", baseURL: nil)
    pumpMain(until: { finishes >= 1 }, timeout: 5, "SpaceA の初期 HTML 読込完了")

    XCTAssertTrue(session.selectSpace(.free(secondSpace.id)))
    browser.loadHTMLString("<title>SpaceB</title><p>b</p>", baseURL: nil)
    pumpMain(until: { finishes >= 2 }, timeout: 5, "SpaceB の初期 HTML 読込完了")
    let webViewB = try XCTUnwrap(browser.webView)
    browser.focusBrowser()
    XCTAssertTrue(window.firstResponder === webViewB, "前提: 遷移済み WKWebView に焦点")

    // 1. オーバーレイ開で WKWebView から同期退避し、hitTest で暗幕とサイドバーを分離できる。
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOverlay)
    XCTAssertTrue(window.firstResponder === browser, "遷移済み WKWebView から self へ同期退避する")
    let scrimPoint = browser.belowBar.convert(NSPoint(x: 350, y: 200), to: stage)
    let sidebarPoint = browser.belowBar.convert(NSPoint(x: 100, y: 200), to: stage)
    XCTAssertTrue(stage.hitTest(scrimPoint) === browser.sidebarScrim, "暗幕露出域は sidebarScrim")
    let sidebarHit = try XCTUnwrap(stage.hitTest(sidebarPoint))
    XCTAssertTrue(
      sidebarHit === browser.sidebarContainer
        || sidebarHit.isDescendant(of: browser.sidebarContainer),
      "サイドバー領域は sidebarContainer 配下に当たる")

    // 2. オーバーレイ開中に別スペース（遷移済み WKWebView あり）へ切り替えても背後へ流出しない。
    browser.sidebarActions.onSelectSpace(.free(freeSpace.id))
    let webViewA = try XCTUnwrap(browser.webView)
    XCTAssertTrue(browser.isSidebarOverlay)
    XCTAssertTrue(window.firstResponder === browser, "スペース切替で背後 WKWebView へ焦点が流出しない")

    // 3. 暗幕クリックおよび Esc で閉じると遷移済み WKWebView へ焦点が戻る。
    let scrimClick = NSEvent.mouse(
      .leftMouseDown,
      at: browser.sidebarScrim.convert(NSPoint(x: 350, y: 100), to: nil),
      in: window)
    browser.sidebarScrim.mouseDown(with: scrimClick)
    XCTAssertFalse(browser.isSidebarOpen)
    XCTAssertTrue(window.firstResponder === webViewA, "暗幕閉鎖で遷移済み WKWebView へ焦点復帰")

    browser.toggleSidebar()
    XCTAssertTrue(window.firstResponder === browser)
    let esc = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false, keyCode: 53)!
    XCTAssertTrue(browser.performKeyEquivalent(with: esc))
    XCTAssertFalse(browser.isSidebarOpen)
    XCTAssertTrue(window.firstResponder === webViewA, "Esc 閉鎖で遷移済み WKWebView へ焦点復帰")

    // 4. オーバーレイ開中の + 新しいタブ でオーバーレイ自動閉鎖＋新タブ入力欄へ焦点が移る。
    browser.toggleSidebar()
    XCTAssertTrue(browser.isSidebarOverlay)
    browser.sidebarActions.onOpenNewTab()
    XCTAssertFalse(browser.isSidebarOpen, "+ 新しいタブ で狭幅オーバーレイが自動閉鎖する")
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      }, "+ 新しいタブ で新タブ入力欄へ焦点が当たる")
  }
}
