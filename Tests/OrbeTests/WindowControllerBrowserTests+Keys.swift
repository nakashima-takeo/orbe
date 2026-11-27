import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 実窓 `WindowController`（`ChromeHostingView` → `handleWindowKeyCommand` 単一降下ゲート →
/// `BrowserLayerView.performKeyEquivalent`）を通したブラウザ焦点中の `⌘T / ⌘W / ⌘R / ⌘⇧T / ⌘S`、
/// URL 入力中・ポップオーバー中・日本語 IME 変換中の保護、および端末・エディター・ボード焦点中の
/// 従来動作非破壊を E2E で守る。
///
/// 壊れると何が起きるか。ブラウザ操作中に `⌘T` で worktree パレットが開く、`⌘W` で背後の端末タブや
/// ピン留めタブが消える、`⌘R` で端末タブ改名が始まる、`⌘⇧T` で閉じたエージェントパレットが開く、
/// `⌘S` で背後のエディターが保存される。逆に日本語変換中の `⌘B` でブラウザが閉じて変換が失われる、
/// あるいは端末・エディター・ボードの従来ショートカットが右シート開中に壊れる。
extension WindowControllerBrowserTests {
  private func keyEvent(
    _ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: chars, charactersIgnoringModifiers: chars,
      isARepeat: false, keyCode: keyCode)!
  }

  private func waitEditor(in host: NSView, window: NSWindow, _ label: String) throws -> NSTextView {
    flush(window)
    pumpMain(
      until: { (window.firstResponder as? NSTextView)?.isDescendant(of: host) == true }, label)
    return try XCTUnwrap(window.firstResponder as? NSTextView)
  }

  private func markComposing(_ editor: NSTextView, _ text: String = "へんかん") {
    editor.setMarkedText(
      text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText(), "前提: IME 変換中")
  }

  // MARK: - ブラウザ焦点中（通常）の 5 キー E2E

  /// ブラウザ焦点中は `⌘T`（新タブ）・`⌘W`（`TODAY` のみ閉鎖）・`⌘R`（再読込）・`⌘⇧T`（閉じたタブ復元）・
  /// `⌘S`（サイドバー開閉）が実窓経路でブラウザ操作として動き、端末タブ・タブ改名・パレット・下層エディターを汚さない。
  @MainActor
  func testBrowserFocusedShortcutsExecuteBrowserActionsWithoutTouchingUnderlay() throws {
    let dir = TestScratch.caseDir.appendingPathComponent("editor-doc", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let docURL = try caseFile("editor-doc/note.txt", "original")
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(
          name: "main", rootPath: dir.path, activeTab: 0,
          tabs: [TabState(cwd: dir.path, agent: nil, explicitTitle: nil)])
      ], window: window)
    window.isKey = true

    let termTab = try XCTUnwrap(wc.activeTab)
    let doc = try termTab.group.editor.open(docURL, as: .pinned)
    doc.surface.responder.perform(#selector(NSResponder.insertText(_:)), with: "dirty-")
    XCTAssertTrue(doc.isDirty, "前提: 下層エディターに未保存変更あり")
    wc.toggleEditorFace()

    let server = try LocalLoopbackHTTPServer(responses: [
      "/reload": .sequence([
        .html("<!doctype html><title>V1</title><p>v1</p>"),
        .html("<!doctype html><title>V2</title><p>v2</p>"),
      ])
    ])
    defer { server.stop() }
    let reloadURL = server.url(for: "/reload")

    let freeSpace = try XCTUnwrap(wc.browserSession.store.freeSpaces.first)
    XCTAssertTrue(wc.browserSession.selectSpace(.free(freeSpace.id)))
    let favTab = try XCTUnwrap(
      wc.browserSession.openTab(
        in: freeSpace.id, section: .favorite, url: reloadURL, title: "Fav", activate: false))
    let pinnedTab = try XCTUnwrap(
      wc.browserSession.openTab(
        in: freeSpace.id, section: .pinned, url: reloadURL, title: "Pin", activate: false))

    wc.setBrowserMode(.sheet, animated: false)
    let termCountBefore = wc.current.tabs.count

    let createdTab = try assertNewTabReloadAndSidebarShortcuts(
      in: wc, reloadURL: reloadURL, isDocDirty: { doc.isDirty }, docURL: docURL,
      termCountBefore: termCountBefore)
    assertCloseAndReopenShortcuts(
      in: wc, createdTabId: createdTab.id, protectedIds: [pinnedTab.id, favTab.id],
      expectedReopenURL: reloadURL, termCountBefore: termCountBefore)
  }

  @MainActor
  private func assertNewTabReloadAndSidebarShortcuts(
    in wc: WindowController, reloadURL: URL, isDocDirty: () -> Bool, docURL: URL,
    termCountBefore: Int
  ) throws -> BrowserTab {
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("t")))
    XCTAssertEqual(wc.presentedOverlay, .none)
    XCTAssertEqual(wc.current.tabs.count, termCountBefore)
    let createdTab = try XCTUnwrap(wc.browserSession.store.activeTab)
    XCTAssertEqual(createdTab.section, .today)

    var finishes = 0
    wc.browserView.onNavigationFinish = { finishes += 1 }
    wc.browserView.load(reloadURL)
    pumpMain(
      until: { finishes >= 1 && wc.browserView.webView?.title == "V1" },
      timeout: 5, "初回ページ読み込み完了")
    XCTAssertEqual(wc.browserView.webView?.title, "V1")
    wc.browserView.focusBrowser()
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("r")))
    pumpMain(
      until: { finishes >= 2 && wc.browserView.webView?.title == "V2" },
      timeout: 5, "⌘R でページ再読込完了")
    XCTAssertEqual(wc.browserView.webView?.title, "V2")
    XCTAssertNil(wc.statusModel.editingIndex, "端末タブ改名は始まらない")

    XCTAssertFalse(wc.browserView.isSidebarOpen)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("s")))
    XCTAssertTrue(wc.browserView.isSidebarOpen)
    XCTAssertTrue(isDocDirty(), "ブラウザ焦点中の ⌘S で下層エディターを保存しない")
    XCTAssertEqual(try String(contentsOf: docURL, encoding: .utf8), "original")
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("s")))
    XCTAssertFalse(wc.browserView.isSidebarOpen)
    return createdTab
  }

  @MainActor
  private func assertCloseAndReopenShortcuts(
    in wc: WindowController, createdTabId: UUID, protectedIds: [UUID],
    expectedReopenURL: URL, termCountBefore: Int
  ) {
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("w")))
    XCTAssertNil(wc.browserSession.store.tab(id: createdTabId), "TODAY タブが閉じる")
    XCTAssertEqual(wc.current.tabs.count, termCountBefore, "端末タブは閉じない")

    for protectedId in protectedIds {
      XCTAssertTrue(wc.browserSession.selectTab(protectedId))
      wc.browserView.focusBrowser()
      XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("w")))
      XCTAssertNotNil(
        wc.browserSession.store.tab(id: protectedId), "PINNED / Favorites は ⌘W で閉じない")
    }
    XCTAssertEqual(wc.browserMode, .sheet, "⌘W でブラウザ層自体は閉じない")

    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("T", [.command, .shift])))
    XCTAssertEqual(wc.presentedOverlay, .none, "閉じたエージェントパレットは開かない")
    XCTAssertEqual(
      wc.browserSession.store.activeTab?.url, expectedReopenURL, "閉じたブラウザタブが復元される")
  }

  // MARK: - URL 入力欄編集中（ツールバー／新タブ）・ポップオーバー表示中

  /// ツールバー URL 欄・新タブ URL 欄の編集中は `⌘T / ⌘W / ⌘⇧T / ⌘S` がブラウザ操作として働き
  /// （`⌘S` はツールバー URL 編集維持）、`⌘R` と下層窓コマンドは抑止される。
  /// ポップオーバー表示中は `⌘B` 以外を抑止し、`Esc` でポップオーバー閉鎖＋`focusBrowser()` する。
  @MainActor
  func testBrowserShortcutsInURLEditingAndPopoverRespectProtectionRules() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain])],
      window: window)
    window.isKey = true
    wc.setBrowserMode(.sheet, animated: false)
    let pageURL = URL(string: "https://docs.orbe.dev/edit")!
    let tab1 = try XCTUnwrap(wc.browserSession.openTab(section: .today, url: pageURL))

    try assertToolbarAndNewTabURLEditingShortcuts(
      in: wc, window: window, tabId: tab1.id, pageURL: pageURL)
    assertPopoverShortcutGuards(in: wc, window: window)
  }

  @MainActor
  private func assertToolbarAndNewTabURLEditingShortcuts(
    in wc: WindowController, window: NSWindow, tabId: UUID, pageURL: URL
  ) throws {
    wc.browserView.beginURLEditing()
    _ = try waitEditor(in: wc.browserView.barHost, window: window, "ツールバー URL 欄に焦点")
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("s")))
    XCTAssertTrue(wc.browserView.isSidebarOpen)
    XCTAssertTrue(wc.browserView.isEditingURL, "⌘S はツールバー URL 編集を維持する")
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("s")))
    XCTAssertFalse(wc.browserView.isSidebarOpen)

    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("r")))
    XCTAssertNil(wc.statusModel.editingIndex, "URL 編集中は ⌘R を抑止")
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("e")))
    XCTAssertFalse(try XCTUnwrap(wc.activeTab).group.view.isEditorOpen, "URL 編集中は ⌘E を抑止")

    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("w")))
    XCTAssertNil(wc.browserSession.store.tab(id: tabId), "URL 編集中も ⌘W で TODAY タブを閉じる")
    XCTAssertFalse(wc.browserView.isEditingURL)

    wc.browserView.beginURLEditing()
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("T", [.command, .shift])))
    XCTAssertEqual(wc.browserSession.store.activeTab?.url, pageURL, "URL 編集中も ⌘⇧T で復元")
    XCTAssertEqual(wc.presentedOverlay, .none)

    wc.browserView.openNewTab()
    _ = try waitEditor(in: wc.browserView.newTabHost, window: window, "新タブ入力欄に焦点")
    let newTabId = try XCTUnwrap(wc.browserSession.store.activeTab?.id)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("r")))
    XCTAssertNil(wc.statusModel.editingIndex)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("e")))
    XCTAssertFalse(try XCTUnwrap(wc.activeTab).group.view.isEditorOpen)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("w")))
    XCTAssertNil(wc.browserSession.store.tab(id: newTabId), "新タブ入力欄編集中も ⌘W で空 TODAY を閉じる")
  }

  @MainActor
  private func assertPopoverShortcutGuards(in wc: WindowController, window: NSWindow) {
    let tabsBeforePopover = wc.browserSession.store.tabs.count
    wc.browserView.openPopover(.profile)
    for event in [
      NSEvent.key("t"), .key("w"), .key("r"), .key("T", [.command, .shift]),
      .key("s"), .key("e"),
    ] {
      XCTAssertTrue(wc.window.performKeyEquivalent(with: event))
    }
    XCTAssertTrue(wc.browserView.isPopoverOpen, "ポップオーバー表示中は ⌘B 以外で閉じない")
    XCTAssertEqual(wc.browserSession.store.tabs.count, tabsBeforePopover)
    XCTAssertEqual(wc.presentedOverlay, .none)
    XCTAssertFalse(wc.browserView.isSidebarOpen)

    XCTAssertTrue(wc.window.performKeyEquivalent(with: keyEvent("\u{1B}", keyCode: 53, in: window)))
    XCTAssertFalse(wc.browserView.isPopoverOpen, "Esc でポップオーバーが閉じる")
    XCTAssertTrue(wc.browserView.focusIsInside)

    wc.browserView.openPopover(.profile)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("b")))
    XCTAssertFalse(wc.browserView.isPopoverOpen)
    XCTAssertEqual(wc.browserMode, .closed, "ポップオーバー表示中の ⌘B はブラウザごと閉じる")
  }

  // MARK: - 日本語 IME 変換中（hasMarkedText）保護

  /// ツールバー URL 欄・新タブ URL 欄・ポップオーバー内フォームで日本語 IME 変換中（`hasMarkedText`）は、
  /// `⌘B` を含む全ショートカットが IME へ素通し（`false`）され、ブラウザもポップオーバーも閉じない。
  @MainActor
  func testIMECompositionInBrowserPassesThroughAllShortcutsIncludingCommandB() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain])],
      window: window)
    window.isKey = true
    wc.setBrowserMode(.sheet, animated: false)

    wc.browserView.beginURLEditing()
    assertIMEPassthrough(
      "ツールバー URL 欄", in: wc, window: window,
      editor: try waitEditor(in: wc.browserView.barHost, window: window, "ツールバー URL 欄に焦点"))
    wc.browserView.cancelURLEditing()

    wc.browserView.openNewTab()
    assertIMEPassthrough(
      "新タブ入力欄", in: wc, window: window,
      editor: try waitEditor(in: wc.browserView.newTabHost, window: window, "新タブ入力欄に焦点"))

    wc.browserView.openPopover(.createSpace)
    assertIMEPassthrough(
      "ポップオーバー内フォーム", in: wc, window: window,
      editor: try waitEditor(in: wc.browserView.popoverHost, window: window, "フォーム入力欄に焦点"))
  }

  @MainActor
  private func assertIMEPassthrough(
    _ label: String, in wc: WindowController, window: NSWindow, editor: NSTextView
  ) {
    let tabsBefore = wc.browserSession.store.tabs.count
    let sidebarBefore = wc.browserView.isSidebarOpen
    let popoverBefore = wc.browserView.isPopoverOpen
    markComposing(editor)
    for event in [
      NSEvent.key("b"), .key("t"), .key("w"), .key("s"),
      keyEvent("\u{1B}", keyCode: 53, in: window),
    ] {
      XCTAssertFalse(
        wc.window.performKeyEquivalent(with: event),
        "\(label): IME 変換中は \(event.charactersIgnoringModifiers ?? "") を IME へ素通しする")
    }
    XCTAssertEqual(wc.browserMode, .sheet, "\(label): IME 変換中の ⌘B でブラウザが閉じない")
    XCTAssertEqual(wc.browserSession.store.tabs.count, tabsBefore, "\(label): タブが増減しない")
    XCTAssertEqual(wc.browserView.isSidebarOpen, sidebarBefore, "\(label): サイドバーが動かない")
    XCTAssertEqual(wc.browserView.isPopoverOpen, popoverBefore, "\(label): ポップオーバーが閉じない")
    XCTAssertEqual(wc.presentedOverlay, .none, "\(label): 下層パレットも開かない")
    editor.unmarkText()
  }

  // MARK: - 端末・エディター・ボード焦点中の従来動作非破壊（右シート開・非焦点）

  /// 右シートが開いていても焦点が端末・エディター・ボードにある間は、`⌘T / ⌘W / ⌘R / ⌘⇧T / ⌘S` が
  /// すべて従来の Orbe 動作のまま動き、ブラウザのタブ・履歴・サイドバーへ一切干渉しない。
  @MainActor
  func testUnderlayFocusPreservesTerminalEditorAndBoardShortcutsWhileSheetIsOpen() throws {
    let dir = TestScratch.caseDir.appendingPathComponent("underlay-doc", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let docURL = try caseFile("underlay-doc/saved.txt", "before")
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(
          name: "main", rootPath: dir.path, activeTab: 0,
          tabs: [
            TabState(cwd: dir.path, agent: nil, explicitTitle: nil),
            TabState(cwd: dir.path, agent: nil, explicitTitle: nil),
          ])
      ], window: window)
    window.isKey = true

    wc.setBrowserMode(.sheet, animated: false)
    let browserTab = try XCTUnwrap(
      wc.browserSession.openTab(section: .today, url: URL(string: "https://docs.orbe.dev/keep")!))
    let closedSeed = try XCTUnwrap(
      wc.browserSession.openTab(
        section: .today, url: URL(string: "https://docs.orbe.dev/old")!, activate: false))
    XCTAssertTrue(wc.browserSession.closeTab(closedSeed.id, recordClosed: true))
    let browserTabCount = wc.browserSession.store.tabs.count
    let closedHistoryCount = wc.browserSession.store.closedTabs.count

    assertTerminalShortcutsPreserved(in: wc, window: window, browserTabId: browserTab.id)
    try assertEditorAndBoardShortcutsPreserved(in: wc, docURL: docURL)

    XCTAssertEqual(wc.browserSession.store.tabs.count, browserTabCount, "ブラウザタブ数は一貫して不変")
    XCTAssertEqual(
      wc.browserSession.store.closedTabs.count, closedHistoryCount, "ブラウザ閉じた履歴も不変")
    XCTAssertFalse(wc.browserView.isSidebarOpen, "ブラウザサイドバーも一貫して不変")
  }

  @MainActor
  private func assertTerminalShortcutsPreserved(
    in wc: WindowController, window: NSWindow, browserTabId: UUID
  ) {
    let tab0 = wc.current.tabs[0]
    window.makeFirstResponder(tab0.surface)
    XCTAssertFalse(wc.browserView.focusIsInside)

    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("t")))
    XCTAssertEqual(wc.presentedOverlay, .worktreePalette, "端末焦点中の ⌘T は worktree パレットを開く")
    wc.dismissPalette()

    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("T", [.command, .shift])))
    XCTAssertEqual(
      wc.presentedOverlay, .closedAgentsPalette, "端末焦点中の ⌘⇧T は閉じたエージェントパレットを開く")
    wc.dismissPalette()

    window.makeFirstResponder(tab0.surface)
    XCTAssertFalse(wc.window.performKeyEquivalent(with: .key("s")), "端末焦点中の ⌘S はブラウザが奪わない")
    XCTAssertFalse(wc.browserView.isSidebarOpen)

    XCTAssertFalse(wc.window.performKeyEquivalent(with: .key("r")), "端末焦点中の ⌘R はブラウザが奪わない")
    deliverKeyDown(.key("r"), to: window)
    XCTAssertEqual(wc.statusModel.editingIndex, 0, "端末焦点中の ⌘R はタブ改名を開始する")
    wc.statusModel.onCancelRename()

    window.makeFirstResponder(tab0.surface)
    XCTAssertFalse(wc.window.performKeyEquivalent(with: .key("w")), "端末焦点中の ⌘W はブラウザが奪わない")
    deliverKeyDown(.key("w"), to: window)
    pumpMain(until: { wc.current.tabs.count == 1 }, "端末焦点中の ⌘W は端末タブを閉じる")
    XCTAssertNotNil(wc.browserSession.store.tab(id: browserTabId), "ブラウザの TODAY タブは無傷")
  }

  @MainActor
  private func assertEditorAndBoardShortcutsPreserved(
    in wc: WindowController, docURL: URL
  ) throws {
    let remainingTab = try XCTUnwrap(wc.activeTab)
    let doc = try remainingTab.group.editor.open(docURL, as: .pinned)
    doc.surface.responder.perform(#selector(NSResponder.insertText(_:)), with: "!")
    wc.toggleEditorFace()
    XCTAssertEqual(wc.browserMode, .sheet, "前提: 右シートは開いたまま")
    XCTAssertTrue(remainingTab.group.view.editor.focusIsInside)

    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("s")))
    XCTAssertFalse(doc.isDirty, "エディター焦点中の ⌘S は文書を保存する")
    XCTAssertEqual(try String(contentsOf: docURL, encoding: .utf8), "!before")
    XCTAssertFalse(wc.browserView.isSidebarOpen, "エディター焦点中の ⌘S でサイドバーを開閉しない")

    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("t")))
    XCTAssertEqual(wc.presentedOverlay, .worktreePalette)
    wc.dismissPalette()
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("r")))
    XCTAssertNotNil(wc.statusModel.editingIndex, "エディター焦点中の ⌘R はタブ改名を開始する")
    wc.statusModel.onCancelRename()

    wc.select(.board, inWorkspaceAt: try XCTUnwrap(wc.store.homeIndex))
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertTrue(wc.boardView.focusIsInside)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("t")))
    XCTAssertEqual(wc.presentedOverlay, .worktreePalette)
    wc.dismissPalette()
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("T", [.command, .shift])))
    XCTAssertEqual(wc.presentedOverlay, .closedAgentsPalette)
    wc.dismissPalette()
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("s")))
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("w")))
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("r")))
  }
}
