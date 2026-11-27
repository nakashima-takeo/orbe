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
}
