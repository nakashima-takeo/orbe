import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// URL 編集中（ツールバー／新タブ）とポップオーバー表示中のショートカット境界を守る。
/// 不発 `⌘W` / `⌘⇧T` の編集・焦点維持、有効実行時の `barHost` 同期退避（連鎖閉鎖防止）、
/// `⌘⇧T` での未遷移 `TODAY` 空タブ自動掃除、`⌘R` 再読込抑止、`⌘⇧←` / `⌘⇧→` 境界 3 分岐、および
/// `availableWithoutTabs` 6 コマンドの抑止を検証する。
///
/// 壊れると何が起きるか。URL 編集中に保護タブで `⌘W` や履歴 0 件で `⌘⇧T` を押しただけで
/// `firstResponder` が `NSWindow` へ落ちて単一降下ゲートが開き下層パレットが暴発する。
/// URL 編集中にポップオーバーを開くと 1 フレーム目で連鎖即閉鎖する。URL 編集中に `⌘R` で
/// ページが再読込される、あるいはフォーム編集中の `⌘⇧←` / `⌘⇧→` 行選択が効かなくなる。
extension BrowserLayerViewTests {
  /// ツールバー URL 欄編集中および新タブ入力欄編集中に `⌘R` を送ってもページ再読込が抑止される
  /// （対の通常時 `⌘R` では同期で `isProvisionalNavigation == true` になる）。
  func testCommandRReloadsNormallyButIsSuppressedWhileEditingURL() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let server = try LocalLoopbackHTTPServer(responses: [
      "/r": .sequence([
        .html("<!doctype html><title>R1</title><p>1</p>"),
        .html("<!doctype html><title>R2</title><p>2</p>"),
      ])
    ])
    defer { server.stop() }

    browser.setMode(.sheet, animated: false)
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    browser.load(server.url(for: "/r"))
    pumpMain(
      until: { finishes >= 1 && browser.webView?.title == "R1" }, timeout: 5, "初期ページ完了")

    // 対の肯定: 通常時 ⌘R は同期で暫定遷移を開始し R2 へ再読込する。
    browser.focusBrowser()
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("r")))
    XCTAssertTrue(
      browser.isProvisionalNavigation,
      "通常時 ⌘R は同期で再読込を開始する（これが待たずに成り立たなければ下の URL 編集中抑止時点も成り立たない）")
    pumpMain(
      until: { finishes >= 2 && browser.webView?.title == "R2" }, timeout: 5, "通常時 ⌘R 再読込完了")

    // 否定 1: ツールバー URL 編集中は ⌘R を無動作消費し同期で再読込を始めない。
    _ = try beginAndFocusURLField(in: hosted)
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("r")))
    XCTAssertFalse(browser.isProvisionalNavigation, "ツールバー URL 編集中は ⌘R で再読込しない")
    XCTAssertEqual(browser.webView?.title, "R2")
    browser.cancelURLEditing()

    // 否定 2: 新タブ入力欄編集中も ⌘R で再読込を始めない。
    browser.openNewTab()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      },
      "新タブ入力欄に焦点")
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("r")))
    XCTAssertFalse(browser.isProvisionalNavigation)
    XCTAssertFalse(browser.hasNavigated)
  }

  /// URL 編集中（ツールバー／新タブ）に不発となる `⌘W`（`PINNED`/`Favorites`/0 枚）と
  /// `⌘⇧T`（履歴 0 件）は編集状態・入力文字列・焦点を維持し `NSWindow` へ落下しない。
  /// 有効実行時の `⌘W` / `⌘⇧T`・`openPopover`・`openNewTab` は `barHost` を同期退避して連鎖閉鎖せず、
  /// `⌘⇧T` 復元でも未遷移 `TODAY` 空タブを `recordClosed: false` で自動掃除する。
  func testURLEditingNoOpAndValidShortcutReclaimAndCommandShiftTEmptyCleanup() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    var focusDrops: [String] = []
    window.onFirstResponderChange = { responder in
      let focused = window.isKeyWindow && browser.focusIsInside
      browser.setFocused(focused)
      if !focused { focusDrops.append(String(describing: responder)) }
    }

    let server = try LocalLoopbackHTTPServer(routes: [
      "/doc": "<!doctype html><title>Doc</title><p>doc</p>"
    ])
    defer { server.stop() }
    let docURL = server.url(for: "/doc")
    let free = try XCTUnwrap(session.store.freeSpaces.first)
    XCTAssertTrue(session.selectSpace(.free(free.id)))
    browser.setMode(.full, animated: false)
    browser.focusBrowser()
    focusDrops.removeAll()

    // 1. 0 枚・PINNED・Favorites の不発 ⌘W と履歴 0 件の不発 ⌘⇧T で編集・焦点・入力を維持する。
    try assertNoOpCloseAndReopenKeepEditing(
      hosted: hosted, freeId: free.id, docURL: docURL,
      resetDrops: { focusDrops.removeAll() }, drops: { focusDrops })

    // 2. ツールバー URL 編集中からの openPopover / openNewTab / 有効 ⌘W / 有効 ⌘⇧T で連鎖閉鎖・落下しない。
    try assertValidEditingActionsReclaimBarHostAndCleanupEmptyTab(
      hosted: hosted, freeId: free.id, docURL: docURL,
      resetDrops: { focusDrops.removeAll() }, drops: { focusDrops })
  }

  private func assertNoOpCloseAndReopenKeepEditing(
    hosted: Hosted, freeId: UUID, docURL: URL,
    resetDrops: () -> Void, drops: () -> [String]
  ) throws {
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session

    // 0 枚 + ツールバー URL 編集中: 不発 ⌘W / ⌘⇧T とも編集と入力を維持。
    let zeroEditor = try beginAndFocusURLField(in: hosted)
    replaceAll("https://keep.example", in: zeroEditor)
    resetDrops()
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("w")))
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("T", [.command, .shift])))
    XCTAssertTrue(browser.isEditingURL)
    XCTAssertTrue(window.firstResponder === zeroEditor)
    XCTAssertEqual(zeroEditor.string, "https://keep.example")
    XCTAssertEqual(drops(), [], "0 枚不発 ⌘W / ⌘⇧T で焦点落下しない")
    browser.cancelURLEditing()

    // PINNED / Favorites + ツールバー URL 編集中: 保護タブの ⌘W は不発で編集・焦点維持。
    for section in [BrowserTabSection.pinned, .favorite] {
      let tab = try XCTUnwrap(
        session.openTab(in: freeId, section: section, url: docURL, activate: true))
      let editor = try beginAndFocusURLField(in: hosted)
      replaceAll("https://stay.example", in: editor)
      resetDrops()
      XCTAssertTrue(browser.performKeyEquivalent(with: .key("w")))
      XCTAssertNotNil(session.store.tab(id: tab.id))
      XCTAssertTrue(browser.isEditingURL)
      XCTAssertTrue(window.firstResponder === editor)
      XCTAssertEqual(editor.string, "https://stay.example")
      XCTAssertEqual(drops(), [], "保護タブ不発 ⌘W で焦点落下しない")
      browser.cancelURLEditing()
    }

    // 新タブ入力欄編集中（空 PINNED タブ + 履歴 0 件）: 不発 ⌘W / ⌘⇧T で編集・焦点維持。
    let emptyPinned = try XCTUnwrap(
      session.openTab(in: freeId, section: .pinned, url: nil, activate: true))
    browser.newTabModel.focusToken &+= 1
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      },
      "空 PINNED の新タブ入力欄に焦点")
    let newEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
    replaceAll("draft-pinned", in: newEditor)
    resetDrops()
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("w")))
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("T", [.command, .shift])))
    XCTAssertNotNil(session.store.tab(id: emptyPinned.id))
    XCTAssertTrue(window.firstResponder === newEditor)
    XCTAssertEqual(newEditor.string, "draft-pinned")
    XCTAssertEqual(drops(), [], "新タブ欄不発 ⌘W / ⌘⇧T で焦点落下しない")
  }

  private func assertValidEditingActionsReclaimBarHostAndCleanupEmptyTab(
    hosted: Hosted, freeId: UUID, docURL: URL,
    resetDrops: () -> Void, drops: () -> [String]
  ) throws {
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session

    // openPopover: ツールバー URL 編集中から開いても barHost 同期退避により連鎖即閉鎖しない。
    _ = try beginAndFocusURLField(in: hosted)
    resetDrops()
    browser.openPopover(.profile)
    flush(window)
    XCTAssertTrue(browser.isPopoverOpen, "URL 編集中からの openPopover が 1 フレーム目で連鎖閉鎖しない")
    XCTAssertFalse(browser.isEditingURL)
    XCTAssertEqual(drops(), [], "openPopover で焦点落下しない")
    browser.closePopover()

    // openNewTab: URL 編集中から開いても barHost 退避して焦点落下せず新タブ入力欄へ移る。
    _ = try beginAndFocusURLField(in: hosted)
    resetDrops()
    browser.openNewTab()
    flush(window)
    XCTAssertFalse(browser.isEditingURL)
    XCTAssertEqual(drops(), [], "openNewTab で焦点落下しない")

    // 有効 ⌘W: URL 編集中に TODAY タブを閉じても焦点落下しない。
    let today = try XCTUnwrap(
      session.openTab(in: freeId, section: .today, url: docURL, activate: true))
    _ = try beginAndFocusURLField(in: hosted)
    resetDrops()
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("w")))
    XCTAssertNil(session.store.tab(id: today.id))
    XCTAssertFalse(browser.isEditingURL)
    XCTAssertEqual(drops(), [], "有効 ⌘W で焦点落下しない")

    // 有効 ⌘⇧T: 未遷移 TODAY 空タブ＋ツールバー URL 編集中から復元すると、元空タブが履歴無し自動掃除される。
    browser.openNewTab()
    let emptyToday = try XCTUnwrap(session.store.activeTab)
    let closedBefore = session.store.closedTabs.count
    _ = try beginAndFocusURLField(in: hosted)
    resetDrops()
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("T", [.command, .shift])))
    XCTAssertEqual(session.store.activeTab?.url, docURL)
    XCTAssertNil(session.store.tab(id: emptyToday.id), "⌘⇧T 復元でも未遷移 TODAY 空タブを自動掃除する")
    XCTAssertEqual(session.store.closedTabs.count, closedBefore - 1, "掃除は recordClosed: false")
    XCTAssertEqual(drops(), [], "有効 ⌘⇧T で焦点落下しない")

    // 非空 TODAY タブ表示中の ⌘⇧T 復元では閲覧中タブを掃除しない。
    let activeNonEmpty = try XCTUnwrap(session.store.activeTab)
    let closedSecond = try XCTUnwrap(
      session.openTab(in: freeId, section: .today, url: docURL, activate: false))
    XCTAssertTrue(session.closeTab(closedSecond.id, recordClosed: true))
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("T", [.command, .shift])))
    XCTAssertNotNil(session.store.tab(id: activeNonEmpty.id), "非空 TODAY タブは ⌘⇧T で掃除しない")
  }

  /// 新タブ入力欄編集中・ポップオーバー非フォーム表示中・ポップオーバーフォーム編集中の
  /// `⌘⇧←` / `⌘⇧→` 境界 3 分岐と、URL 編集中・ポップオーバー中の `availableWithoutTabs` 6 キー抑止を守る。
  func testCommandShiftArrowsInNewTabAndPopoverAndPaletteKeysSuppressed() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    var commands: [WindowCommand] = []
    browser.onWindowCommand = { commands.append($0) }
    browser.setMode(.full, animated: false)
    browser.focusBrowser()

    let cmdShiftLeft = specialKey(.leftArrow, keyCode: 123, flags: [.command, .shift], in: window)
    let cmdShiftRight = specialKey(
      .rightArrow, keyCode: 124, flags: [.command, .shift], in: window)
    let paletteEvents: [NSEvent] = [
      .key("S", [.command, .shift]), .key("C", [.command, .shift]),
      .key("A", [.command, .shift]), .key("X", [.command, .shift]),
      .key(","), .key("h"),
    ]

    // 1. 新タブ入力欄編集中: ⌘⇧←/→ は入力欄へ素通し（false）、availableWithoutTabs 6 キーは抑止（true）。
    browser.openNewTab()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      },
      "新タブ入力欄に焦点")
    XCTAssertFalse(browser.performKeyEquivalent(with: cmdShiftLeft), "新タブ入力中の ⌘⇧← は素通し")
    XCTAssertFalse(browser.performKeyEquivalent(with: cmdShiftRight), "新タブ入力中の ⌘⇧→ は素通し")
    for event in paletteEvents { XCTAssertTrue(browser.performKeyEquivalent(with: event)) }
    XCTAssertTrue(commands.isEmpty)

    // 2. ポップオーバー非フォーム表示中（.profile メイン画面）: ⌘⇧←/→ と 6 キーをすべて無動作消費（true）。
    browser.openPopover(.profile)
    flush(window)
    XCTAssertTrue(browser.performKeyEquivalent(with: cmdShiftLeft), "非フォームポップオーバーの ⌘⇧← は無動作消費")
    XCTAssertTrue(browser.performKeyEquivalent(with: cmdShiftRight), "非フォームポップオーバーの ⌘⇧→ は無動作消費")
    for event in paletteEvents { XCTAssertTrue(browser.performKeyEquivalent(with: event)) }
    XCTAssertTrue(commands.isEmpty)

    // 3. ポップオーバーフォーム編集中（.createSpace 入力欄に焦点）: ⌘⇧←/→ は素通し（false）、6 キーは抑止。
    browser.openPopover(.createSpace)
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.popoverHost) == true
      },
      "ポップオーバーフォーム入力欄に焦点")
    XCTAssertFalse(browser.performKeyEquivalent(with: cmdShiftLeft), "フォーム編集中の ⌘⇧← は素通し")
    XCTAssertFalse(browser.performKeyEquivalent(with: cmdShiftRight), "フォーム編集中の ⌘⇧→ は素通し")
    for event in paletteEvents { XCTAssertTrue(browser.performKeyEquivalent(with: event)) }
    XCTAssertTrue(commands.isEmpty)
  }
}
