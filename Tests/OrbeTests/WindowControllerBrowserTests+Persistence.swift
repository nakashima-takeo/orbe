import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// `WindowController` 統合における workspace 削除時のローカルスペース連動除去、起動時復元での
/// 閉状態・シート幅比率復元・起動時 12 時間整理・初回オープン遅延 materialize、および
/// `yieldBrowserToUnderlay` 経由の閉鎖同期を守る。
///
/// 壊れると何が起きるか。workspace を閉じてもローカルスペース・タブ・閉じたタブ履歴・ランタイムが
/// DB とメモリへ孤児残留する、または別 workspace のローカルスペースを誤削除する。再起動後に
/// ブラウザが意図せず開いた状態で始まる・幅比率が巻き戻る・古い放置タブが消えない、あるいは
/// 全面ブラウザから下層へ移った際に閉鎖状態が `BrowserSession` へ同期されず保護が外れない。
extension WindowControllerBrowserTests {
  /// `closeWorkspace`（背景 workspace 削除・アクティブ workspace 削除の両経路）で対象 workspace の
  /// ローカルスペース・配下タブ・閉じたタブ履歴・ランタイムだけが除去され、残存 workspace は無傷。
  @MainActor
  func testCloseWorkspaceRemovesOnlyTargetLocalSpaceTabsHistoryAndRuntime() throws {
    let server = try LocalLoopbackHTTPServer(routes: [
      "/a": "<!doctype html><title>A</title><p>a</p>",
      "/b": "<!doctype html><title>B</title><p>b</p>",
      "/c": "<!doctype html><title>C</title><p>c</p>",
    ])
    defer { server.stop() }

    let wsAId = UUID()
    let wsBId = UUID()
    let wsCId = UUID()
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(name: "a", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain], id: wsAId),
        WorkspaceState(name: "b", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain], id: wsBId),
        WorkspaceState(name: "c", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain], id: wsCId),
      ], window: window)
    window.isKey = true
    wc.setBrowserMode(.sheet, animated: false)

    let wsAIdx = try XCTUnwrap(wc.workspaces.firstIndex { $0.id == wsAId })
    let wsBIdx = try XCTUnwrap(wc.workspaces.firstIndex { $0.id == wsBId })
    let wsCIdx = try XCTUnwrap(wc.workspaces.firstIndex { $0.id == wsCId })

    let runtimeA = try populateLocalWorkspace(wc, index: wsAIdx, url: server.url(for: "/a"))
    let runtimeB = try populateLocalWorkspace(wc, index: wsBIdx, url: server.url(for: "/b"))
    let runtimeC = try populateLocalWorkspace(wc, index: wsCIdx, url: server.url(for: "/c"))
    let wsCTabId = try XCTUnwrap(wc.browserSession.store.activeTab?.id)
    let wsCSpaceId = try XCTUnwrap(wc.browserSession.store.localSpace(for: wsCId)?.id)
    wc.switchWorkspace(to: wsAIdx)

    // 1. 背景 workspace（wsB）削除: wsB のローカルスペース・タブ・履歴・ランタイムのみ除去。
    let currentBIdx = try XCTUnwrap(wc.workspaces.firstIndex { $0.id == wsBId })
    wc.closeWorkspace(currentBIdx, origin: .controlAPI)
    XCTAssertNil(wc.browserSession.store.localSpace(for: wsBId), "背景 WS のローカルスペース除去")
    XCTAssertTrue(runtimeB.isInvalidated, "背景 WS のランタイムを invalidate")
    XCTAssertNil(wc.browserSession.runtimes[runtimeB.tabId])
    XCTAssertNotNil(wc.browserSession.store.localSpace(for: wsAId))
    XCTAssertNotNil(wc.browserSession.store.localSpace(for: wsCId))

    // 2. アクティブ workspace（wsA）削除: wsA のローカルスペース・タブ・履歴・ランタイムのみ除去。
    let currentAIdx = try XCTUnwrap(wc.workspaces.firstIndex { $0.id == wsAId })
    wc.closeWorkspace(currentAIdx, origin: .controlAPI)
    XCTAssertNil(wc.browserSession.store.localSpace(for: wsAId), "アクティブ WS のローカルスペース除去")
    XCTAssertTrue(runtimeA.isInvalidated, "アクティブ WS のランタイムを invalidate")
    XCTAssertNil(wc.browserSession.runtimes[runtimeA.tabId])
    XCTAssertFalse(runtimeC.isInvalidated, "残存 wsC のランタイムは無傷")
    XCTAssertNotNil(wc.browserSession.store.tab(id: wsCTabId), "残存 wsC のタブは無傷")
    XCTAssertEqual(
      wc.browserSession.store.closedTabs.map(\.originalSpaceId), [wsCSpaceId],
      "wsA/wsB の履歴は消え wsC のみ残る")
  }

  /// 永続 DB からの `WindowController` 起動復元は閉状態・保存済みシート比率・起動時 12 時間整理済みで始まり、
  /// `⌘B` 開放で初めて前回タブが遅延 materialize し、`yieldBrowserToUnderlay` 閉鎖も `session` へ同期する。
  @MainActor
  func testRestartRestoresClosedStateRatioAndLazyTabAndYieldSyncsSessionOpenState() throws {
    let server = try LocalLoopbackHTTPServer(routes: [
      "/keep": "<!doctype html><title>Keep</title><p>keep</p>"
    ])
    defer { server.stop() }
    let keepURL = server.url(for: "/keep")
    let wsId = UUID()

    // 1. 事前状態を実 DB へ保存して接続を解放する（WindowControllerRestoreTests と同じ流儀）。
    let (expiredTabId, keptTabId): (UUID, UUID) = try {
      let store = BrowserStore.open(language: .ja)
      XCTAssertTrue(store.setSheetRatio(0.68).didPersist)
      let freeSpace = try XCTUnwrap(store.freeSpaces.first)
      XCTAssertTrue(store.selectSpace(.free(freeSpace.id)).didPersist)
      let kept = try XCTUnwrap(
        store.openTab(in: freeSpace.id, section: .pinned, url: keepURL, activate: true).value)
      let stale = try XCTUnwrap(
        store.openTab(
          in: freeSpace.id, section: .today, url: keepURL, activate: false,
          now: Date().addingTimeInterval(-(BrowserStore.todayTabTTL + 600))
        ).value)
      return (stale.id, kept.id)
    }()

    // 2. WindowController 起動: 閉状態・WebKit 未生成・比率復元・起動時 12h 整理完了済み。
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain], id: wsId)],
      window: window)
    window.isKey = true
    XCTAssertTrue(wc.browserSession.store.available)
    XCTAssertEqual(wc.browserMode, .closed, "再起動後は常に閉状態で始まる")
    XCTAssertFalse(wc.browserSession.isBrowserOpen)
    XCTAssertNil(wc.browserView.webView, "起動直後は WKWebView を作らない")
    XCTAssertEqual(wc.browserView.sheetRatio, 0.68, accuracy: 0.001, "保存比率を復元する")
    XCTAssertNil(wc.browserSession.store.tab(id: expiredTabId), "起動時 12h 整理で放置 TODAY を除去")
    XCTAssertNotNil(wc.browserSession.store.tab(id: keptTabId))

    // 3. ⌘B 開放で初めて前回アクティブタブを遅延 materialize する。
    var finishes = 0
    wc.browserView.onNavigationFinish = { finishes += 1 }
    XCTAssertTrue(wc.window.performKeyEquivalent(with: .key("b")))
    XCTAssertEqual(wc.browserMode, .sheet)
    XCTAssertTrue(wc.browserSession.isBrowserOpen)
    XCTAssertNotNil(wc.browserView.webView, "開放時に初めて WKWebView を遅延生成する")
    pumpMain(until: { finishes >= 1 }, timeout: 5, "復元タブの読み込み完了")
    XCTAssertEqual(wc.browserView.webView?.url, keepURL)

    // 4. 全面表示から ⌘E（yieldBrowserToUnderlay 経路）で閉鎖しても session.isBrowserOpen が同期する。
    wc.setBrowserMode(.full, animated: false)
    XCTAssertTrue(wc.browserSession.isBrowserOpen)
    wc.toggleEditorFace()
    XCTAssertEqual(wc.browserMode, .closed)
    XCTAssertFalse(wc.browserSession.isBrowserOpen, "yieldBrowserToUnderlay 閉鎖も session へ同期")
  }

  @MainActor
  private func populateLocalWorkspace(
    _ wc: WindowController, index: Int, url: URL
  ) throws -> BrowserTabRuntime {
    wc.switchWorkspace(to: index)
    let localSpace = try XCTUnwrap(wc.browserSession.store.currentLocalSpace)
    let closedTab = try XCTUnwrap(
      wc.browserSession.openTab(in: localSpace.id, section: .today, url: url, activate: false))
    XCTAssertTrue(wc.browserSession.closeTab(closedTab.id, recordClosed: true))

    var loaded = false
    wc.browserView.onNavigationFinish = { loaded = true }
    let activeTab = try XCTUnwrap(
      wc.browserSession.openTab(in: localSpace.id, section: .today, url: url, activate: true))
    pumpMain(until: { loaded }, timeout: 5, "ローカルタブ読み込み完了")
    return try XCTUnwrap(wc.browserSession.runtimes[activeTab.id])
  }
}
