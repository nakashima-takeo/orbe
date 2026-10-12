import AppKit
import XCTest

@testable import Orbe

/// ボードと content の照合——タブを閉じる・裏のタブの cd・別の workspace で起こす・新しいタブのどの経路が照合を呼んでも、
/// ボードは外れず、見え方は選択どおり。
extension WindowControllerBoardTests {
  // MARK: - 閉じる

  /// Home の最後のタブを閉じる（⌘W）とボードが出て、空表示にならず、閉じたタブの画面も残らない。
  func testClosingTheLastHomeTabShowsTheBoard() throws {
    let wc = try homeOnBoard(tabs: 1)
    let tab = wc.current.tabs[0]
    wc.select(.tab(tab))

    wc.handleWindowCommand(.closeTab)
    XCTAssertTrue(waitUntil { wc.current.tabs.isEmpty }, "前提: ⌘W でタブが閉じる")

    XCTAssertEqual(wc.current.selection, .board)
    XCTAssertEqual(visibleContent(wc), [wc.boardView])
    XCTAssertFalse(wc.model.contentIsEmpty, "空表示にならない")
    XCTAssertFalse(contentHolds(wc, terminalOf: tab), "閉じたタブの画面は残らない")
  }

  /// ボードを選んでいる間に Home の他のタブが閉じても、ボードは出たままで、閉じたタブの画面は残らない。
  func testATabClosingBehindTheBoardLeavesNoTrace() throws {
    let wc = try homeOnBoard(tabs: 2)
    let closing = wc.current.tabs[1]

    guard case .success = wc.controlCloseTab(tabId: closing.id) else {
      return XCTFail("close_tab は success")
    }

    XCTAssertEqual(wc.current.selection, .board)
    XCTAssertEqual(visibleContent(wc), [wc.boardView])
    XCTAssertFalse(contentHolds(wc, terminalOf: closing), "閉じたタブの画面は残らない")
  }

  // MARK: - 照合を呼ぶ他の経路

  /// ボードを選んでいる間に裏のタブが cd で別の連へ移っても、ボードは出たままで、焦点もボードに残る。
  @MainActor func testACdBehindTheBoardKeepsTheBoardShownAndFocused() throws {
    let wc = try homeOnBoard(tabs: 2)
    show(wc)
    pump()
    XCTAssertTrue(wc.window.firstResponder is NSTextView, "前提: 焦点は依頼の欄")
    let moved = wc.current.tabs[1]

    moved.surface.currentPwd = "/tmp"  // OSC 7

    XCTAssertFalse(moved.group === wc.current.tabs[0].group, "前提: 別の連へ移る")
    XCTAssertEqual(wc.current.selection, .board)
    XCTAssertEqual(visibleContent(wc), [wc.boardView])
    pump()
    XCTAssertTrue(wc.window.firstResponder is NSTextView, "焦点はボードのまま")
  }

  /// ボードを選んでいる間に別の workspace でタブを起こしても、ボードは出たまま。
  func testATabWokenInAnotherWorkspaceLeavesTheBoardShown() throws {
    let wc = try homeOnBoard(tabs: 1)
    let other = try XCTUnwrap(wc.workspaces.indices.first { $0 != wc.activeWorkspace })

    let opened = try XCTUnwrap(wc.openTab(workspaceIndex: other, cwd: "/tmp"))

    XCTAssertEqual(wc.current.selection, .board)
    XCTAssertEqual(visibleContent(wc), [wc.boardView])
    let tab = try XCTUnwrap(wc.workspaces[other].tabs.first { $0.id == opened.tabId })
    XCTAssertNotNil(tab.surface.surfacePtr, "そのタブは裏で起きる")
  }

  // MARK: - 新しいタブ

  /// ボードから開いた新しいタブは選ばれて見え、隠れたタブの場所でなく Home の root で起きる。
  func testNewTabFromTheBoardOpensAtHomeRootAndIsShown() throws {
    let wc = WindowController()
    let home = try XCTUnwrap(wc.store.homeIndex)
    wc.switchWorkspace(to: home)
    _ = wc.openTab(workspaceIndex: home, cwd: "/tmp")
    wc.statusModel.onSelectBoard()

    wc.newTab()

    let opened = try XCTUnwrap(wc.activeTab, "新しいタブが選ばれる")
    XCTAssertEqual(opened.cwd, wc.current.rootPath, "Home の root で起きる")
    assertShows(wc, opened)
  }

  /// 裏で起こすタブ（`select: false` の spawn——秘書・`start_task` と同じ経路）は、ボードを押しのけずに起きる。
  func testUnselectedSpawnWakesBehindTheBoard() throws {
    let wc = try homeOnBoard(tabs: 0)
    let homeId = wc.current.id

    let tabId = try XCTUnwrap(
      wc.controlSpawn(workspaceId: homeId, cwd: nil, command: nil, selects: false))

    XCTAssertEqual(wc.current.selection, .board, "ボードのまま")
    XCTAssertEqual(visibleContent(wc), [wc.boardView])
    let opened = try XCTUnwrap(wc.controlResolveTab(tabId))
    XCTAssertTrue(waitUntil { opened.surface.surfacePtr != nil }, "そのタブは起きる")
  }
}
