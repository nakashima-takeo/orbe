import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// `BrowserLayerView` の左端ドラッグハンドル・キー分類・本物の `BrowserURLTextField`（`NSTextField` /
/// `Coordinator`＋IME）経由の URL インライン編集を守る。
extension BrowserLayerViewTests {
  private func mouse(_ type: NSEvent.EventType, x: CGFloat, in hosted: Hosted, clickCount: Int = 1)
    -> NSEvent
  {
    let point = hosted.browser.convert(NSPoint(x: x, y: 200), to: nil)
    return NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0,
      clickCount: clickCount, pressure: 1)!
  }

  private func specialKey(
    _ special: NSEvent.SpecialKey, keyCode: UInt16, flags: NSEvent.ModifierFlags = [],
    in window: NSWindow
  ) -> NSEvent {
    let chars = String(UnicodeScalar(special.rawValue)!)
    return NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: chars, charactersIgnoringModifiers: chars,
      isARepeat: false, keyCode: keyCode)!
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

  func beginAndFocusURLField(in hosted: Hosted) throws -> NSTextView {
    hosted.browser.beginURLEditing()
    flush(hosted.window)
    pumpMain(
      until: {
        guard let editor = hosted.window.firstResponder as? NSTextView else { return false }
        return editor.isDescendant(of: hosted.browser.barHost)
      }, "URL 入力欄（本物の field editor）が焦点を取る")
    return try XCTUnwrap(hosted.window.firstResponder as? NSTextView)
  }

  // MARK: - 左端ドラッグとダブルクリック

  /// 左端ドラッグで幅更新・異常離脱キャンセル・全面吸着確定・右投げ閉じ・ダブルクリック全面切替が働き、
  /// 通常域を通過して全面吸着／右投げ閉じ／異常離脱してもドラッグ開始前の確定比率を復元する。
  func testResizeHandleSupportsDragSnapDoubleClickAndResignKeyCancellation() {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let handle = browser.resizeHandle
    var requestedModes: [BrowserMode] = []
    browser.onRequestModeChange = { mode, _ in
      requestedModes.append(mode)
      browser.setMode(mode, animated: false)
    }
    browser.setMode(.sheet, animated: false)

    // 通常域ドラッグ: 1000pt の窓で x=400 → 幅 600pt (60%)。
    NSCursor.arrow.set()
    handle.mouseDown(with: mouse(.leftMouseDown, x: browser.sheetView.frame.minX + 4, in: hosted))
    XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight, "ドラッグ中は左右リサイズカーソルを push")
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 400, in: hosted))
    handle.mouseUp(with: mouse(.leftMouseUp, x: 400, in: hosted))
    XCTAssertEqual(browser.sheetRatio, 0.60, accuracy: 0.001)
    XCTAssertTrue(NSCursor.current === NSCursor.arrow, "ドラッグ終了でカーソルが戻る")

    // 通常域（75%）を経由して全面吸着域まで引いた途中で windowDidResignKey → 中断し 60% のまま戻る。
    handle.mouseDown(with: mouse(.leftMouseDown, x: browser.sheetView.frame.minX + 4, in: hosted))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 250, in: hosted))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 100, in: hosted))
    XCTAssertEqual(browser.snapBadge.kind, .snapFull, "前提: 全面吸着プレビュー中")
    window.isKey = false
    XCTAssertEqual(browser.mode, .sheet, "異常離脱では全面確定しない")
    XCTAssertNil(browser.snapBadge.kind, "スナップバッジが消える")
    XCTAssertEqual(browser.sheetRatio, 0.60, accuracy: 0.001, "開始前の確定比率を保つ")
    XCTAssertTrue(NSCursor.current === NSCursor.arrow, "異常離脱でもカーソルを pop する")

    // 通常域（75%）を経由して全面吸着域で mouseUp → 全面確定かつ開始前比率 60% を保持。
    window.isKey = true
    handle.mouseDown(with: mouse(.leftMouseDown, x: browser.sheetView.frame.minX + 4, in: hosted))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 250, in: hosted))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 100, in: hosted))
    handle.mouseUp(with: mouse(.leftMouseUp, x: 100, in: hosted))
    XCTAssertEqual(requestedModes.last, .full, "全面吸着域で離すと全面切替を要求する")
    XCTAssertEqual(browser.mode, .full)
    XCTAssertEqual(browser.sheetRatio, 0.60, accuracy: 0.001, "全面吸着確定後も開始前比率を保つ")
    XCTAssertTrue(NSCursor.current === NSCursor.arrow, "全面吸着確定でもカーソルを pop する")

    // 右シートへ戻し、通常域（45%）を経由して右投げ閉じ → 閉じ要求かつ 60% 保持。
    browser.setMode(.sheet, animated: false)
    handle.mouseDown(with: mouse(.leftMouseDown, x: browser.sheetView.frame.minX + 4, in: hosted))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 550, in: hosted))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 820, in: hosted))
    handle.mouseUp(with: mouse(.leftMouseUp, x: 820, in: hosted))
    XCTAssertEqual(requestedModes.last, .closed)
    XCTAssertEqual(browser.sheetRatio, 0.60, accuracy: 0.001, "右投げ閉じ後も開始前比率を保つ")

    // 開き直してダブルクリック → 全面切替。
    browser.setMode(.sheet, animated: false)
    handle.mouseDown(
      with: mouse(.leftMouseDown, x: browser.sheetView.frame.minX + 4, in: hosted, clickCount: 2))
    XCTAssertEqual(requestedModes.last, .full)
  }

  // MARK: - キー分類と URL 編集中ガード

  /// ブラウザ焦点中は安全遷移系のみ上位転送し、⌘T/⌘W/⌘R/⌘⇧T/⌘S はブラウザ操作として実行、
  /// 端末ズーム・エディター専用・⌘F は無動作消費する。
  /// URL 編集中は ⌘R・遷移系・⌘⇧[/] を抑止しつつ ⌘S（サイドバー開閉）・⌘⇧←/→ のテキスト選択を維持し、
  /// ⌘T / ⌘B は編集終了のうえブラウザ操作として実行し、焦点外は素通しする。
  func testPerformKeyEquivalentClassifiesChromeKeysAndGuardsURLEditing() {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    var commands: [WindowCommand] = []
    browser.onWindowCommand = { commands.append($0) }
    browser.setMode(.sheet, animated: false)
    browser.focusBrowser()

    // 背後誤爆防止: 端末ズーム・エディター専用・⌘F は消費して上位へ流さない。
    let blocked: [NSEvent] = [
      .key("+"), .key("-"), .key("0"),
      .key("B", [.command, .shift]), .key("p"), .key("f"),
    ]
    for event in blocked { XCTAssertTrue(browser.performKeyEquivalent(with: event)) }
    XCTAssertTrue(commands.isEmpty, "遮断キーは onWindowCommand を呼ばない")

    // ⌘T / ⌘W / ⌘R / ⌘⇧T / ⌘S はブラウザ固有操作として消費し、onWindowCommand を呼ばない。
    XCTAssertFalse(browser.isSidebarOpen, "前提: 右シート既定はサイドバー閉")
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("s")))
    XCTAssertTrue(browser.isSidebarOpen, "⌘S でサイドバーが開く")
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("s")))
    XCTAssertFalse(browser.isSidebarOpen, "再度 ⌘S でサイドバーが閉じる")
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("t")))
    XCTAssertEqual(browser.session.store.tabs.count, 1, "⌘T で新しい TODAY タブを作る")
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("w")))
    XCTAssertEqual(browser.session.store.tabs.count, 0, "⌘W で TODAY タブを閉じる")
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("w")), "タブ 0 枚でも ⌘W は無動作消費")
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("r")), "⌘R はページ再読込として消費")
    XCTAssertTrue(
      browser.performKeyEquivalent(with: .key("T", [.command, .shift])),
      "⌘⇧T は閉じたタブ復元として消費")
    XCTAssertTrue(commands.isEmpty, "ブラウザ固有 5 キーは onWindowCommand を呼ばない")

    // 安全遷移系は上位へ転送し、⌘↑/⌘↓/⌘C は素通しする。
    for event in [
      NSEvent.key("e"), .key("F", [.command, .shift]), .key("}", [.command, .shift]),
      .key("{", [.command, .shift]), .key("E", [.command, .shift]),
    ] { XCTAssertTrue(browser.performKeyEquivalent(with: event)) }
    XCTAssertEqual(commands, [.toggleEditorFace, .findInProject, .nextTab, .prevTab, .openEditor])
    commands.removeAll()
    for event in [
      specialKey(.upArrow, keyCode: 126, flags: [.command], in: window),
      specialKey(.downArrow, keyCode: 125, flags: [.command], in: window),
      .key("c"),
    ] { XCTAssertFalse(browser.performKeyEquivalent(with: event)) }
    XCTAssertTrue(commands.isEmpty, "⌘↑/⌘↓/⌘C は onWindowCommand を呼ばない")

    assertURLEditingAndUnfocusedKeyGuards(browser: browser, window: window)
  }

  private func assertURLEditingAndUnfocusedKeyGuards(
    browser: BrowserLayerView, window: NSWindow
  ) {
    var commands: [WindowCommand] = []
    browser.onWindowCommand = { commands.append($0) }
    browser.beginURLEditing()
    for event in [
      NSEvent.key("e"), .key("r"),
      .key("}", [.command, .shift]), .key("{", [.command, .shift]),
    ] { XCTAssertTrue(browser.performKeyEquivalent(with: event)) }
    XCTAssertTrue(commands.isEmpty, "URL 編集中は ⌘E/⌘R/⌘⇧[/] を発火しない")
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("s")))
    XCTAssertTrue(browser.isSidebarOpen, "URL 編集中も ⌘S でサイドバーを開閉できる")
    XCTAssertTrue(browser.isEditingURL, "⌘S でツールバー URL 編集を維持する")
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("s")))
    XCTAssertFalse(
      browser.performKeyEquivalent(
        with: specialKey(.leftArrow, keyCode: 123, flags: [.command, .shift], in: window)),
      "URL 編集中の ⌘⇧← は素通しする")
    XCTAssertFalse(
      browser.performKeyEquivalent(
        with: specialKey(.rightArrow, keyCode: 124, flags: [.command, .shift], in: window)),
      "URL 編集中の ⌘⇧→ は素通しする")
    XCTAssertTrue(commands.isEmpty, "⌘⇧←/→ でタブ切替を発火しない")
    XCTAssertTrue(browser.isEditingURL, "抑止・素通しキーを受けても URL 編集状態を維持する")

    XCTAssertTrue(browser.performKeyEquivalent(with: .key("t")))
    XCTAssertFalse(browser.isEditingURL, "URL 編集中の ⌘T は編集を終了して新タブを作る")
    XCTAssertEqual(browser.session.store.tabs.count, 1)
    XCTAssertTrue(commands.isEmpty)

    browser.beginURLEditing()
    XCTAssertTrue(browser.performKeyEquivalent(with: .key("b")))
    XCTAssertFalse(browser.isEditingURL, "⌘B は URL 編集を外因終了する")
    XCTAssertEqual(commands, [.toggleBrowser])

    commands.removeAll()
    window.makeFirstResponder(nil)
    XCTAssertFalse(browser.performKeyEquivalent(with: .key("w")))
    XCTAssertFalse(browser.performKeyEquivalent(with: .key("e")))
    XCTAssertTrue(commands.isEmpty)
  }

  func markComposing(_ editor: NSTextView, _ text: String = "か") {
    editor.setMarkedText(
      text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText(), "前提: IME 変換中")
  }

  func replaceAll(_ text: String, in editor: NSTextView) {
    editor.insertText(
      text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
  }

  // MARK: - 本物の BrowserURLTextField（NSTextField / Coordinator＋IME）経由の編集契約

  /// URL 欄編集開始で本物の field editor が焦点を取って全選択し、IME 変換中の Enter / Esc は保護する。
  /// 不正入力の Enter は編集欄に留まったうえで直後の他所焦点移動（blur）を焦点を奪い返さず終了でき、
  /// 非変換中の Esc 取消と有効 URL の Enter 確定はブラウザへ焦点を戻し、⌘⇧← は行頭選択として働く。
  func testURLEditingViaRealTextFieldHandlesSelectionIMECommitCancelAndBlur() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    hosted.underlay.addSubview(outsider)
    let server = try LocalLoopbackHTTPServer(routes: [
      "/start": "<p>start</p>", "/next": "<p>next</p>",
    ])
    defer { server.stop() }

    browser.setMode(.sheet, animated: false)
    var finishCount = 0
    browser.onNavigationFinish = { finishCount += 1 }
    let startURL = server.url(for: "/start")
    browser.load(startURL)
    pumpMain(until: { finishCount >= 1 }, timeout: 5, "初期ページ読み込み完了")

    // 1. 開始時に現在 URL が全選択され、IME 変換中の Enter / Esc では終了しない。
    let editor = try beginAndFocusURLField(in: hosted)
    XCTAssertEqual(editor.string, startURL.absoluteString)
    XCTAssertEqual(
      editor.selectedRange(),
      NSRange(location: 0, length: (startURL.absoluteString as NSString).length),
      "編集開始時は現在 URL を全選択する")

    markComposing(editor)
    deliverKeyDown(keyEvent("\r", keyCode: 36, in: window), to: window)
    XCTAssertTrue(browser.isEditingURL, "IME 変換中の Enter で URL 編集を終了しない")
    markComposing(editor)
    deliverKeyDown(keyEvent("\u{1B}", keyCode: 53, in: window), to: window)
    XCTAssertTrue(browser.isEditingURL, "IME 変換中の Esc で URL 編集を終了しない")
    editor.unmarkText()

    // 2. ⌘⇧← で行頭選択でき、不正入力 Enter で編集欄に留まった直後に他所へ焦点を移しても blur で閉じる。
    let fullLength = (editor.string as NSString).length
    editor.setSelectedRange(NSRange(location: fullLength, length: 0))
    let cmdShiftLeft = specialKey(.leftArrow, keyCode: 123, flags: [.command, .shift], in: window)
    XCTAssertFalse(browser.performKeyEquivalent(with: cmdShiftLeft))
    deliverKeyDown(cmdShiftLeft, to: window)
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: fullLength))

    replaceAll("not a url", in: editor)
    deliverKeyDown(keyEvent("\r", keyCode: 36, in: window), to: window)
    XCTAssertTrue(browser.isEditingURL, "不正入力の Enter は編集欄に留まる")
    XCTAssertEqual(finishCount, 1, "不正入力では遷移しない")

    XCTAssertTrue(window.makeFirstResponder(outsider))
    flush(window)
    nextTurn()
    XCTAssertFalse(browser.isEditingURL, "不正入力 Enter 後の他所焦点移動でも blur で自動終了する")
    let responder = try XCTUnwrap(window.firstResponder as? NSView)
    XCTAssertTrue(
      responder === outsider || responder.isDescendant(of: outsider),
      "外因終了は他所の焦点を奪い返さない")
    XCTAssertFalse(browser.focusIsInside, "外因終了後にブラウザへ焦点が戻らない")

    // 3. 非変換中の Esc 取消と有効 URL の Enter 確定はどちらもブラウザ本体へ焦点を戻す。
    _ = try beginAndFocusURLField(in: hosted)
    deliverKeyDown(keyEvent("\u{1B}", keyCode: 53, in: window), to: window)
    XCTAssertFalse(browser.isEditingURL, "非変換中の Esc で編集を取り消す")
    XCTAssertTrue(window.firstResponder === browser.focusTarget, "明示取消はブラウザ本体へ焦点を戻す")

    let nextURL = server.url(for: "/next")
    replaceAll(nextURL.absoluteString, in: try beginAndFocusURLField(in: hosted))
    deliverKeyDown(keyEvent("\r", keyCode: 36, in: window), to: window)
    XCTAssertFalse(browser.isEditingURL, "有効 URL の Enter で編集を閉じる")
    XCTAssertTrue(window.firstResponder === browser.focusTarget, "明示確定はブラウザ本体へ焦点を戻す")
    pumpMain(until: { finishCount >= 2 }, timeout: 5, "確定先 URL の読み込み完了")
    XCTAssertEqual(browser.webView?.url, nextURL)
  }

  /// 空スペース間・空タブ間（いずれも `mountedRuntime == nil`）の切替でも URL 編集が外因終了され、
  /// 下層に焦点がある場合は切替で焦点を奪い返さない。
  func testEmptyTabAndEmptySpaceSwitchEndsURLEditingExternally() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    let session = browser.session
    let freeSpaces = session.store.freeSpaces
    XCTAssertGreaterThanOrEqual(freeSpaces.count, 2, "前提: 自由スペースが 2 件以上ある")
    let spaceA = freeSpaces[0]
    let spaceB = freeSpaces[1]

    XCTAssertTrue(session.selectSpace(.free(spaceA.id)))
    browser.setMode(.sheet, animated: false)
    XCTAssertNil(browser.mountedRuntime)

    // 1. 空スペース A → 空スペース B の切替で URL 編集が外因終了される。
    _ = try beginAndFocusURLField(in: hosted)
    XCTAssertTrue(browser.isEditingURL)
    XCTAssertTrue(session.selectSpace(.free(spaceB.id)))
    XCTAssertFalse(browser.isEditingURL, "空スペース間の切替で URL 編集が外因終了される")
    XCTAssertEqual(browser.displayedSpaceId, spaceB.id)

    // 2. 同一スペース内の空タブ 1 → 空タブ 2 の切替でも URL 編集が外因終了される。
    let emptyTab1 = try XCTUnwrap(session.openTab(in: spaceB.id, url: nil, activate: true))
    let emptyTab2 = try XCTUnwrap(session.openTab(in: spaceB.id, url: nil, activate: false))
    XCTAssertNil(browser.mountedRuntime)
    _ = try beginAndFocusURLField(in: hosted)
    XCTAssertTrue(session.selectTab(emptyTab2.id))
    XCTAssertFalse(browser.isEditingURL, "空タブ間の切替で URL 編集が外因終了される")
    XCTAssertEqual(browser.displayedTabId, emptyTab2.id)

    // 3. 焦点がブラウザ外にある間の空タブ切替では焦点を奪い返さない。
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    hosted.underlay.addSubview(outsider)
    XCTAssertTrue(window.makeFirstResponder(outsider))
    XCTAssertTrue(session.selectTab(emptyTab1.id))
    XCTAssertFalse(browser.focusIsInside, "ブラウザ外焦点のまま空タブを切り替えても焦点を奪わない")
  }
}
