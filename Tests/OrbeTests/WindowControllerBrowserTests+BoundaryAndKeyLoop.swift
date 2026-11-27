import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 実窓 `OrbeWindow` / `WindowController` における Z=2 キービュー循環封じ込め（`Tab` / `Shift+Tab`）、
/// URL 編集中 `⌘R` 再読込抑止の実窓検証、および単一降下ゲート経由 `availableWithoutTabs` 6 コマンドの
/// 転送・抑止を E2E で守る。
extension WindowControllerBrowserTests {
  func keyEvent(
    _ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: chars, charactersIgnoringModifiers: chars,
      isARepeat: false, keyCode: keyCode)!
  }

  func waitEditor(in host: NSView, window: NSWindow, _ label: String) throws -> NSTextView {
    flush(window)
    pumpMain(
      until: { (window.firstResponder as? NSTextView)?.isDescendant(of: host) == true }, label)
    return try XCTUnwrap(window.firstResponder as? NSTextView)
  }

  func markComposing(_ editor: NSTextView, _ text: String = "へんかん") {
    editor.setMarkedText(
      text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText(), "前提: IME 変換中")
  }

  // MARK: - 実窓 OrbeWindow のキービュー循環封じ込め

  /// `autorecalculatesKeyViewLoop == true` の実窓 `OrbeWindow` で、全面ブラウザ（遷移済み WebView・
  /// 空画面・URL 編集中・新タブ入力中）およびポップオーバー表示中（メイン画面・フォーム入力中）から
  /// `Tab` / `Shift+Tab`（`selectNextKeyView` / `selectPreviousKeyView` / `selectKeyView(following:/preceding:)`
  /// および実キー配送）を行っても、キービュー循環が Z=2 やポップオーバーを脱出して背後へ漏洩しない。
  @MainActor
  func testKeyViewLoopContainmentBlocksEscapeFromBrowserAndPopoverToUnderlay() throws {
    let dir = TestScratch.caseDir.appendingPathComponent("keyloop-doc", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let docURL = try caseFile("keyloop-doc/note.txt", "body")
    let server = try LocalLoopbackHTTPServer(routes: [
      "/page": "<!doctype html><title>P</title><input id='i' value='ok'>"
    ])
    defer { server.stop() }

    let window = OrbeWindowFake()
    window.autorecalculatesKeyViewLoop = true
    let wc = try restore(
      [
        WorkspaceState(
          name: "main", rootPath: dir.path, activeTab: 0,
          tabs: [TabState(cwd: dir.path, agent: nil, explicitTitle: nil)])
      ], window: window)
    window.isKey = true
    let tab = try XCTUnwrap(wc.activeTab)
    _ = try tab.group.editor.open(docURL, as: .pinned)
    wc.toggleEditorFace()
    layout(wc)

    // 1. 対の確認: 右シート非焦点（下層エディターに焦点）時は封じ込め境界が nil。
    wc.setBrowserMode(.sheet, animated: false)
    tab.group.view.editor.focusEditor()
    XCTAssertFalse(wc.browserView.focusIsInside)
    XCTAssertNil(window.keyViewContainmentBoundary?(), "非焦点時は下層キービュー循環を遮らない")

    // 2. 全面ブラウザ遷移済み WebView: 境界は webView 固定で Tab / Shift+Tab が背後へ抜けない。
    wc.setBrowserMode(.full, animated: false)
    var finishes = 0
    wc.browserView.onNavigationFinish = { finishes += 1 }
    wc.browserView.load(server.url(for: "/page"))
    pumpMain(until: { finishes >= 1 }, timeout: 5, "キービュー循環テスト用ページ読込")
    let webView = try XCTUnwrap(wc.browserView.webView)
    wc.browserView.focusBrowser()
    layout(wc)
    XCTAssertTrue(window.keyViewContainmentBoundary?() === webView)
    assertKeyViewStaysInside(webView, in: window, label: "遷移済み WebView")

    // 3. ツールバー URL 編集中・新タブ入力欄編集中・空画面: 境界は browserView で背後端末・エディターへ漏れない。
    try assertEditingAndPopoverKeyLoopContainment(in: wc, window: window)
  }

  @MainActor
  private func assertEditingAndPopoverKeyLoopContainment(
    in wc: WindowController, window: OrbeWindow
  ) throws {
    wc.browserView.beginURLEditing()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: wc.browserView.barHost) == true
      }, "ツールバー URL 欄に焦点")
    XCTAssertTrue(window.keyViewContainmentBoundary?() === wc.browserView)
    assertKeyViewStaysInside(wc.browserView, in: window, label: "ツールバー URL 編集中")
    wc.browserView.cancelURLEditing()

    wc.browserView.openNewTab()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: wc.browserView.newTabHost) == true
      }, "新タブ入力欄に焦点")
    XCTAssertTrue(window.keyViewContainmentBoundary?() === wc.browserView)
    assertKeyViewStaysInside(wc.browserView, in: window, label: "新タブ入力欄編集中")

    // ポップオーバー表示中（フォーム入力中含む）: 境界は popoverHost で背面ツールバー・WebView・下層へ漏れない。
    wc.browserView.openPopover(.createSpace)
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: wc.browserView.popoverHost) == true
      }, "ポップオーバーフォーム入力欄に焦点")
    XCTAssertTrue(window.keyViewContainmentBoundary?() === wc.browserView.popoverHost)
    assertKeyViewStaysInside(wc.browserView.popoverHost, in: window, label: "ポップオーバーフォーム編集中")

    wc.browserView.openPopover(.profile)
    flush(window)
    XCTAssertTrue(window.keyViewContainmentBoundary?() === wc.browserView.popoverHost)
    assertKeyViewStaysInside(wc.browserView, in: window, label: "ポップオーバーメイン画面")
    XCTAssertFalse(
      (window.firstResponder as? NSView)?.isDescendant(of: wc.model.content) == true,
      "ポップオーバーメイン画面の Tab で下層へ漏洩しない")
  }

  @MainActor
  private func assertKeyViewStaysInside(_ boundary: NSView, in window: OrbeWindow, label: String) {
    let tab = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
      isARepeat: false, keyCode: 48)!
    let backtab = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.shift],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\u{19}", charactersIgnoringModifiers: "\u{19}",
      isARepeat: false, keyCode: 48)!

    for _ in 0..<3 {
      window.selectNextKeyView(nil)
      assertResponderInside(boundary, in: window, label: "\(label) selectNextKeyView")
      window.selectPreviousKeyView(nil)
      assertResponderInside(boundary, in: window, label: "\(label) selectPreviousKeyView")
      if let view = window.firstResponder as? NSView {
        window.selectKeyView(following: view)
        assertResponderInside(boundary, in: window, label: "\(label) selectKeyView(following:)")
        window.selectKeyView(preceding: view)
        assertResponderInside(boundary, in: window, label: "\(label) selectKeyView(preceding:)")
      }
      deliverKeyDown(tab, to: window)
      assertResponderInside(boundary, in: window, label: "\(label) Tab")
      deliverKeyDown(backtab, to: window)
      assertResponderInside(boundary, in: window, label: "\(label) Shift+Tab")
    }
  }

  @MainActor
  private func assertResponderInside(_ boundary: NSView, in window: OrbeWindow, label: String) {
    guard let responder = window.firstResponder as? NSView else {
      return XCTFail("\(label): firstResponder が NSView のまま境界内に留まる")
    }
    XCTAssertTrue(
      responder === boundary || responder.isDescendant(of: boundary),
      "\(label): firstResponder(\(type(of: responder))) が境界(\(type(of: boundary)))の外へ漏洩した")
  }

  // MARK: - 実窓 URL 編集中 ⌘R 抑止・availableWithoutTabs 単一降下ゲート

  /// 実窓経路で URL 編集中（ツールバー／新タブ）の `⌘R` は同期で再読込を開始せず（対の通常時は
  /// `isProvisionalNavigation == true`）、単一降下ゲート経由の `availableWithoutTabs` 6 コマンドは
  /// ブラウザ通常焦点時のみ起動し、URL 編集中・ポップオーバー中は抑止される。
  @MainActor
  func testWindowCommandRSuppressionAndAvailableWithoutTabsGate() throws {
    let server = try LocalLoopbackHTTPServer(responses: [
      "/r": .sequence([
        .html("<!doctype html><title>R1</title><p>1</p>"),
        .html("<!doctype html><title>R2</title><p>2</p>"),
      ])
    ])
    defer { server.stop() }
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain])],
      window: window)
    window.isKey = true
    wc.setBrowserMode(.sheet, animated: false)

    var finishes = 0
    wc.browserView.onNavigationFinish = { finishes += 1 }
    wc.browserView.load(server.url(for: "/r"))
    pumpMain(until: { finishes >= 1 && wc.browserView.webView?.title == "R1" }, timeout: 5, "R1 完了")

    // 対の肯定: 通常時 ⌘R は同期で isProvisionalNavigation == true になり R2 へ遷移。
    wc.browserView.focusBrowser()
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("r")))
    XCTAssertTrue(wc.browserView.isProvisionalNavigation, "通常時 ⌘R は同期で再読込を開始する")
    pumpMain(until: { finishes >= 2 && wc.browserView.webView?.title == "R2" }, timeout: 5, "R2 完了")

    // 否定: ツールバー URL 編集中および新タブ入力欄編集中の ⌘R は同期で再読込を抑止する。
    wc.browserView.beginURLEditing()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: wc.browserView.barHost) == true
      }, "ツールバー URL 欄に焦点")
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("r")))
    XCTAssertFalse(wc.browserView.isProvisionalNavigation, "ツールバー URL 編集中は ⌘R 再読込を抑止")
    XCTAssertEqual(wc.browserView.webView?.title, "R2")
    XCTAssertNil(wc.statusModel.editingIndex)
    wc.browserView.cancelURLEditing()

    // 新タブ入力欄編集中も ⌘R 再読込・タブ改名を抑止する。
    wc.browserView.openNewTab()
    _ = try waitEditor(in: wc.browserView.newTabHost, window: window, "新タブ入力欄に焦点")
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("r")))
    XCTAssertFalse(wc.browserView.isProvisionalNavigation, "新タブ入力欄編集中も ⌘R 再読込を抑止")
    XCTAssertNil(wc.statusModel.editingIndex)
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("w")))

    // availableWithoutTabs 6 コマンド: 通常焦点時は全 6 オーバーレイを起動し、URL 編集中・ポップオーバー中は抑止。
    try assertAvailableWithoutTabsSixCommands(in: wc, window: window)
  }

  @MainActor
  private func assertAvailableWithoutTabsSixCommands(
    in wc: WindowController, window: OrbeWindow
  ) throws {
    struct PaletteCase {
      let event: NSEvent
      let overlay: AppShellModel.Overlay
      let label: String
    }
    let cases: [PaletteCase] = [
      PaletteCase(event: .key("S", [.command, .shift]), overlay: .workspacePalette, label: "⌘⇧S"),
      PaletteCase(event: .key("C", [.command, .shift]), overlay: .agentPalette, label: "⌘⇧C"),
      PaletteCase(event: .key("A", [.command, .shift]), overlay: .agentPalette, label: "⌘⇧A"),
      PaletteCase(event: .key("X", [.command, .shift]), overlay: .taskPalette, label: "⌘⇧X"),
      PaletteCase(event: .key(","), overlay: .settingsPalette, label: "⌘,"),
      PaletteCase(event: .key("h"), overlay: .help, label: "⌘H"),
    ]

    for item in cases {
      wc.browserView.focusBrowser()
      XCTAssertTrue(
        wc.window.performKeyEquivalent(with: item.event), "\(item.label): ブラウザ焦点時は消費転送")
      XCTAssertEqual(wc.presentedOverlay, item.overlay, "\(item.label): 対象オーバーレイが起動する")
      wc.dismissPalette()
      nextTurn()
    }

    // URL 編集中（ツールバー）は 6 キーとも抑止され overlay == .none のまま。
    wc.browserView.beginURLEditing()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: wc.browserView.barHost) == true
      }, "URL 欄編集中")
    for item in cases {
      XCTAssertTrue(
        wc.window.performKeyEquivalent(with: item.event), "\(item.label): URL 編集中は抑止消費")
      XCTAssertEqual(wc.presentedOverlay, .none, "\(item.label): URL 編集中はパレットを起動しない")
    }
    wc.browserView.cancelURLEditing()

    // ポップオーバー表示中も 6 キーとも抑止され overlay == .none のまま。
    wc.browserView.openPopover(.profile)
    for item in cases {
      XCTAssertTrue(
        wc.window.performKeyEquivalent(with: item.event), "\(item.label): ポップオーバー中は抑止消費")
      XCTAssertEqual(wc.presentedOverlay, .none, "\(item.label): ポップオーバー中はパレットを起動しない")
    }
    wc.browserView.closePopover()
  }
}
