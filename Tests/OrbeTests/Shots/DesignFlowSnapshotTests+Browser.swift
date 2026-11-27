import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 内蔵ブラウザ層（Z=2）の視覚確認 flow。
/// 未 `orderFront` の borderless `NSWindow`（`ScreenIsolation` 遵守）上に本物の `GroupFacesView`（Z=0/Z=1）と
/// `BrowserLayerView`（Z=2）を兄弟配置し、外部通信ゼロのローカル HTML を `WKWebView.takeSnapshot` 合成して撮る。
extension DesignFlowSnapshotTests {
  func testBrowserShell() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    let size = NSSize(width: 1100, height: 640)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)

    let session = BrowserSession.inMemory(language: .ja, workspaceName: "orbe")
    let browser = BrowserLayerView(
      session: session, localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver())
    browser.reduceMotion = true

    let stage = BrowserShotStage(frame: NSRect(origin: .zero, size: size))
    for sub in [scene.group.view, browser] as [NSView] {
      sub.frame = stage.bounds
      sub.autoresizingMask = [.width, .height]
      stage.addSubview(sub)
    }
    window.contentView = stage
    defer {
      browser.clearWebSnapshot()
      window.contentView = nil
    }

    scene.group.view.show(.editor, animated: false)
    stage.layoutSubtreeIfNeeded()
    pumpMain(until: { scene.isReady }, "git バッジと文書の色付けが揃う")

    var idx = 0
    browser.setMode(.sheet, animated: false)
    browser.setFocused(true)
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: false, idx: &idx, label: "empty_dark")

    loadBrowserFixturePage(in: browser)
    try captureSheetFocusAndUnfocused(window: window, stage: stage, browser: browser, idx: &idx)
    try captureNarrowSheetAndPeek(window: window, stage: stage, browser: browser, idx: &idx)
    try captureSheetDrag(window: window, stage: stage, browser: browser, idx: &idx)
    try captureFullAndPeek(
      window: window, stage: stage, faces: scene.group.view, browser: browser, idx: &idx)
    try captureSidebarPopoverAndNewTab(window: window, stage: stage, browser: browser, idx: &idx)
  }

  /// サイドバー（自由・ローカル）・プロファイルポップオーバー・新しいタブ画面・360pt 狭幅オーバーレイを撮る。
  private func captureSidebarPopoverAndNewTab(
    window: NSWindow, stage: NSView, browser: BrowserLayerView, idx: inout Int
  ) throws {
    let store = browser.session.store
    let personalSpace = try XCTUnwrap(store.freeSpaces.first { $0.icon == .person })
    let localSpace = try XCTUnwrap(store.currentLocalSpace)
    populateSidebarFixtureTabs(in: browser.session, personal: personalSpace, local: localSpace)

    // 1. 全面ローカルスペースサイドバー（Dark / Light）
    _ = browser.session.selectSpace(.local)
    browser.setMode(.full, animated: false)
    browser.setSidebarOpen(true)
    browser.setFocused(true)
    loadBrowserFixturePage(in: browser)
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
      window.appearance = NSAppearance(named: appearance)
      try writeBrowserShot(
        stage: stage, browser: browser, captureWeb: true, idx: &idx,
        label: "full_local_sidebar_\(suffix)")
    }

    // 2. 全面自由スペース（個人・非公開ピル＋Favorites 4 タイル＋PINNED＋TODAY）Dark / Light
    _ = browser.session.selectSpace(.free(personalSpace.id))
    loadBrowserFixturePage(in: browser)
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
      window.appearance = NSAppearance(named: appearance)
      try writeBrowserShot(
        stage: stage, browser: browser, captureWeb: true, idx: &idx,
        label: "full_free_sidebar_\(suffix)")
    }

    // 3. プロファイルポップオーバー開（Dark / Light）
    browser.openPopover(.profile)
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
      window.appearance = NSAppearance(named: appearance)
      try writeBrowserShot(
        stage: stage, browser: browser, captureWeb: true, idx: &idx,
        label: "popover_profile_\(suffix)")
    }
    browser.closePopover()

    // 4. 新しいタブ画面（クイックアクセス＋最近閉じたタブあり）Dark / Light
    browser.openNewTab()
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
      window.appearance = NSAppearance(named: appearance)
      try writeBrowserShot(
        stage: stage, browser: browser, captureWeb: false, idx: &idx,
        label: "newtab_rich_\(suffix)")
    }

    // 5. 狭幅右シート 360pt オーバーレイサイドバー開（WKWebView 合成上に暗幕＋サイドバー）
    window.appearance = NSAppearance(named: .darkAqua)
    _ = browser.session.selectSpace(.local)
    browser.setMode(.sheet, animated: false)
    browser.setSheetRatio(360.0 / 1100.0)
    browser.setSidebarOpen(true)
    loadBrowserFixturePage(in: browser)
    stage.layoutSubtreeIfNeeded()
    XCTAssertTrue(browser.isSidebarOverlay, "360pt 右シートではオーバーレイドロワーに切り替わる")
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: true, idx: &idx,
      label: "sheet_overlay_360_dark")
    browser.setSidebarOpen(false)
    browser.setSheetRatio(BrowserResizeSession.defaultRatio)
  }

  private func populateSidebarFixtureTabs(
    in session: BrowserSession, personal: BrowserSpace, local: BrowserSpace
  ) {
    if let initialLocalTab = session.store.tabs(in: local.id).first {
      _ = session.store.updateTabTitle(initialLocalTab.id, title: "Orbe Preview — SyncClient")
    }

    let favEntries: [(String, String)] = [
      ("https://mail.google.com/mail/u/0/#inbox", "Gmail"),
      ("https://calendar.google.com/calendar", "Google カレンダー"),
      ("https://www.youtube.com/watch?v=orbe", "YouTube"),
      ("https://github.com/notifications", "GitHub"),
    ]
    for (raw, title) in favEntries {
      _ = session.openTab(
        in: personal.id, section: .favorite, url: URL(string: raw), title: title, activate: false)
    }
    _ = session.openTab(
      in: personal.id, section: .pinned, url: URL(string: "https://x.com/home"),
      title: "ホーム / X", activate: false)
    _ = session.openTab(
      in: personal.id, section: .pinned, url: URL(string: "https://www.amazon.co.jp/orders"),
      title: "注文履歴 — Amazon", activate: false)
    // アクティブタブは外部通信ゼロでローカル HTML を差し込めるよう url: nil で生成する。
    _ = session.openTab(
      in: personal.id, section: .today, url: nil, title: "週末の予定 — Notion", activate: true)

    _ = session.openTab(
      in: local.id, section: .pinned,
      url: URL(string: "https://github.com/nakashima-takeo/orbe/actions"),
      title: "CI · build-test #429", activate: false)
    _ = session.openTab(
      in: local.id, section: .pinned,
      url: URL(string: "https://developer.apple.com/documentation/webkit"),
      title: "WKWebsiteDataStore — Apple Docs", activate: false)
    _ = session.openTab(
      in: local.id, section: .today,
      url: URL(string: "https://developer.mozilla.org/ja/docs/Web/API/WebSockets_API"),
      title: "WebSockets API — MDN", activate: false)

    if let closed1 = session.openTab(
      in: personal.id, section: .today,
      url: URL(string: "https://developer.apple.com/videos/play/wwdc2024/10134"),
      title: "WKWebExtension in macOS — WWDC24", activate: false)
    {
      _ = session.closeTab(closed1.id, recordClosed: true)
    }
    if let closed2 = session.openTab(
      in: local.id, section: .today,
      url: URL(string: "https://localhost:5173/preview"),
      title: "Orbe Preview — SyncClient", activate: false)
    {
      _ = session.closeTab(closed2.id, recordClosed: true)
    }
  }

  /// 右シート最小幅（240pt）と狭幅ウィンドウでの全面 Peek で 5 つの主要ボタンが 1px も切れないことを撮る。
  private func captureNarrowSheetAndPeek(
    window: NSWindow, stage: NSView, browser: BrowserLayerView, idx: inout Int
  ) throws {
    let originalFrame = window.frame
    window.appearance = NSAppearance(named: .darkAqua)

    window.setFrame(NSRect(origin: .zero, size: NSSize(width: 800, height: 640)), display: false)
    browser.setMode(.sheet, animated: false)
    browser.setSheetRatio(BrowserResizeSession.minRatio)
    browser.setFocused(true)
    stage.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      browser.sheetView.frame.width, BrowserResizeSession.closeThresholdWidth, accuracy: 0.5,
      "800pt 窓・minRatio で右シート最小幅 240pt に収まる")
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: true, idx: &idx, label: "sheet_narrow_240_dark")

    window.setFrame(NSRect(origin: .zero, size: NSSize(width: 320, height: 640)), display: false)
    browser.setMode(.full, animated: false)
    browser.setPeekUnderlay(.editor)
    browser.setPeeking(true, animated: false)
    stage.layoutSubtreeIfNeeded()
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: false, idx: &idx,
      label: "full_peek_narrow_320_dark")
    browser.setPeeking(false, animated: false)

    window.setFrame(originalFrame, display: false)
    browser.setSheetRatio(BrowserResizeSession.defaultRatio)
    stage.layoutSubtreeIfNeeded()
  }

  private func captureSheetFocusAndUnfocused(
    window: NSWindow, stage: NSView, browser: BrowserLayerView, idx: inout Int
  ) throws {
    browser.setMode(.sheet, animated: false)
    browser.setSheetRatio(BrowserResizeSession.defaultRatio)
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
      window.appearance = NSAppearance(named: appearance)
      browser.setFocused(true)
      try writeBrowserShot(
        stage: stage, browser: browser, captureWeb: true, idx: &idx,
        label: "sheet_focus_\(suffix)")
      browser.setFocused(false)
      try writeBrowserShot(
        stage: stage, browser: browser, captureWeb: true, idx: &idx,
        label: "sheet_unfocused_\(suffix)")
    }
    window.appearance = NSAppearance(named: .darkAqua)
  }

  private func captureSheetDrag(
    window: NSWindow, stage: NSView, browser: BrowserLayerView, idx: inout Int
  ) throws {
    browser.setMode(.sheet, animated: false)
    browser.setSheetRatio(BrowserResizeSession.defaultRatio)
    browser.setFocused(true)
    stage.layoutSubtreeIfNeeded()

    let handle = browser.resizeHandle
    let startPoint = browser.convert(NSPoint(x: browser.sheetView.frame.minX + 4, y: 200), to: nil)
    handle.mouseDown(with: .mouse(.leftMouseDown, at: startPoint, in: window))
    let dragPoint = browser.convert(NSPoint(x: stage.bounds.width * 0.36, y: 200), to: nil)
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: dragPoint, in: window))
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: true, idx: &idx, label: "sheet_drag_percent")

    let snapPoint = browser.convert(NSPoint(x: stage.bounds.width * 0.10, y: 200), to: nil)
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: snapPoint, in: window))
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: true, idx: &idx, label: "sheet_drag_snap_full")

    let closePoint = browser.convert(NSPoint(x: stage.bounds.width - 180, y: 200), to: nil)
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: closePoint, in: window))
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: true, idx: &idx, label: "sheet_drag_close")

    handle.cancelDragIfNeeded()
    browser.setSheetRatio(BrowserResizeSession.defaultRatio)
  }

  private func captureFullAndPeek(
    window: NSWindow, stage: NSView, faces: GroupFacesView, browser: BrowserLayerView,
    idx: inout Int
  ) throws {
    browser.setMode(.full, animated: false)
    browser.setFocused(true)
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
      window.appearance = NSAppearance(named: appearance)
      try writeBrowserShot(
        stage: stage, browser: browser, captureWeb: true, idx: &idx, label: "full_\(suffix)")
    }
    window.appearance = NSAppearance(named: .darkAqua)

    browser.setMode(.sheet, animated: false)
    browser.setSheetRatio(BrowserResizeSession.defaultRatio)
    browser.setPeekUnderlay(.editor)
    browser.setPeeking(true, animated: false)
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: false, idx: &idx, label: "sheet_peek_editor")
    browser.setPeeking(false, animated: false)

    browser.setMode(.full, animated: false)
    browser.setPeekUnderlay(.editor)
    browser.setPeeking(true, animated: false)
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: false, idx: &idx, label: "full_peek_editor")

    faces.show(.terminal, animated: false)
    browser.setPeekUnderlay(.terminal)
    try writeBrowserShot(
      stage: stage, browser: browser, captureWeb: false, idx: &idx, label: "full_peek_terminal")
    browser.setPeeking(false, animated: false)
  }

  private func loadBrowserFixturePage(in browser: BrowserLayerView) {
    var finished = false
    browser.onNavigationFinish = { finished = true }
    browser.loadHTMLString(
      Self.browserFixtureHTML, baseURL: URL(string: "https://docs.orbe.dev/browser/preview"))
    pumpMain(until: { finished }, timeout: 5, "ローカル HTML の読み込み完了")
    if let tab = browser.session.store.activeTab, tab.title.isEmpty {
      _ = browser.session.store.updateTabTitle(tab.id, title: "Orbe Preview — SyncClient")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
  }

  private func writeBrowserShot(
    stage: NSView, browser: BrowserLayerView, captureWeb: Bool, idx: inout Int, label: String
  ) throws {
    stage.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.12))
    if captureWeb {
      var done = false
      browser.captureWebSnapshot { _ in done = true }
      pumpMain(until: { done }, timeout: 5, "WKWebView.takeSnapshot 完了")
      stage.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    defer { browser.clearWebSnapshot() }
    let rep = try XCTUnwrap(stage.bitmapImageRepForCachingDisplay(in: stage.bounds))
    stage.cacheDisplay(in: stage.bounds, to: rep)
    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    let name = String(format: "browser_shell_%02d_%@", idx, label)
    let url = previewDir("flows").appendingPathComponent("\(name).png")
    try data.write(to: url)
    print("[flow] wrote \(url.path)")
    idx += 1
  }

  private static let browserFixtureHTML = """
    <!doctype html>
    <html lang="ja"><head><meta charset="utf-8"><style>
    :root { color-scheme: dark light; --bg: #13111a; --card: #1d1929; --line: rgba(199,185,235,.12);
      --t1: #e6e1f0; --t2: #b8afc4; --t3: #8b8397; --ac: #9068f0; --ok: #82d894; }
    @media (prefers-color-scheme: light) {
      :root { --bg: #faf9fd; --card: #ffffff; --line: rgba(110,90,170,.16);
        --t1: #3a3151; --t2: #5f5678; --t3: #8d85a3; --ac: #6d43d8; --ok: #279a4d; }
    }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 24px 26px; background: var(--bg); color: var(--t1);
      font: 13px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    .badge { display: inline-flex; align-items: center; gap: 6px; padding: 2px 9px;
      border-radius: 99px; font: 11px ui-monospace, Menlo, monospace;
      background: rgba(144,104,240,.16); color: var(--ac); }
    .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--ok); }
    h1 { margin: 12px 0 6px; font-size: 20px; font-weight: 600; }
    p { margin: 0 0 18px; color: var(--t2); }
    .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
    .card { padding: 14px 16px; border-radius: 10px; background: var(--card);
      border: 1px solid var(--line); }
    .k { font: 10.5px ui-monospace, Menlo, monospace; color: var(--t3); margin-bottom: 4px; }
    .v { font: 600 16px ui-monospace, Menlo, monospace; color: var(--t1); }
    </style></head><body>
    <span class="badge"><i class="dot"></i>LIVE · localhost:5173</span>
    <h1>Orbe Preview — SyncClient</h1>
    <p>3 層ステージの最上層（Z=2）として動作する右エッジシート型ブラウザの描画見本。</p>
    <div class="grid">
      <div class="card"><div class="k">LAYERS</div><div class="v">Z=0 / Z=1 / Z=2</div></div>
      <div class="card"><div class="k">TERMINAL SIGWINCH</div><div class="v">0 events</div></div>
      <div class="card"><div class="k">OPACITY</div><div class="v">100% opaque</div></div>
      <div class="card"><div class="k">STORAGE</div><div class="v">nonPersistent</div></div>
    </div>
    </body></html>
    """
}

/// 不透明時のステージ地（`bg.base`）。`GroupFacesView` と `BrowserLayerView` を兄弟で載せる。
private final class BrowserShotStage: NSView {
  override func draw(_ dirtyRect: NSRect) {
    Theme.Color.bgBase.setFill()
    bounds.fill()
  }
}
