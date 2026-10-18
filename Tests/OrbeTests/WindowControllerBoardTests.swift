import AppKit
import XCTest

@testable import Orbe

/// Home のボード——タブ行の左端の固定のセルと、選んだときに端末の代わりに出る面——を実窓で固定する。
///
/// 壊れると何が起きるか。ボードを選んでいる間にキーや操作が隠れたタブへ届くと、見えていないタブが閉じる・改名が
/// 始まる・検索が開く。焦点の無いボードがキーを取ると、パレットを開いている間に裏の選択が動く。閉じたタブの画面が content に
/// 残ると、ボードの後ろで surface がリークする。裏で起こしたタブがボードを押しのけると、`start_task` が人の
/// 見ている画面を奪う。`list_tabs` が隠れたタブを active と言うと、外の agent が人の見ているタブを取り違える。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerBoardTests: OrbeTestCase {
  /// 画面外に出した（ordered-in の）窓。終わりに下ろす。
  private var shown: WindowController?

  override func setUp() {
    super.setUp()
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay を出さない。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  override func tearDown() {
    shown?.window.orderOut(nil)
    shown = nil
    super.tearDown()
  }

  // MARK: - fixture

  /// Home を前面にし、素のシェルのタブを `count` 枚開いてから、ボードのセルをクリックした WindowController。
  func homeOnBoard(tabs count: Int) throws -> WindowController {
    let wc = WindowController()
    wc.switchWorkspace(to: try XCTUnwrap(wc.store.homeIndex))
    for _ in 0..<count { wc.newTab() }
    wc.statusModel.onSelectBoard()
    return wc
  }

  /// 止めている自動化を 2 件置く——起動でも回らず、取得もコマンドなので本物の agent は起きない。
  @MainActor private func savePausedAutomations() {
    DesignSceneFixtures.seedAutomations(
      DesignSceneFixtures.boardAutomationSamples().prefix(2).map {
        var sample = $0
        sample.paused = true
        sample.definition.parts[0] = DesignSceneFixtures.commandPart(
          "fetch", "取る", .scheduled(.every(1800)), script: "true", coverage: .currentSet)
        return sample
      })
  }

  /// 窓を画面外に出す。非アクティブなアプリの窓は key にならないが、`NSApp.sendEvent` は ordered-in の窓の first responder
  /// へ届ける。
  func show(_ wc: WindowController) {
    shown = wc
    NSApplication.shared.setActivationPolicy(.accessory)
    wc.window.makeKeyAndOrderFront(nil)
  }

  /// content に載っていて見えているビュー。
  func visibleContent(_ wc: WindowController) -> [NSView] {
    wc.model.content.subviews.filter { !$0.isHidden }
  }

  /// 見えているのは `tab` の連の器だけで、その器は `tab` の端末を見せている。
  func assertShows(
    _ wc: WindowController, _ tab: TerminalTab, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(visibleContent(wc), [tab.group.view], file: file, line: line)
    XCTAssertTrue(tab.group.view.shownTerminal === tab.terminal, file: file, line: line)
  }

  /// content に載っている器のどれかが `tab` の端末を抱えているか。
  func contentHolds(_ wc: WindowController, terminalOf tab: TerminalTab) -> Bool {
    wc.model.content.subviews.contains { view in
      (view as? GroupFacesView)?.terminals.contains { $0 === tab.terminal } == true
    }
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
    XCTAssertFalse(wc.model.content.subviews.contains { $0 === wc.boardView }, "ボードの面も載らない")

    let home = try XCTUnwrap(wc.store.homeIndex)
    wc.switchWorkspace(to: home)
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.boardLabel, "Home")
    wc.renameWorkspace(home, to: "秘書")
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.boardLabel, "秘書", "改名に追随する")
  }

  // MARK: - 選ぶ

  /// セルをクリックすると、端末の代わりにボードが出て、chrome はどの隠れたタブも選んでいるように見せない。
  func testClickingTheBoardCellShowsTheBoardInPlaceOfTheTabs() throws {
    let wc = try homeOnBoard(tabs: 2)
    wc.flushChrome()

    XCTAssertEqual(visibleContent(wc), [wc.boardView], "見えるのはボードだけ")
    XCTAssertEqual(wc.statusModel.selection, .board, "タブのセルは選択の見た目にならない")
    XCTAssertTrue(wc.statusModel.location.isEmpty, "隠れたタブの現在地を出さない")
    XCTAssertNil(wc.statusModel.faceDots, "隠れたタブの位置ドットを出さない")
    XCTAssertFalse(wc.model.contentIsEmpty, "空表示の地を重ねない")
  }

  // MARK: - キー

  /// ボードに焦点がある間（入ったときの依頼の欄にあっても）、タブに効くキー（⌘W・⌘R・⌘E・⌘F・⌘+）はボードで止まり、
  /// どのタブにも何も起こさない。
  @MainActor func testTabKeysStopAtTheFocusedBoard() throws {
    let wc = try homeOnBoard(tabs: 2)
    show(wc)
    pump()
    XCTAssertTrue(wc.window.firstResponder is NSTextView, "前提: 焦点は依頼の欄")
    let tabs = wc.current.tabs

    for key in ["w", "r", "e", "f", "+"] {
      XCTAssertTrue(wc.window.performKeyEquivalent(with: .key(key)), "⌘\(key) はボードで止まる")
    }

    XCTAssertEqual(wc.current.tabs.count, 2, "⌘W でタブは閉じない")
    XCTAssertEqual(wc.current.selection, .board, "ボードのまま")
    XCTAssertNil(wc.statusModel.editingIndex, "⌘R で隠れたタブの改名は始まらない")
    XCTAssertTrue(tabs.allSatisfy { $0.group.faces == FaceLayout.terminalOnly }, "⌘E で面は動かない")
    XCTAssertTrue(tabs.allSatisfy { $0.surface.searchBar == nil }, "⌘F で検索は開かない")
  }

  /// ボードに焦点がある間も ⌘⇧] は効き、ボードから先頭のタブへ移る。
  func testCycleKeyLeavesTheBoardForTheFirstTab() throws {
    let wc = try homeOnBoard(tabs: 2)
    let first = wc.current.tabs[0]

    XCTAssertTrue(wc.window.performKeyEquivalent(with: Self.nextTabKey))

    XCTAssertEqual(wc.current.selection, .tab(first))
    assertShows(wc, first)  // ボードは隠れて先頭のタブが見える
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

  /// 焦点が外から入る（ボードを選ぶ・パレットを閉じる・workspace を戻る）と、部品は欄から始まり、↓ で一覧の先頭へ下りる。
  /// 一覧で選んでいた行は入り直すと保たないが、裏のタブが閉じただけ（焦点は中のまま）なら保つ。
  @MainActor func testEnteringTheBoardStartsAtTheRequestField() throws {
    savePausedAutomations()
    let wc = WindowController()
    show(wc)
    let home = try XCTUnwrap(wc.store.homeIndex)
    wc.switchWorkspace(to: home)
    wc.newTab()
    let behind = try XCTUnwrap(wc.activeTab)
    let automation = wc.board.automation

    wc.statusModel.onSelectBoard()
    pump()
    XCTAssertEqual(automation.place, .request, "ボードを選ぶと欄")
    try pressDown(wc)
    XCTAssertEqual(automation.selectedAutomation?.id, 1, "↓ で一覧の先頭")
    try pressDown(wc)
    XCTAssertEqual(automation.selectedAutomation?.id, 2)

    guard case .success = wc.controlCloseTab(tabId: behind.id) else {
      return XCTFail("close_tab は success")
    }
    pump()
    XCTAssertEqual(automation.selectedAutomation?.id, 2, "裏のタブが閉じても、焦点は中のままなので選択を保つ")

    wc.showWorkspacePalette()
    wc.window.makeFirstResponder(nil)  // パレットの入力欄が焦点を持っていった状態
    wc.dismissPalette()
    pump()
    XCTAssertEqual(automation.place, .request, "パレットを閉じると欄から")
    try pressDown(wc)
    XCTAssertEqual(automation.selectedAutomation?.id, 1, "↓ で一覧の先頭")

    wc.switchWorkspace(to: try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "default" }))
    XCTAssertFalse(wc.boardView.focusIsInside, "前提: 他の workspace ではそのタブが焦点")
    wc.switchWorkspace(to: home)
    pump()
    XCTAssertEqual(automation.place, .request, "workspace を戻ると欄から")
    try pressDown(wc)
    XCTAssertEqual(automation.selectedAutomation?.id, 1, "キーがボードに効く")
  }

  /// 依頼の欄で打っている途中にボードを離れて戻ると（パレットを閉じる・端末タブから戻る・workspace を戻る）、焦点は欄へ戻り、
  /// 打ちかけは全文が選ばれている（⌘⇧X の入力欄と同じ）。端末タブを選んでいる間、隠れた欄はキーを取らない。
  @MainActor func testFocusReturnsToTheRequestFieldWhereItWasLeft() throws {
    let wc = WindowController()
    show(wc)
    let home = try XCTUnwrap(wc.store.homeIndex)
    wc.switchWorkspace(to: home)
    wc.newTab()
    let tab = try XCTUnwrap(wc.activeTab)
    let automation = wc.board.automation

    wc.statusModel.onSelectBoard()
    XCTAssertEqual(automation.place, .request, "0 件なら初めから欄")
    try press(wc, keyCode: 0, "a")
    try press(wc, keyCode: 0, "b")
    XCTAssertEqual(automation.requestText, "ab")

    wc.showWorkspacePalette()
    wc.window.makeFirstResponder(nil)  // パレットの入力欄が焦点を持っていった状態
    wc.dismissPalette()
    pump()
    try assertFieldSelectsAll(wc, "ab", "パレットを閉じると欄へ")

    wc.select(.tab(tab))
    try press(wc, keyCode: 0, "x")
    XCTAssertEqual(automation.requestText, "ab", "端末タブの間は隠れた欄にキーが届かない")
    wc.statusModel.onSelectBoard()
    pump()
    try assertFieldSelectsAll(wc, "ab", "ボードへ戻ると欄へ")

    wc.switchWorkspace(to: try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "default" }))
    wc.switchWorkspace(to: home)
    pump()
    try assertFieldSelectsAll(wc, "ab", "workspace を戻ると欄へ")
  }

  /// ボードの上に ⌘⇧X を開いている間に自動化がすべて消えても（⌘⇧X で最後の 1 件を消す）、ボードの欄は焦点を奪わず、
  /// 打鍵は ⌘⇧X の入力欄に届いたまま。
  @MainActor func testAutomationsVanishingUnderThePaletteLeaveTheFocusInThePalette() throws {
    savePausedAutomations()
    let wc = WindowController()
    show(wc)
    wc.switchWorkspace(to: try XCTUnwrap(wc.store.homeIndex))
    let automation = wc.board.automation
    wc.statusModel.onSelectBoard()
    try pressDown(wc)
    XCTAssertEqual(automation.place, .list, "前提: 一覧にいる")

    wc.showTaskPalette()
    pump()
    let palette = try XCTUnwrap(wc.model.taskPalette)
    for id in automation.ids { try wc.automationRunner.delete(id) }
    pump()

    XCTAssertEqual(automation.place, .request, "前提: 行がすべて消えて欄になった")
    try press(wc, keyCode: 0, "x")
    XCTAssertEqual(palette.query, "x", "打鍵は ⌘⇧X の入力欄に届く")
    XCTAssertEqual(automation.requestText, "", "ボードの欄は焦点を奪わない")
  }

  private func assertFieldSelectsAll(
    _ wc: WindowController, _ text: String, _ message: String
  ) throws {
    let editor = try XCTUnwrap(wc.window.firstResponder as? NSTextView, message)
    XCTAssertEqual(editor.string, text, message)
    XCTAssertEqual(
      editor.selectedRange(), NSRange(location: 0, length: (text as NSString).length), message)
  }

  /// 焦点の当て直しが SwiftUI に写るのを待ってから ↓ を窓へ送る。
  private func pressDown(_ wc: WindowController) throws {
    try press(wc, keyCode: 125, "\u{F701}", [.numericPad, .function])
  }

  /// 焦点の当て直しが SwiftUI に写るのを待ってからキーを窓へ送る。
  private func press(
    _ wc: WindowController, keyCode: UInt16, _ characters: String,
    _ flags: NSEvent.ModifierFlags = []
  ) throws {
    pump()
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wc.window.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: keyCode)
    NSApp.sendEvent(try XCTUnwrap(event))
    pump()
  }

  func pump() {
    let end = Date().addingTimeInterval(0.3)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
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
    assertShows(wc, target)
    XCTAssertTrue(wc.window.firstResponder === target.surface)
  }

  /// ボードのまま Home を離れ、別の workspace から `focus_tab`（メニューバー・`orb tab focus` と同じ経路）で Home のタブへ移ると、
  /// 焦点はそのタブに残る——戻る途中でボードが一瞬選ばれても、そのときの欄への焦点の合図が後から端末の焦点を奪わない。
  @MainActor func testFocusTabFromAnotherWorkspaceLeavesNoFocusRequestBehind() throws {
    let wc = try homeOnBoard(tabs: 1)
    show(wc)
    pump()
    let target = wc.current.tabs[0]
    wc.switchWorkspace(to: try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "default" }))

    guard case .success = wc.controlFocusTab(tabId: target.id) else {
      return XCTFail("focus_tab は success")
    }
    pump()

    XCTAssertEqual(wc.current.selection, .tab(target))
    XCTAssertTrue(wc.window.firstResponder === target.surface, "焦点はタブの端末に残る")
  }
}
