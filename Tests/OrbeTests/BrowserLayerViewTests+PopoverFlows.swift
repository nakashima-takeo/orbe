import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ビュー内ポップオーバー（`BrowserSpacePopover`・`BrowserProfilePopover`）の画面内遷移・
/// フォーム破棄前退避（`onBeforeFormUnmount`）・入力検証・プロファイル作成非自動割当・
/// 削除付け替え安全化を実オフスクリーンウィンドウ経由で守る。
extension BrowserLayerViewTests {
  // MARK: - 自由スペースポップオーバー実操作

  /// 自由スペース編集フォームで空白名拒否・名前のみ変更（既存 WebView 非破棄）・
  /// プロファイル変更（再 materialize）・「スペースを削除…」実クリック（`onBeforeFormUnmount` 連鎖閉鎖なし）→
  /// 確認画面の「削除」実クリック削除までを通しで検証する。
  func testSpacePopoverEditValidationProfileSwapAndDeleteConfirmFlow() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    var focusDrops: [String] = []
    window.onFirstResponderChange = { responder in
      let focused = window.isKeyWindow && browser.focusIsInside
      browser.setFocused(focused)
      if !focused { focusDrops.append(String(describing: responder)) }
    }

    let server = try LocalLoopbackHTTPServer(routes: ["/s": "<title>S</title><p>s</p>"])
    defer { server.stop() }
    browser.setMode(.full, animated: false)
    browser.focusBrowser()
    placeOffscreen(window)
    let targetSpace = try XCTUnwrap(session.store.freeSpaces.first)
    XCTAssertTrue(session.selectSpace(.free(targetSpace.id)))
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    browser.load(server.url(for: "/s"))
    pumpMain(until: { finishes >= 1 }, timeout: 5, "スペース初期ページ読込")
    let initialRuntime = try XCTUnwrap(browser.mountedRuntime)

    try assertSpaceRenameAndProfileSwap(
      hosted: hosted, spaceId: targetSpace.id, initialRuntime: initialRuntime)

    // 編集フォーム→「スペースを削除…」実クリック（onBeforeFormUnmount）→連鎖閉鎖なし→「削除」実クリック。
    browser.sidebarActions.onOpenEditSpace(targetSpace.id, false)
    flush(window)
    _ = try waitPopoverEditor(in: hosted, "削除前の編集フォーム入力欄に焦点")
    focusDrops.removeAll()
    let formDoc = try popoverDocumentView(in: browser)
    clickWindowPoint(pointInDoc(formDoc, x: formDoc.bounds.midX, fromBottom: 24), in: window)

    XCTAssertEqual(browser.popoverState, .editSpace(targetSpace.id, confirmingDelete: true))
    XCTAssertFalse(browser.popoverHost.isHidden, "onBeforeFormUnmount で連鎖閉鎖しない")
    XCTAssertTrue(browser.isBrowserFocused)
    XCTAssertEqual(focusDrops, [], "OrbeWindow 再入ガードにより中間で NSWindow へ落ちない")

    let confirmDoc = try popoverDocumentView(in: browser)
    clickWindowPoint(
      pointInDoc(confirmDoc, x: confirmDoc.bounds.maxX - 32, fromBottom: 24), in: window)
    XCTAssertFalse(browser.isPopoverOpen, "確認画面の削除クリックで閉じる")
    XCTAssertNil(session.store.space(id: targetSpace.id), "自由スペースが削除される")
  }

  private func assertSpaceRenameAndProfileSwap(
    hosted: Hosted, spaceId: UUID, initialRuntime: BrowserTabRuntime
  ) throws {
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session

    // 空白名 Enter 拒否 → 有効名変更のみ（プロファイル不変）では既存 WebView ランタイムを破棄しない。
    browser.sidebarActions.onOpenEditSpace(spaceId, false)
    flush(window)
    let editEditor = try waitPopoverEditor(in: hosted, "自由スペース編集入力欄に焦点")
    replaceAll("   ", in: editEditor)
    deliverKeyDown(popoverKey("\r", keyCode: 36, in: window), to: window)
    XCTAssertEqual(browser.popoverState, .editSpace(spaceId, confirmingDelete: false), "空白名は拒否")

    replaceAll("改名スペース", in: editEditor)
    deliverKeyDown(popoverKey("\r", keyCode: 36, in: window), to: window)
    flush(window)
    XCTAssertFalse(browser.isPopoverOpen)
    XCTAssertEqual(session.store.space(id: spaceId)?.name, "改名スペース")
    XCTAssertTrue(browser.mountedRuntime === initialRuntime, "プロファイル未変更なら既存 WebView 非破棄")

    // 編集フォームで別プロファイルを選んで保存すると再 materialize される。
    let otherProfile = try XCTUnwrap(
      session.store.profiles.first { $0.id != session.store.space(id: spaceId)?.profileId })
    let otherIndex = try XCTUnwrap(session.store.profiles.firstIndex { $0.id == otherProfile.id })
    browser.sidebarActions.onOpenEditSpace(spaceId, false)
    flush(window)
    _ = try waitPopoverEditor(in: hosted, "プロファイル変更前の編集フォーム入力欄に焦点")
    let swapDoc = try popoverDocumentView(in: browser)
    let rowsFromBottom = CGFloat(session.store.profiles.count - 1 - otherIndex) * 30
    clickWindowPoint(
      pointInDoc(swapDoc, x: swapDoc.bounds.midX, fromBottom: 108 + rowsFromBottom), in: window)
    deliverKeyDown(popoverKey("\r", keyCode: 36, in: window), to: window)
    flush(window)
    XCTAssertEqual(session.store.space(id: spaceId)?.profileId, otherProfile.id)
    XCTAssertFalse(browser.mountedRuntime === initialRuntime, "プロファイル変更で再 materialize される")
  }

  // MARK: - プロファイルポップオーバー実操作

  /// 非公開プロファイル削除時の非公開候補優先付け替えと非公開→公開移行警告表示判定を守る。
  func testProfileDeleteReassignPrefersPrivateAndShowsMCPExposeWarning() {
    let now = Date()
    let pub = BrowserProfile(
      id: UUID(), name: "work", color: .blue, mcpAllowed: true, position: 0, createdAt: now)
    let privA = BrowserProfile(
      id: UUID(), name: "privA", color: .green, mcpAllowed: false, position: 1, createdAt: now)
    let privB = BrowserProfile(
      id: UUID(), name: "privB", color: .amber, mcpAllowed: false, position: 2, createdAt: now)

    XCTAssertEqual(
      BrowserProfilePopover.defaultReassignProfileId(for: privA, candidates: [pub, privB]),
      privB.id, "非公開プロファイル削除時は公開より非公開候補を既定付け替え先に選ぶ")
    XCTAssertEqual(
      BrowserProfilePopover.defaultReassignProfileId(for: privA, candidates: [pub]),
      pub.id, "他に非公開候補がない場合のみ公開先頭へフォールバック")
    XCTAssertEqual(
      BrowserProfilePopover.defaultReassignProfileId(for: pub, candidates: [privA, privB]),
      privA.id, "公開プロファイル削除時は候補先頭を選ぶ")

    let l10n = LocalizationStore(language: .ja)
    let warningHeight = deleteSectionHeight(
      target: privA, candidates: [pub], hasReferencingSpaces: true, localization: l10n)
    let noWarningNoRefHeight = deleteSectionHeight(
      target: privA, candidates: [pub], hasReferencingSpaces: false, localization: l10n)
    let noWarningPrivateHeight = deleteSectionHeight(
      target: privA, candidates: [privB], hasReferencingSpaces: true, localization: l10n)
    XCTAssertGreaterThan(
      warningHeight, noWarningPrivateHeight + 12,
      "非公開→公開付け替え時は MCP 公開範囲拡大警告が表示される")
    XCTAssertGreaterThan(warningHeight, noWarningNoRefHeight + 12)
  }

  /// プロファイルポップオーバー実画面で MCP トグル、フォーム戻る遷移（`onBeforeFormUnmount` 連鎖閉鎖なし）、
  /// 新規作成（非公開既定・空白名拒否・現在スペース非自動割当・既存 WebView 非破棄）、および
  /// 非公開プロファイルの削除確認→非公開候補付け替え削除を通しで検証する。
  func testProfilePopoverMCPToggleBackCreateNonAutoAssignAndPrivateDeleteFlow() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    window.onFirstResponderChange = { _ in
      browser.setFocused(window.isKeyWindow && browser.focusIsInside)
    }

    let server = try LocalLoopbackHTTPServer(routes: ["/p": "<title>P</title><p>p</p>"])
    defer { server.stop() }
    browser.setMode(.full, animated: false)
    browser.focusBrowser()
    placeOffscreen(window)
    var finishes = 0
    browser.onNavigationFinish = { finishes += 1 }
    browser.load(server.url(for: "/p"))
    pumpMain(until: { finishes >= 1 }, timeout: 5, "初期ページ読込")
    let runtimeBefore = try XCTUnwrap(browser.mountedRuntime)
    let activeProfileBefore = try XCTUnwrap(session.store.activeSpace?.profileId)

    browser.openPopover(.profile)
    flush(window)

    // メイン画面の MCP トグル行実クリックで現在プロファイルの mcpAllowed が反転する。
    let initialMCP = try XCTUnwrap(session.store.profile(id: activeProfileBefore)?.mcpAllowed)
    let toggleDoc = try popoverDocumentView(in: browser)
    clickWindowPoint(pointInDoc(toggleDoc, x: toggleDoc.bounds.midX, fromTop: 78), in: window)
    XCTAssertEqual(session.store.profile(id: activeProfileBefore)?.mcpAllowed, !initialMCP)
    clickWindowPoint(pointInDoc(toggleDoc, x: toggleDoc.bounds.midX, fromTop: 78), in: window)
    XCTAssertEqual(session.store.profile(id: activeProfileBefore)?.mcpAllowed, initialMCP)

    // 「新しいプロファイルを作成…」→ フォーム → 戻るクリックで連鎖閉鎖しない。
    let mainDoc = try popoverDocumentView(in: browser)
    clickWindowPoint(pointInDoc(mainDoc, x: mainDoc.bounds.midX, fromBottom: 20), in: window)
    _ = try waitPopoverEditor(in: hosted, "プロファイル作成フォーム入力欄に焦点")

    let backDoc = try popoverDocumentView(in: browser)
    clickWindowPoint(pointInDoc(backDoc, x: backDoc.bounds.minX + 24, fromTop: 24), in: window)
    XCTAssertEqual(browser.popoverState, .profile, "戻る操作の onBeforeFormUnmount で連鎖閉鎖しない")
    XCTAssertFalse(browser.popoverHost.isHidden)

    try assertProfileCreateAndPrivateDeleteFlow(
      hosted: hosted, activeProfileBefore: activeProfileBefore, runtimeBefore: runtimeBefore)
  }

  private func assertProfileCreateAndPrivateDeleteFlow(
    hosted: Hosted, activeProfileBefore: UUID, runtimeBefore: BrowserTabRuntime
  ) throws {
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    let mainDoc = try popoverDocumentView(in: browser)
    clickWindowPoint(pointInDoc(mainDoc, x: mainDoc.bounds.midX, fromBottom: 20), in: window)
    let editor = try waitPopoverEditor(in: hosted, "プロファイル新規作成入力欄に焦点")

    replaceAll("   ", in: editor)
    deliverKeyDown(popoverKey("\r", keyCode: 36, in: window), to: window)
    XCTAssertEqual(session.store.profiles.count, 2, "空白名ではプロファイルを作成しない")

    replaceAll("vault", in: editor)
    deliverKeyDown(popoverKey("\r", keyCode: 36, in: window), to: window)
    flush(window)
    XCTAssertEqual(browser.popoverState, .profile, "保存後はメイン画面へ戻り連鎖閉鎖しない")
    let vault = try XCTUnwrap(session.store.profiles.first { $0.name == "vault" })
    XCTAssertFalse(vault.mcpAllowed, "新規作成の既定は MCP 非公開")
    XCTAssertEqual(
      session.store.activeSpace?.profileId, activeProfileBefore,
      "新規プロファイル作成は現在スペースへ自動割当しない")
    XCTAssertTrue(browser.mountedRuntime === runtimeBefore, "自動割当しないため既存 WebView 非破棄")

    // vault（非公開）を割当て、他非公開（personal）がある状態で削除確認→削除すると非公開へ付け替えられる。
    let activeSpace = try XCTUnwrap(session.store.activeSpace)
    XCTAssertTrue(session.setSpaceProfile(activeSpace.id, profileId: vault.id))
    let personal = try XCTUnwrap(
      session.store.profiles.first { !$0.mcpAllowed && $0.id != vault.id })
    flush(window)
    let listDoc = try popoverDocumentView(in: browser)
    clickWindowPoint(pointInDoc(listDoc, x: listDoc.bounds.maxX - 22, fromBottom: 60), in: window)
    _ = try waitPopoverEditor(in: hosted, "vault 編集フォーム入力欄に焦点")

    let editDoc = try popoverDocumentView(in: browser)
    clickWindowPoint(pointInDoc(editDoc, x: editDoc.bounds.midX, fromBottom: 22), in: window)
    XCTAssertEqual(browser.popoverState, .profile, "削除確認遷移の onBeforeFormUnmount で連鎖閉鎖しない")
    XCTAssertFalse(browser.popoverHost.isHidden)

    let deleteDoc = try popoverDocumentView(in: browser)
    clickWindowPoint(
      pointInDoc(deleteDoc, x: deleteDoc.bounds.maxX - 32, fromBottom: 24), in: window)
    XCTAssertNil(session.store.profile(id: vault.id), "削除確定で vault プロファイルが消える")
    XCTAssertEqual(
      session.store.space(id: activeSpace.id)?.profileId, personal.id,
      "非公開プロファイル削除時の既定付け替え先は公開ではなく非公開プロファイルが選ばれる")
  }

  // MARK: - 補助

  private func deleteSectionHeight(
    target: BrowserProfile, candidates: [BrowserProfile],
    hasReferencingSpaces: Bool, localization: LocalizationStore
  ) -> CGFloat {
    var reassign: UUID? = candidates.first?.id
    let binding = Binding<UUID?>(get: { reassign }, set: { reassign = $0 })
    let host = NSHostingView(
      rootView: BrowserProfileDeleteSection(
        target: target, candidates: candidates, hasReferencingSpaces: hasReferencingSpaces,
        reassignProfileId: binding, localization: localization,
        onBack: {}, onCancel: {}, onDelete: { _ in }
      )
      .frame(width: Theme.Layout.browserPopoverProfileWidth)
      .environment(\.chromeFontResolver, ChromeFontResolver()))
    return host.fittingSize.height
  }

  private func waitPopoverEditor(in hosted: Hosted, _ label: String) throws -> NSTextView {
    let (window, browser) = (hosted.window, hosted.browser)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.popoverHost) == true
      }, label)
    return try XCTUnwrap(window.firstResponder as? NSTextView)
  }

  private func popoverDocumentView(in browser: BrowserLayerView) throws -> NSView {
    let sv = try XCTUnwrap(firstScrollView(in: browser.popoverHost), "ポップオーバー内の単一 ScrollView")
    return try XCTUnwrap(sv.documentView, "ScrollView の documentView")
  }

  private func pointInDoc(_ docView: NSView, x: CGFloat, fromTop offset: CGFloat) -> NSPoint {
    let y = docView.isFlipped ? docView.bounds.minY + offset : docView.bounds.maxY - offset
    return docView.convert(NSPoint(x: x, y: y), to: nil)
  }

  private func pointInDoc(_ docView: NSView, x: CGFloat, fromBottom offset: CGFloat) -> NSPoint {
    let y = docView.isFlipped ? docView.bounds.maxY - offset : docView.bounds.minY + offset
    return docView.convert(NSPoint(x: x, y: y), to: nil)
  }

  private func popoverKey(
    _ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: chars, charactersIgnoringModifiers: chars,
      isARepeat: false, keyCode: keyCode)!
  }
}
