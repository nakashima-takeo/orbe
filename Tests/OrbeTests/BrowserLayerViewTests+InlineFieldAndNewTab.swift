import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 新タブ画面背景余白への実クリック焦点到達、非空タブの非掃除、`session.openTab` 非フォーカス、
/// 非変換 `Esc` 取消、`openNewTab()` 直後の `beginURLEditing()` 非奪取、および `BrowserInlineTextField` の
/// 編集中 `focusToken` 非破棄・非表示ゴースト焦点ガードを守る。
extension BrowserLayerViewTests {
  /// `BrowserNewTabView` の背景余白への実マウスクリックが `ScrollView` に遮られず `onTapBackground` へ届き、
  /// 非フォーカス右シートからでも新タブ入力欄編集中からでもブラウザ層へ焦点が移る。
  func testNewTabBackgroundClickReachesOnTapBackgroundFromUnderlayAndNewTabEditing() throws {
    // 1. 単体 BrowserNewTabView（BrowserLayerView.mouseDown フォールバックなし）の余白実クリックが
    //    ScrollView に遮られず actions.onTapBackground へ直接到達する。
    let probeWindow = OrbeWindowFake(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless],
      backing: .buffered, defer: false)
    probeWindow.isReleasedWhenClosed = false
    probeWindow.isKey = true
    holdUntilTestEnds(probeWindow)
    addTeardownBlock { MainActor.assumeIsolated { probeWindow.contentView = nil } }
    let actions = BrowserNewTabActions()
    var tapCount = 0
    actions.onTapBackground = { tapCount += 1 }
    let viewHost = BrowserNewTabHost(
      rootView: BrowserNewTabView(
        model: BrowserNewTabModel(), session: BrowserSession.inMemory(language: .ja),
        localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver(),
        actions: actions))
    viewHost.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
    probeWindow.contentView = viewHost
    viewHost.layoutSubtreeIfNeeded()
    placeOffscreen(probeWindow)
    flush(probeWindow)
    clickWindowPoint(NSPoint(x: 560, y: 40), in: probeWindow)
    XCTAssertEqual(
      tapCount, 1, "BrowserNewTabView 余白の実クリックが ScrollView に遮られず onTapBackground へ届く")

    // 2. 統合 BrowserLayerView: 下層 outsider 焦点中および新タブ入力欄編集中からの余白実クリックで焦点復帰。
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    hosted.underlay.addSubview(outsider)
    browser.setMode(.sheet, animated: false)
    placeOffscreen(window)
    flush(window)

    XCTAssertTrue(window.makeFirstResponder(outsider))
    XCTAssertFalse(browser.focusIsInside)
    clickWindowPoint(NSPoint(x: 960, y: 60), in: window)
    XCTAssertTrue(
      window.firstResponder === browser,
      "非フォーカス右シートの新タブ画面余白クリックで focusBrowser() が成立する")

    browser.openNewTab()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true
      }, "前提: 新タブ入力欄に焦点")
    XCTAssertTrue(browser.isEditingNewTabURL)
    clickWindowPoint(NSPoint(x: 960, y: 60), in: window)
    XCTAssertTrue(window.firstResponder === browser, "新タブ入力欄編集中も余白実クリックで browser へ戻る")
    XCTAssertFalse(browser.isEditingNewTabURL)
  }

  /// `session.openTab` 直接呼び出しでは中央入力欄へ自動フォーカスせず、非空 `TODAY` タブは
  /// クイックアクセス／復元で掃除されず、新タブ入力欄の非変換 `Esc` で `cancelNewTabURL()` が動く。
  /// また `openNewTab()` 直後に `beginURLEditing()` が入ってもツールバー URL 編集を奪わない。
  func testNewTabDirectOpenCancelEscNonEmptyProtectionAndToolbarEditingPrecedence() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    let free = try XCTUnwrap(session.store.freeSpaces.first)
    XCTAssertTrue(session.selectSpace(.free(free.id)))
    let server = try LocalLoopbackHTTPServer(routes: [
      "/a": "<title>A</title><p>a</p>",
      "/b": "<title>B</title><p>b</p>",
      "/c": "<title>C</title><p>c</p>",
    ])
    defer { server.stop() }

    browser.setMode(.full, animated: false)
    browser.focusBrowser()

    // 1. 対の肯定: openNewTab() は flush + nextTurn 時点で新タブ入力欄に焦点を当てる。
    browser.openNewTab()
    flush(window)
    nextTurn()
    XCTAssertTrue(
      (window.firstResponder as? NSTextView)?.isDescendant(of: browser.newTabHost) == true,
      "対の肯定: openNewTab() は flush + nextTurn で新タブ入力欄に焦点")

    // 非変換 Esc で cancelNewTabURL() が動き、browser 自身へ焦点が戻る。
    let esc = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false, keyCode: 53)!
    deliverKeyDown(esc, to: window)
    XCTAssertTrue(window.firstResponder === browser, "新タブ入力欄の非変換 Esc で browser へ戻る")

    // 2. 否定: session.openTab 直接呼び出しでは同じ flush + nextTurn 時点で自動フォーカスしない。
    _ = try XCTUnwrap(session.openTab(in: free.id, section: .today, url: nil, activate: true))
    flush(window)
    nextTurn()
    XCTAssertTrue(window.firstResponder === browser, "session.openTab 直接呼び出しは入力欄へ自動フォーカスしない")

    // 3. openNewTab() 直後に beginURLEditing() が入ると canFocusInput が偽になり URL 欄焦点を奪わない。
    browser.openNewTab()
    browser.beginURLEditing()
    flush(window)
    nextTurn()
    XCTAssertTrue(browser.isEditingURL)
    XCTAssertTrue(
      (window.firstResponder as? NSTextView)?.isDescendant(of: browser.barHost) == true,
      "openNewTab() 直後の beginURLEditing() でツールバー URL 欄の焦点を新タブ欄が奪わない")
    browser.cancelURLEditing()

    // 4. 非空 TODAY タブはクイックアクセス選択・最近閉じたタブ復元のいずれでも掃除しない。
    let fav = try XCTUnwrap(
      session.openTab(in: free.id, section: .favorite, url: server.url(for: "/a"), activate: false))
    let closedSeed = try XCTUnwrap(
      session.openTab(in: free.id, section: .today, url: server.url(for: "/b"), activate: false))
    XCTAssertTrue(session.closeTab(closedSeed.id, recordClosed: true))
    let closedItem = try XCTUnwrap(session.store.reopenableClosedTabs().first)
    let nonEmptyToday = try XCTUnwrap(
      session.openTab(in: free.id, section: .today, url: server.url(for: "/c"), activate: true))

    browser.newTabActions.onSelectQuickAccess(fav.id)
    XCTAssertNotNil(session.store.tab(id: nonEmptyToday.id), "非空 TODAY はクイックアクセスで掃除しない")
    XCTAssertTrue(session.selectTab(nonEmptyToday.id))
    browser.newTabActions.onReopenClosedTab(closedItem.id)
    XCTAssertNotNil(session.store.tab(id: nonEmptyToday.id), "非空 TODAY は復元でも掃除しない")
  }

  /// `BrowserInlineTextField` は編集中に `focusToken` が進んでも `onBlur` を誤発火せず
  /// 編集中テキストと IME を上書きしない。また祖先が非表示（`isHidden = true`）のときは
  /// `focusToken` が進んでもゴースト焦点を奪わない（対の可視時テスト付き）。
  func testInlineTextFieldTokenUpdateWhileEditingAndHiddenGhostFocusGuard() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    browser.setMode(.sheet, animated: false)
    browser.focusBrowser()

    let model = TokenProbeModel()
    var blurCount = 0
    let fieldHost = NSHostingView(
      rootView: TokenInlineFieldProbeView(model: model, onBlur: { blurCount += 1 }))
    fieldHost.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
    hosted.underlay.addSubview(fieldHost)
    fieldHost.layoutSubtreeIfNeeded()

    // 1. 対の肯定: 可視状態で focusToken を進めると flush + nextTurn 時点で焦点を取る。
    model.focusToken += 1
    flush(window)
    nextTurn()
    let editor = try XCTUnwrap(
      window.firstResponder as? NSTextView,
      "対の肯定: 可視時の focusToken 更新は flush + nextTurn で焦点を取る")
    XCTAssertTrue(editor.isDescendant(of: fieldHost))

    // 2. 編集中に外部モデル変更＋focusToken 連続更新が入っても onBlur 非発火・テキスト維持・全選択。
    replaceAll("editing-value", in: editor)
    model.text = "external-override"
    model.focusToken += 1
    flush(window)
    nextTurn()
    model.focusToken += 1
    flush(window)
    nextTurn()
    XCTAssertEqual(blurCount, 0, "編集中に focusToken が進んでも onBlur を誤発火しない")
    XCTAssertTrue(window.firstResponder === editor, "編集中 field editor の焦点を維持する")
    XCTAssertEqual(editor.string, "editing-value", "編集中テキストを外部値で上書きしない")
    XCTAssertEqual(editor.selectedRange().length, "editing-value".utf16.count, "全選択が適用される")

    // 3. 否定: 非表示（isHidden = true）のときは focusToken が進んでも焦点を奪わない。
    XCTAssertTrue(window.makeFirstResponder(browser))
    fieldHost.isHidden = true
    model.focusToken += 1
    flush(window)
    nextTurn()
    XCTAssertTrue(
      window.firstResponder === browser,
      "非表示フィールドの focusToken 更新では !isHiddenOrHasHiddenAncestor によりゴースト焦点を奪わない")
  }
}

@Observable private final class TokenProbeModel {
  var text = ""
  var focusToken = 0
}

private struct TokenInlineFieldProbeView: View {
  @Bindable var model: TokenProbeModel
  let onBlur: () -> Void

  var body: some View {
    BrowserInlineTextField(
      text: $model.text,
      placeholder: "probe",
      focusToken: model.focusToken,
      selectAllOnFocus: true,
      onCommit: { _ in true },
      onCancel: {},
      onBlur: onBlur)
  }
}
