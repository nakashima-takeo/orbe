import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ビュー内ポップオーバーの焦点不変条件（`focusTarget === self`・フォーム破棄前の同期退避・
/// ツールバー／ドラッグ／フォーカス喪失での排他解除）、新しいタブ画面の焦点・URL 遷移・空タブ自動掃除、
/// および `BrowserInlineTextField` の常駐再フォーカスと IME 保護を守る。
///
/// 壊れると何が起きるか。プロファイル変更や削除で焦点が背後 WebView へ逃げてポップオーバーが暴走する、
/// フォーム画面切替で `firstResponder` が窓へ落ちてポップオーバーが連鎖即閉鎖する、
/// ツールバーやドラッグとポップオーバーが二重状態になる、クイックアクセスや復元のたびに
/// 空タブのゴミが溜まる、あるいは常駐入力欄で Esc 後にクリック再フォーカスすると blur が壊れる。
extension BrowserLayerViewTests {
  private func findTextField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField { return field }
    for subview in view.subviews {
      if let found = findTextField(in: subview) { return found }
    }
    return nil
  }

  private func keyEvent(
    _ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: chars, charactersIgnoringModifiers: chars,
      isARepeat: false, keyCode: keyCode)!
  }

  // MARK: - ポップオーバー焦点不変条件・フォーム破棄前退避・排他解除

  /// ポップオーバー表示中は `focusTarget === browser` を維持してプロファイル付け替え・削除の再マウントでも
  /// 背後 `WKWebView` へ焦点を流出させず、フォーム破棄前の同期退避で `setFocused(false)` 連鎖閉鎖を防ぐ。
  /// 自由スペース削除は確認画面（`confirmingDelete: true`）を必ず経由し、ツールバー操作・ドラッグ・
  /// フォーカス喪失で排他閉鎖する。
  func testPopoverFocusInvariantPreUnmountReclaimAndExclusiveDismissal() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session

    // 本番 WindowController と同じ focus 監視を配線し、firstResponder 落下による連鎖閉鎖を再現可能にする。
    window.onFirstResponderChange = { _ in
      browser.setFocused(window.isKeyWindow && browser.focusIsInside)
    }

    let server = try LocalLoopbackHTTPServer(routes: ["/page": "<p>page</p>"])
    defer { server.stop() }
    browser.setMode(.full, animated: false)
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    browser.load(server.url(for: "/page"))
    pumpMain(until: { finishes >= 1 }, timeout: 5, "初期ページ読み込み完了")
    browser.focusBrowser()
    let initialWebView = try XCTUnwrap(browser.webView)
    XCTAssertTrue(window.firstResponder === initialWebView, "前提: 遷移後は WKWebView に焦点")

    // 1. ポップオーバー表示中は focusTarget === browser 固定。setSpaceProfile の再マウントでも背後へ流出しない。
    browser.openPopover(.profile)
    XCTAssertTrue(browser.focusTarget === browser)
    XCTAssertTrue(window.firstResponder === browser)
    let activeSpace = try XCTUnwrap(session.store.activeSpace)
    let otherProfile = try XCTUnwrap(
      session.store.profiles.first { $0.id != activeSpace.profileId })
    XCTAssertTrue(session.setSpaceProfile(activeSpace.id, profileId: otherProfile.id))
    XCTAssertTrue(browser.isPopoverOpen, "プロファイル切替でポップオーバーが閉じない")
    XCTAssertTrue(window.firstResponder === browser, "再マウント後も背後 WKWebView へ焦点が流出しない")

    // 2. 自由スペース編集フォーム（BrowserInlineTextField に焦点）から削除確認画面へ切り替えても
    //    同期退避により firstResponder が window へ落ちず連鎖閉鎖しない。
    let freeSpace = try XCTUnwrap(session.store.freeSpaces.first)
    browser.sidebarActions.onOpenEditSpace(freeSpace.id, false)
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.popoverHost) == true
      }, "自由スペース編集フォームの入力欄が焦点を取る")

    browser.sidebarActions.onOpenEditSpace(freeSpace.id, true)
    flush(window)
    nextTurn()
    XCTAssertEqual(
      browser.popoverState, .editSpace(freeSpace.id, confirmingDelete: true),
      "フォーム破棄に伴う連鎖閉鎖を起こさず削除確認画面へ遷移する")
    XCTAssertNotNil(session.store.space(id: freeSpace.id), "削除メニュー経由でも確認前に即削除しない")
    XCTAssertTrue(browser.isBrowserFocused)
    XCTAssertTrue(window.firstResponder === browser)

    // 3. 作成フォームの Enter 確定で自由スペースを作成・選択し、破棄前退避を経て焦点が browser 側へ残る。
    browser.sidebarActions.onOpenCreateSpace()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.popoverHost) == true
      }, "作成フォーム入力欄が焦点を取る")
    let createEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
    replaceAll("設計ノート", in: createEditor)
    deliverKeyDown(keyEvent("\r", keyCode: 36, in: window), to: window)
    flush(window)
    XCTAssertFalse(browser.isPopoverOpen, "作成完了でポップオーバーが閉じる")
    XCTAssertEqual(session.store.activeSpace?.name, "設計ノート")
    XCTAssertTrue(browser.isBrowserFocused, "フォーム破棄後もブラウザ焦点が落ちない")

    // 4. ツールバー全操作入口・ドラッグ開始・フォーカス喪失で排他閉鎖し、Esc で閉鎖＋focusBrowser()。
    assertPopoverExclusiveDismissal(browser: browser, window: window)
  }

  private func assertPopoverExclusiveDismissal(browser: BrowserLayerView, window: NSWindow) {
    browser.openPopover(.profile)
    browser.toolbar.onBack()
    XCTAssertFalse(browser.isPopoverOpen, "戻るボタンでポップオーバーが閉じる")

    browser.openPopover(.profile)
    browser.toolbar.onReloadOrStop()
    XCTAssertFalse(browser.isPopoverOpen, "再読込ボタンでポップオーバーが閉じる")

    browser.openPopover(.profile)
    browser.beginURLEditing()
    XCTAssertFalse(browser.isPopoverOpen, "URL 編集開始でポップオーバーが閉じる")
    browser.cancelURLEditing()

    browser.openPopover(.profile)
    browser.toggleSidebar()
    XCTAssertFalse(browser.isPopoverOpen, "サイドバー開閉でポップオーバーが閉じる")

    browser.setMode(.sheet, animated: false)
    browser.openPopover(.profile)
    browser.dragDidStart()
    XCTAssertFalse(browser.isPopoverOpen, "ドラッグ開始でポップオーバーが閉じる")
    browser.dragDidEnd(cancelled: true)

    browser.openPopover(.profile)
    browser.setFocused(true)
    browser.setFocused(false)
    XCTAssertFalse(browser.isPopoverOpen, "フォーカス喪失でポップオーバーが閉じる")

    browser.setFocused(true)
    browser.openPopover(.profile)
    XCTAssertTrue(browser.performKeyEquivalent(with: keyEvent("\u{1B}", keyCode: 53, in: window)))
    XCTAssertFalse(browser.isPopoverOpen, "Esc でポップオーバーが閉じる")
    XCTAssertTrue(window.firstResponder === browser.focusTarget, "Esc 閉鎖後に focusTarget へ戻る")
  }

  // MARK: - 新しいタブ画面の契約と空タブ掃除

  /// 単なる空表示では中央入力欄へ自動フォーカスせず、`openNewTab()` 経由のみ中央入力欄へフォーカスする。
  /// クイックアクセス選択・最近閉じたタブ復元では元の空 `TODAY` タブだけを履歴へ積まずに掃除し、
  /// 非空タブ・非 `TODAY` タブ・復元失敗時は掃除しない。
  func testNewTabFocusContractURLCommitQuickAccessAndReopenEmptyCleanup() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    let freeSpace = try XCTUnwrap(session.store.freeSpaces.first)
    XCTAssertTrue(session.selectSpace(.free(freeSpace.id)))

    let server = try LocalLoopbackHTTPServer(routes: [
      "/fav": "<title>Fav</title><p>fav</p>",
      "/closed": "<title>Closed</title><p>closed</p>",
      "/typed": "<title>Typed</title><p>typed</p>",
    ])
    defer { server.stop() }

    // 1. 単なる空表示（⌘B 開／session.openTab 直接呼び出し）では自動フォーカスしない。
    browser.setMode(.full, animated: false)
    browser.focusBrowser()
    flush(window)
    nextTurn()
    XCTAssertEqual(browser.newTabModel.focusToken, 0)
    XCTAssertTrue(window.firstResponder === browser, "単なる空表示では BrowserLayerView 自身が焦点を持つ")

    let favTab = try XCTUnwrap(
      session.openTab(
        in: freeSpace.id, section: .favorite, url: server.url(for: "/fav"), title: "Fav",
        activate: false))
    let closedSource = try XCTUnwrap(
      session.openTab(
        in: freeSpace.id, section: .today, url: server.url(for: "/closed"), title: "Closed",
        activate: false))
    XCTAssertTrue(session.closeTab(closedSource.id, recordClosed: true))
    let closedEntry = try XCTUnwrap(session.store.reopenableClosedTabs().first)

    // 2. openNewTab() 経由のみ中央入力欄が焦点を取る。不正 URL は留まり、有効 URL で遷移＋webView 焦点。
    try assertNewTabInputCommitAndValidation(
      browser: browser, window: window, validURL: server.url(for: "/typed"))

    // 3. 空 TODAY タブからクイックアクセス・最近閉じたタブ復元での掃除境界と背景タップを確認する。
    try assertNewTabEmptyCleanupAndBackgroundTap(
      browser: browser, window: window, freeSpaceId: freeSpace.id, favTabId: favTab.id,
      closedEntry: closedEntry)
  }

  private func assertNewTabInputCommitAndValidation(
    browser: BrowserLayerView, window: NSWindow, validURL: URL
  ) throws {
    browser.openNewTab()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      }, "openNewTab() で中央入力欄が焦点を取る")
    let newTabEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
    replaceAll("not a url", in: newTabEditor)
    deliverKeyDown(keyEvent("\r", keyCode: 36, in: window), to: window)
    XCTAssertFalse(browser.hasNavigated, "不正 URL は遷移しない")
    XCTAssertTrue(window.firstResponder === newTabEditor, "不正 URL は入力欄に留まる")

    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    replaceAll(validURL.absoluteString, in: newTabEditor)
    deliverKeyDown(keyEvent("\r", keyCode: 36, in: window), to: window)
    pumpMain(until: { finishes >= 1 }, timeout: 5, "新タブ入力欄からの URL 遷移完了")
    XCTAssertEqual(browser.webView?.url, validURL)
    XCTAssertTrue(window.firstResponder === browser.webView, "遷移確定後は WKWebView へ焦点が移る")
  }

  private func assertNewTabEmptyCleanupAndBackgroundTap(
    browser: BrowserLayerView, window: NSWindow, freeSpaceId: UUID, favTabId: UUID,
    closedEntry: BrowserClosedTab
  ) throws {
    let session = browser.session
    // 空 TODAY タブからクイックアクセス選択 → 対象タブへ切替＋元空タブは履歴なし除去。
    browser.openNewTab()
    let emptyForQuick = try XCTUnwrap(session.store.activeTab)
    let closedCountBeforeQuick = session.store.closedTabs.count
    browser.newTabActions.onSelectQuickAccess(favTabId)
    XCTAssertEqual(session.store.activeTab?.id, favTabId)
    XCTAssertNil(session.store.tab(id: emptyForQuick.id), "元の空 TODAY タブが掃除される")
    XCTAssertEqual(
      session.store.closedTabs.count, closedCountBeforeQuick, "掃除は recordClosed: false で履歴に積まない")

    // 空 TODAY タブから最近閉じたタブ復元 → 失敗時は消さず、成功時のみ元空タブを履歴なし除去。
    browser.openNewTab()
    let emptyForReopen = try XCTUnwrap(session.store.activeTab)
    browser.newTabActions.onReopenClosedTab(999_999)
    XCTAssertNotNil(session.store.tab(id: emptyForReopen.id), "復元失敗時は空タブを消さない")

    browser.newTabActions.onReopenClosedTab(closedEntry.id)
    XCTAssertEqual(session.store.activeTab?.url, closedEntry.url)
    XCTAssertNil(session.store.tab(id: emptyForReopen.id), "復元成功後に元空タブが掃除される")

    // 空 PINNED タブは TODAY ではないためクイックアクセス経由でも掃除しない。
    let emptyPinned = try XCTUnwrap(
      session.openTab(in: freeSpaceId, section: .pinned, url: nil, activate: true))
    browser.newTabActions.onSelectQuickAccess(favTabId)
    XCTAssertNotNil(session.store.tab(id: emptyPinned.id), "PINNED の空タブは掃除対象外")

    // 背景余白タップでポップオーバーと URL 編集を閉じて focusBrowser() する。
    browser.openNewTab()
    browser.openPopover(.profile)
    browser.newTabActions.onTapBackground()
    XCTAssertFalse(browser.isPopoverOpen)
    XCTAssertTrue(window.firstResponder === browser)
  }

  // MARK: - BrowserInlineTextField の常駐再フォーカスと IME 保護

  /// 常駐する `BrowserInlineTextField` で Esc 明示終了した後に直接フォーカスして再編集しても
  /// `endedExplicitly` がリセットされて他所クリックで `onBlur` が発火し、
  /// 編集中 `updateNSView` でテキストと IME 未確定文字列が上書きされず、IME 変換中の Enter / Esc を保護する。
  func testInlineTextFieldResetsExplicitEndOnRefocusPreservesEditingTextAndIME() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    hosted.underlay.addSubview(outsider)

    // 1. 新タブ画面の常駐入力欄: 編集中 updateNSView の非上書きと IME 変換中 Enter / Esc 保護。
    browser.setMode(.full, animated: false)
    browser.openNewTab()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      }, "新タブ入力欄が焦点を取る")
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    replaceAll("https://ex", in: editor)
    markComposing(editor, "あい")
    let beforeUpdate = editor.string
    browser.newTabModel.inputText = "external-overwrite"
    flush(window)
    XCTAssertEqual(editor.string, beforeUpdate, "編集中は外部 updateNSView で文字列を上書きしない")
    XCTAssertTrue(editor.hasMarkedText(), "編集中は IME 未確定文字列も壊さない")

    deliverKeyDown(keyEvent("\r", keyCode: 36, in: window), to: window)
    XCTAssertTrue(window.firstResponder === editor, "IME 変換中の Enter は確定しない")
    markComposing(editor, "あい")
    deliverKeyDown(keyEvent("\u{1B}", keyCode: 53, in: window), to: window)
    XCTAssertTrue(window.firstResponder === editor, "IME 変換中の Esc はキャンセルしない")
    editor.unmarkText()

    // 2. 常駐 BrowserInlineTextField（正規の onBlur / onFocusChange 境界）:
    //    Esc 明示終了（onBlur 非発火）後に直接再フォーカス・編集すると、次の他所クリックで onBlur が発火する。
    var blurCount = 0
    var cancelCount = 0
    var focusHistory: [Bool] = []
    let field = try makeInlineFieldProbe(
      in: hosted,
      onFocusChange: { focusHistory.append($0) },
      onCancel: {
        cancelCount += 1
        window.makeFirstResponder(browser)
      },
      onBlur: { blurCount += 1 })
    XCTAssertTrue(window.makeFirstResponder(field))
    replaceAll("first", in: try XCTUnwrap(window.firstResponder as? NSTextView))
    deliverKeyDown(keyEvent("\u{1B}", keyCode: 53, in: window), to: window)
    XCTAssertEqual(cancelCount, 1)
    XCTAssertEqual(blurCount, 0, "Esc の明示終了では onBlur を発火しない")

    XCTAssertTrue(window.makeFirstResponder(field))
    replaceAll("second", in: try XCTUnwrap(window.firstResponder as? NSTextView))
    XCTAssertEqual(focusHistory.last, true)
    XCTAssertTrue(window.makeFirstResponder(outsider))
    XCTAssertEqual(blurCount, 1, "Esc 後に再フォーカスした常駐欄でも他所クリックで onBlur が発火する")
    XCTAssertEqual(focusHistory.last, false)
  }

  /// バグ疑い（xfail）: `BrowserInlineTextField` は `becomeFirstResponder()` 直後（文字入力前）から
  /// `onFocusChange(true)` を通知し、Esc 明示終了後に直接再フォーカスして未編集のまま他所へ移動しても
  /// `endedExplicitly` リセット済みとして `onBlur` を発火すべき。
  func testInlineTextFieldNotifiesFocusAndResetsExplicitEndBeforeTyping() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    hosted.underlay.addSubview(outsider)

    // 1. 新タブ画面で openNewTab() により焦点が当たった直後（文字入力前）に isInputFocused が true になる。
    browser.setMode(.full, animated: false)
    browser.openNewTab()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      }, "新タブ入力欄が焦点を取る")
    XCTExpectFailure("becomeFirstResponder 時点で onFocusChange(true) が未通知") {
      XCTAssertTrue(browser.newTabModel.isInputFocused, "文字入力前からフォーカス強調枠が点灯する")
    }

    // 2. Esc 取消 → 直接再フォーカス → 未編集のまま他所クリックでも onFocusChange(true) と onBlur が動く。
    var blurCount = 0
    var focusHistory: [Bool] = []
    let field = try makeInlineFieldProbe(
      in: hosted, onFocusChange: { focusHistory.append($0) },
      onCancel: { window.makeFirstResponder(browser) }, onBlur: { blurCount += 1 })
    XCTAssertTrue(window.makeFirstResponder(field))
    replaceAll("draft", in: try XCTUnwrap(window.firstResponder as? NSTextView))
    deliverKeyDown(keyEvent("\u{1B}", keyCode: 53, in: window), to: window)
    XCTAssertEqual(blurCount, 0)

    XCTAssertTrue(window.makeFirstResponder(field))
    XCTExpectFailure("未編集再フォーカス時に endedExplicitly リセットと焦点通知を行わない") {
      XCTAssertEqual(focusHistory.last, true, "未編集の再フォーカス直後に onFocusChange(true) が届く")
      XCTAssertTrue(window.makeFirstResponder(outsider))
      XCTAssertEqual(blurCount, 1, "未編集のまま他所クリックしても onBlur が発火する")
      XCTAssertEqual(focusHistory.last, false)
    }
  }

  private func makeInlineFieldProbe(
    in hosted: Hosted, onFocusChange: @escaping (Bool) -> Void,
    onCancel: @escaping () -> Void, onBlur: @escaping () -> Void
  ) throws -> NSTextField {
    let fieldHost = NSHostingView(
      rootView: InlineFieldProbeView(
        model: InlineFieldProbeModel(), onFocusChange: onFocusChange,
        onCancel: onCancel, onBlur: onBlur))
    fieldHost.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
    hosted.underlay.addSubview(fieldHost)
    fieldHost.layoutSubtreeIfNeeded()
    return try XCTUnwrap(findTextField(in: fieldHost))
  }
}

@Observable private final class InlineFieldProbeModel { var text = "" }

private struct InlineFieldProbeView: View {
  @Bindable var model: InlineFieldProbeModel
  let onFocusChange: (Bool) -> Void
  let onCancel: () -> Void
  let onBlur: () -> Void

  var body: some View {
    BrowserInlineTextField(
      text: $model.text, placeholder: "probe", onFocusChange: onFocusChange,
      onCommit: { _ in true }, onCancel: onCancel, onBlur: onBlur)
  }
}
