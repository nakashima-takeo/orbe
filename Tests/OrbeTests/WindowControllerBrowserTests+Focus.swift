import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// URL 欄編集中における背景操作（背景タブ閉鎖・workspace 切替）からのフォーカス・入力保護と、
/// タブ改名中に右シート（本体・URL 欄）へ焦点を移した際の改名欄 blur からの焦点保護を実窓で守る。
extension WindowControllerBrowserTests {
  /// 自由スペース表示中に URL 欄を本物の field editor で編集中に背景タブ閉鎖・workspace 切替が走っても
  /// 入力中の URL を破棄せず、タブ改名中に右シート（本体・URL 欄）へ焦点を移した直後の改名欄 blur でも
  /// 焦点が下層へ奪い返されない。
  @MainActor
  func testURLEditingSurvivesBackgroundFocusSelectionAndTabRenameClick() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(
          name: "a", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain, Self.plain]),
        WorkspaceState(name: "b", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
      ], window: window)
    window.isKey = true
    let wsA = try XCTUnwrap(wc.workspaces.first { $0.name == "a" })
    let wsBIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "b" })
    let workSpace = try XCTUnwrap(
      wc.browserSession.store.freeSpaces.first { $0.icon == .briefcase })
    XCTAssertTrue(wc.browserSession.selectSpace(.free(workSpace.id)))
    wc.setBrowserMode(.sheet, animated: false)

    // 1. 自由スペース表示中の URL 欄編集中に背景タブ閉鎖・workspace 切替が起きても焦点と入力内容を守る。
    wc.browserView.beginURLEditing()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: wc.browserView.barHost) == true
      }, "URL 欄の field editor が焦点を取る")
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.insertText("https://draft.example", replacementRange: NSRange(location: 0, length: 0))

    wc.closeTab(wsA.tabs[1], origin: .controlAPI)
    XCTAssertTrue(wc.browserView.isEditingURL, "背景タブ閉鎖で URL 編集を破棄しない")
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(editor.string, "https://draft.example")

    wc.switchWorkspace(to: wsBIndex)
    XCTAssertTrue(wc.browserView.isEditingURL, "自由スペース表示中の workspace 切替で URL 編集を破棄しない")
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(editor.string, "https://draft.example")
    wc.browserView.cancelURLEditing()

    // 2. 下層端末焦点からタブ改名を開始し、右シート本体へ焦点を移した直後の改名欄 blur でも焦点が戻らない。
    let tabB = try XCTUnwrap(wc.activeTab)
    window.makeFirstResponder(tabB.surface)
    XCTAssertFalse(wc.browserWasFocused, "前提: 下層端末に焦点")
    wc.beginTabRename()
    XCTAssertNotNil(wc.statusModel.editingIndex, "前提: タブ改名中")
    wc.browserView.focusBrowser()
    wc.statusModel.onCancelRename()
    XCTAssertTrue(wc.browserView.focusIsInside, "改名中クリック後の blur で下層端末へ奪い返されない")
    XCTAssertTrue(wc.browserWasFocused)

    // 3. 改名欄が焦点を取った状態で URL 欄へ焦点を移すと、本物の改名欄 blur 後も URL 編集と焦点が維持される。
    window.makeFirstResponder(tabB.surface)
    wc.beginTabRename()
    flush(window)
    pumpMain(
      until: {
        guard let responder = window.firstResponder as? NSTextView else { return false }
        return !responder.isDescendant(of: wc.browserView.barHost)
      }, "前提: タブ改名欄が焦点を取る")
    wc.browserView.beginURLEditing()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: wc.browserView.barHost) == true
      }, "改名中に URL 欄が焦点を取る")
    let urlEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
    flush(window)
    pumpMain(until: { wc.statusModel.editingIndex == nil }, "改名欄の blur でタブ改名が終了する")
    XCTAssertTrue(wc.browserView.isEditingURL, "改名欄 blur で URL 編集が打ち切られない")
    XCTAssertTrue(window.firstResponder === urlEditor)
  }

  /// ローカルスペース（空画面同士）表示中に URL 欄編集中で workspace を切り替えると、
  /// 表示先スペースが切り替わるため URL 編集が外因終了される。
  @MainActor
  func testLocalSpaceWorkspaceSwitchEndsURLEditingAcrossEmptySpaces() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(name: "a", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
        WorkspaceState(name: "b", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
      ], window: window)
    window.isKey = true
    let wsBIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "b" })
    wc.setBrowserMode(.sheet, animated: false)
    XCTAssertEqual(wc.browserSession.store.activeSpaceSelection, .local, "前提: ローカルスペース表示")
    XCTAssertNil(wc.browserView.mountedRuntime, "前提: 空画面でランタイムなし")

    wc.browserView.beginURLEditing()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: wc.browserView.barHost) == true
      }, "URL 欄が焦点を取る")

    wc.switchWorkspace(to: wsBIndex)
    XCTAssertFalse(wc.browserView.isEditingURL, "ローカルスペース切替で URL 編集が外因終了される")
    XCTAssertNil(wc.browserView.mountedRuntime)
  }

  /// 右シート＋ローカルスペース焦点中（ページ表示中・URL 編集中）からの別 workspace 宛て下層遷移
  /// （`controlFocusTab`・`controlOpenFile`・`select(.tab(...), inWorkspaceAt:)`）で、
  /// `renderSelection` 内の `syncCurrentWorkspace` 後にブラウザが下層から焦点を奪い返さない。
  @MainActor
  func testLocalSpaceSheetYieldsFocusToTargetWorkspaceUnderlayWithoutReclaiming() throws {
    let dir = TestScratch.caseDir.appendingPathComponent("ws-yield", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = try caseFile("ws-yield/target.txt", "hello")
    let server = try LocalLoopbackHTTPServer(routes: [
      "/a": "<!doctype html><title>A</title><p>a</p>",
      "/b": "<!doctype html><title>B</title><p>b</p>",
    ])
    defer { server.stop() }

    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(name: "a", rootPath: dir.path, activeTab: 0, tabs: [Self.plain]),
        WorkspaceState(name: "b", rootPath: dir.path, activeTab: 0, tabs: [Self.plain]),
      ], window: window)
    window.isKey = true
    let wsAIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "a" })
    let wsBIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "b" })
    let wsBTab = try XCTUnwrap(wc.workspaces[wsBIndex].tabs.first)

    // wsB のローカルスペースにも遷移済みページを持たせ、syncCurrentWorkspace で mountRuntime が走る条件を作る。
    wc.setBrowserMode(.sheet, animated: false)
    wc.switchWorkspace(to: wsBIndex)
    var finishes = 0
    wc.browserView.onNavigationFinish = { finishes += 1 }
    wc.browserView.load(server.url(for: "/b"))
    pumpMain(until: { finishes >= 1 }, timeout: 5, "wsB ローカルページ読込")
    wc.switchWorkspace(to: wsAIndex)
    wc.browserView.load(server.url(for: "/a"))
    pumpMain(until: { finishes >= 2 }, timeout: 5, "wsA ローカルページ読込")

    // 1. controlFocusTab: wsA ローカル右シート焦点中 → wsB 端末へ遷移しブラウザが奪い返さない。
    wc.browserView.focusBrowser()
    XCTAssertTrue(wc.browserView.focusIsInside)
    guard case .success = wc.controlFocusTab(tabId: wsBTab.id) else {
      return XCTFail("controlFocusTab は success")
    }
    XCTAssertEqual(wc.browserMode, .sheet, "右シートは維持")
    XCTAssertTrue(window.firstResponder === wsBTab.surface, "切替先 wsB 端末へ焦点が移る")
    XCTAssertFalse(wc.browserView.focusIsInside, "syncCurrentWorkspace でブラウザが焦点を奪い返さない")
    XCTAssertFalse(wc.browserWasFocused)

    // 2. controlOpenFile: wsA ローカル右シート URL 編集中 → wsB エディターへ遷移しブラウザが奪い返さない。
    wc.switchWorkspace(to: wsAIndex)
    wc.browserView.focusBrowser()
    wc.browserView.beginURLEditing()
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: wc.browserView.barHost) == true
      }, "wsA ローカル URL 欄編集中")
    guard case .success = wc.controlOpenFile(tabId: wsBTab.id, path: file.path) else {
      return XCTFail("controlOpenFile は success")
    }
    XCTAssertFalse(wc.browserView.isEditingURL, "URL 編集が外因終了される")
    XCTAssertTrue(wsBTab.group.view.editor.focusIsInside, "切替先 wsB エディターへ焦点が移る")
    XCTAssertFalse(wc.browserView.focusIsInside, "ブラウザがエディターから焦点を奪い返さない")

    // 3. select(.tab, inWorkspaceAt:): wsA ローカル右シート焦点中 → wsB 端末へ遷移し奪い返さない。
    wc.switchWorkspace(to: wsAIndex)
    wc.browserView.focusBrowser()
    wc.select(.tab(wsBTab), inWorkspaceAt: wsBIndex)
    XCTAssertTrue(window.firstResponder === wsBTab.surface, "select による別 WS 遷移で端末に焦点")
    XCTAssertFalse(wc.browserView.focusIsInside, "select 後の syncCurrentWorkspace で奪い返さない")
  }
}
