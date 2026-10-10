import AppKit
import XCTest

@testable import Orbe

/// Home のボード——タブ行の左端の固定のセルと、選んだときに端末の代わりに出る面——を実窓で固定する。
///
/// 壊れると何が起きるか。ボードを選んでいる間にキーや操作が隠れたタブへ届くと、見えていないタブが閉じる・改名が
/// 始まる・検索が開く。焦点の無いボードがキーを取ると、パレットを開いている間に裏の選択が動く。閉じたタブの画面が content に
/// 残ると、ボードの後ろで surface がリークする。裏で起こしたタブがボードを押しのけると、秘書や `start_task` が人の
/// 見ている画面を奪う。`list_tabs` が隠れたタブを active と言うと、外の agent が人の見ているタブを取り違える。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerBoardTests: OrbeTestCase {
  override func setUp() {
    super.setUp()
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay を出さない。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  // MARK: - fixture

  /// Home を前面にし、素のシェルのタブを `count` 枚開いてから、ボードのセルをクリックした WindowController。
  private func homeOnBoard(tabs count: Int) throws -> WindowController {
    let wc = WindowController()
    wc.switchWorkspace(to: try XCTUnwrap(wc.store.homeIndex))
    for _ in 0..<count { wc.newTab() }
    wc.statusModel.onSelectBoard()
    return wc
  }

  /// content に載っていて見えているビュー。
  private func visibleContent(_ wc: WindowController) -> [NSView] {
    wc.model.content.subviews.filter { !$0.isHidden }
  }

  /// content に載っているビューの中に `view` があるか。
  private func contentHolds(_ wc: WindowController, _ view: NSView) -> Bool {
    wc.model.content.subviews.contains { $0 === view }
  }

  private static let nextTabKey = NSEvent.key("}", [.command, .shift])

  // MARK: - タブ行のセル

  /// ボードのセルは Home のタブ行にだけ出て、ラベルは workspace 名に追随する。Home でない workspace はボードを選べない。
  func testOnlyHomeHasTheBoardCellLabelledWithItsName() throws {
    let wc = WindowController()
    wc.flushChrome()
    XCTAssertNil(wc.statusModel.boardLabel, "Home でない workspace にセルは無い")
    wc.select(.board)
    XCTAssertNotEqual(wc.current.selection, .board, "Home でない workspace はボードを選べない")
    XCTAssertFalse(contentHolds(wc, wc.boardView), "ボードの面も載らない")

    let home = try XCTUnwrap(wc.store.homeIndex)
    wc.switchWorkspace(to: home)
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.boardLabel, "Home")
    wc.renameWorkspace(home, to: "秘書")
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.boardLabel, "秘書", "改名に追随する")
  }

  // MARK: - 選ぶ

  /// セルをクリックすると、端末の代わりにボードが出て焦点を取り、タブのセルはどれも選択の見た目にならない。
  func testClickingTheBoardCellShowsTheBoardInPlaceOfTheTabs() throws {
    let wc = try homeOnBoard(tabs: 2)
    wc.flushChrome()

    XCTAssertEqual(visibleContent(wc), [wc.boardView], "見えるのはボードだけ")
    XCTAssertEqual(wc.statusModel.selection, .board, "タブのセルは選択の見た目にならない")
    XCTAssertFalse(wc.model.contentIsEmpty, "空表示の地を重ねない")
    XCTAssertTrue(wc.window.firstResponder === wc.boardView, "焦点はボード")
  }

  // MARK: - キー

  /// ボードに焦点がある間、タブに効くキー（⌘W・⌘R・⌘E・⌘F・⌘+）はボードで止まり、どのタブにも何も起こさない。
  func testTabKeysStopAtTheFocusedBoard() throws {
    let wc = try homeOnBoard(tabs: 2)
    let tabs = wc.current.tabs

    for key in ["w", "r", "e", "f", "+"] {
      XCTAssertTrue(wc.window.performKeyEquivalent(with: .key(key)), "⌘\(key) はボードで止まる")
    }

    XCTAssertEqual(wc.current.tabs.count, 2, "⌘W でタブは閉じない")
    XCTAssertEqual(wc.current.selection, .board, "ボードのまま")
    XCTAssertNil(wc.statusModel.editingIndex, "⌘R で隠れたタブの改名は始まらない")
    XCTAssertTrue(tabs.allSatisfy { $0.faces == FaceLayout.terminalOnly }, "⌘E で面は動かない")
    XCTAssertTrue(tabs.allSatisfy { $0.surface.searchBar == nil }, "⌘F で検索は開かない")
  }

  /// ボードに焦点がある間も ⌘⇧] は効き、ボードから先頭のタブへ移る。
  func testCycleKeyLeavesTheBoardForTheFirstTab() throws {
    let wc = try homeOnBoard(tabs: 2)
    let first = wc.current.tabs[0]

    XCTAssertTrue(wc.window.performKeyEquivalent(with: Self.nextTabKey))

    XCTAssertEqual(wc.current.selection, .tab(first))
    XCTAssertEqual(visibleContent(wc), [first.view], "ボードは隠れて先頭のタブが見える")
  }

  /// 見えているボードでも、焦点が外（ボードの上に開いたパレット）にある間はキーを取らない——⌘⇧] で裏の選択が動かない。
  func testBoardTakesNoKeysWhileFocusIsElsewhere() throws {
    let wc = try homeOnBoard(tabs: 1)
    wc.showWorkspacePalette()
    wc.window.makeFirstResponder(nil)  // パレットの入力欄が焦点を持っていった状態（窓に出さないので自分では取らない）

    XCTAssertFalse(wc.window.performKeyEquivalent(with: Self.nextTabKey))

    XCTAssertEqual(wc.current.selection, .board, "ボードのまま")
  }

  // MARK: - 焦点

  /// ボードを選んでいれば、パレットを閉じたとき・workspace を行き来したとき、焦点はボードへ戻る。
  func testFocusReturnsToTheBoard() throws {
    let wc = try homeOnBoard(tabs: 0)

    wc.showWorkspacePalette()
    wc.window.makeFirstResponder(nil)  // パレットの入力欄が焦点を持っていった状態（窓に出さないので自分では取らない）
    wc.dismissPalette()
    XCTAssertTrue(wc.window.firstResponder === wc.boardView, "パレットを閉じるとボードへ")

    let home = wc.activeWorkspace
    wc.switchWorkspace(to: try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "default" }))
    XCTAssertFalse(wc.window.firstResponder === wc.boardView, "前提: 他の workspace ではそのタブが焦点")
    wc.switchWorkspace(to: home)
    XCTAssertTrue(wc.window.firstResponder === wc.boardView, "workspace を戻るとボードへ")
  }

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
    XCTAssertFalse(contentHolds(wc, tab.view), "閉じたタブの画面は残らない")
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
    XCTAssertFalse(contentHolds(wc, closing.view), "閉じたタブの画面は残らない")
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
    XCTAssertEqual(visibleContent(wc), [opened.view])
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

  // MARK: - 制御 API

  /// ボードを選んでいる workspace では、`list_tabs` はどのタブも active と言わない。
  func testListTabsMarksNoTabActiveWhileTheBoardIsSelected() throws {
    let wc = try homeOnBoard(tabs: 2)
    let homeId = wc.current.id

    let homeRows = wc.controlListTabs().filter { $0["workspaceId"] as? Int == homeId }

    XCTAssertEqual(homeRows.count, 2, "タブは 2 枚とも出る（ボードは出ない）")
    XCTAssertTrue(homeRows.allSatisfy { $0["active"] as? Bool == false })
  }

  /// `focus_tab` でタブを指すと、ボードから外れてそのタブが見え、焦点を取る。
  func testFocusTabLeavesTheBoard() throws {
    let wc = try homeOnBoard(tabs: 2)
    let target = wc.current.tabs[1]

    guard case .success = wc.controlFocusTab(tabId: target.id) else {
      return XCTFail("focus_tab は success")
    }

    XCTAssertEqual(wc.current.selection, .tab(target))
    XCTAssertEqual(visibleContent(wc), [target.view])
    XCTAssertTrue(wc.window.firstResponder === target.surface)
  }
}
