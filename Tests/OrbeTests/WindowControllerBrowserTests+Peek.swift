import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 3 層構成における `⌥` 単層めくり（最上層 1 枚のみめくる・下層エディター監視抑止・全面めくりピル下層判定）と、
/// `visibleTab` および完了通知（`done`）の抑制・消費規則を実窓で守る。
extension WindowControllerBrowserTests {
  // MARK: - ⌥ 単層めくり

  /// エディター＋右シート並走時の `⌥` 長押しは最上層のブラウザのみをめくり、下のエディターを動かさず、
  /// ブラウザ透かし中は下層エディターの押下監視（一覧の閉鎖）も抑止する。全面めくりピルは下層種別へ追従する。
  @MainActor
  func testOptionHoldPeeksOnlyTheTopmostLayerAndSuppressesEditorPressMonitor() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain])],
      window: window)
    let option = OptionHoldDriver(wc)
    window.isKey = true
    let tab = try XCTUnwrap(wc.activeTab)
    let pane = tab.group.view.editor
    _ = try tab.group.editor.open(try caseFile("a.txt", "x"), as: .pinned)

    // エディター（Z=1）＋右シート（Z=2）並走: ⌥ でブラウザだけめくり、下のエディターは .editor のまま。
    wc.toggleEditorFace()
    wc.setBrowserMode(.sheet, animated: false)
    let focusBefore = wc.window.firstResponder
    option.hold()
    XCTAssertTrue(wc.browserPeeking)
    XCTAssertTrue(wc.browserView.isPeeking)
    XCTAssertEqual(tab.group.view.mode, .editor, "下のエディターはめくらず全幅で残す")
    XCTAssertTrue(wc.window.firstResponder === focusBefore, "焦点は動かさない")

    // ブラウザ透かし中は下層エディターの isPeekingOverlay が真になり、一覧外押下でも一覧が閉じない。
    pane.toggleItemList()
    XCTAssertTrue(pane.itemList.isOpen, "前提: 下層エディターの一覧が開いている")
    let outside = pane.convert(NSPoint(x: 10, y: 10), to: nil)
    pane.pressWillArrive(.mouse(.leftMouseDown, at: outside, in: window))
    XCTAssertTrue(pane.itemList.isOpen, "ブラウザ透かし中は下層エディターの一覧を閉じない")

    // ブラウザ透かし中に下層 editorShownTab が変わってもブラウザ透かしを壊さない。
    wc.editorShownTab = nil
    XCTAssertTrue(wc.browserPeeking, "Z=2 めくり中は Z=1 の変化で optionHold を打ち切らない")

    option.send([])
    XCTAssertFalse(wc.browserPeeking)
    XCTAssertFalse(wc.browserView.isPeeking)

    // 全面ブラウザの Peek ピルは直下の層（端末・エディター・ボード・空）へ追従する。
    wc.setBrowserMode(.full, animated: false)
    XCTAssertEqual(wc.browserView.toolbar.peekUnderlay, .terminal)
    wc.editorShownTab = tab
    wc.syncPeekState(animated: false)
    XCTAssertEqual(wc.browserView.toolbar.peekUnderlay, .editor)
    wc.switchWorkspace(to: try XCTUnwrap(wc.store.homeIndex))
    XCTAssertEqual(wc.browserView.toolbar.peekUnderlay, .board)
    wc.switchWorkspace(to: try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "main" }))
    wc.closeTab(tab, origin: .gesture)
    XCTAssertEqual(wc.browserView.toolbar.peekUnderlay, .window)
  }

  /// エディターめくり中にブラウザを開くと `syncPeekState` が下層エディターの透かしも確実に解き、
  /// ⌥ を離すまで次を始めない。
  func testOpeningBrowserWhilePeekingEditorClearsEditorPeekCleanly() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain])],
      window: window)
    let option = OptionHoldDriver(wc)
    window.isKey = true
    let tab = try XCTUnwrap(wc.activeTab)

    wc.toggleEditorFace()
    option.hold()
    XCTAssertEqual(tab.group.view.mode, .peek, "前提: エディターをめくり中")

    wc.setBrowserMode(.sheet, animated: false)
    XCTAssertFalse(wc.optionHold.isHolding)
    XCTAssertEqual(tab.group.view.mode, .editor, "ブラウザを開くと下層エディターの透かしが解ける")
    XCTAssertFalse(wc.browserView.isPeeking, "⌥ を押したままでもブラウザが即めくり状態にならない")
  }

  // MARK: - visibleTab と done 通知制御

  /// 全面ブラウザ（非めくり）中のみ端末が見えないため `done` 通知を抑制せず残し、
  /// 右シート表示中・全面めくり中・全面解除（閉鎖／右シート化）で端末が見えれば `done` を抑制・消費する。
  func testVisibleTabAndDoneNotificationControlAcrossThreeLayers() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain])],
      window: window)
    let option = OptionHoldDriver(wc)
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    window.isKey = true
    let tab = try XCTUnwrap(wc.activeTab)

    // 全面ブラウザ（非めくり）: 端末が見えないので done 通知・音が鳴りバッジが残る。
    wc.setBrowserMode(.full, animated: false)
    XCTAssertNil(wc.visibleTab)
    reportDone(wc, tab)
    XCTAssertEqual(tab.agentState, "done")
    XCTAssertEqual(sound.played.map(\.event), [.done])
    XCTAssertEqual(wc.attentionStore.transient?.row?.state, "done")

    // 全面めくり（下層が端末）: 端末が見えるので visibleTab になり done が消費される。
    option.hold()
    XCTAssertTrue(wc.visibleTab === tab)
    XCTAssertEqual(tab.agentState, "idle", "全面めくりで露出した端末の done を消費する")
    option.send([])

    // 全面 → 右シート切替でも端末が露出するので done が消費される。
    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "working"))
    reportDone(wc, tab)
    XCTAssertEqual(tab.agentState, "done", "前提: 全面中は再び done が残る")
    wc.setBrowserMode(.sheet, animated: false)
    XCTAssertTrue(wc.visibleTab === tab)
    XCTAssertEqual(tab.agentState, "idle", "右シート化で露出した端末の done を消費する")

    // 右シート表示中に届いた done は端末が見えているため音・通知を抑制し即 idle。
    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "working"))
    wc.attentionStore.transient = nil
    let playedBefore = sound.played.count
    reportDone(wc, tab)
    XCTAssertEqual(tab.agentState, "idle")
    XCTAssertEqual(sound.played.count, playedBefore, "右シート表示中は done 音を鳴らさない")
    XCTAssertNil(wc.attentionStore.transient, "右シート表示中は done 知らせを出さない")

    // 全面 → 単独 ⌘B 閉鎖でも端末が露出するので done が消費される。
    wc.setBrowserMode(.full, animated: false)
    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "working"))
    reportDone(wc, tab)
    XCTAssertEqual(tab.agentState, "done", "前提: 全面中は再び done が残る")
    wc.toggleBrowser()
    XCTAssertEqual(wc.browserMode, .closed)
    XCTAssertTrue(wc.visibleTab === tab)
    XCTAssertEqual(tab.agentState, "idle", "単独 ⌘B 閉鎖で露出した端末の done を消費する")

    // 全面ブラウザ＋下層エディターで全面めくりしても端末は見えないため done は残る。
    wc.toggleEditorFace()
    wc.setBrowserMode(.full, animated: false)
    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "working"))
    reportDone(wc, tab)
    option.hold()
    XCTAssertNil(wc.visibleTab, "全面めくりでも下層がエディターなら端末は見えない")
    XCTAssertEqual(tab.agentState, "done")
    option.send([])
  }

  /// 全面ブラウザから下層のエディターへ直接移る操作（`⌘E`・別 workspace のタブへの `open_file`）では、
  /// 端末が一度も見えないため元タブおよび移り先タブの `done` を消費せず残す。
  func testFullBrowserYieldToEditorKeepsDoneOnCoveredAndNonTargetTabs() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [
        WorkspaceState(name: "here", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
        WorkspaceState(name: "there", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
      ], window: window)
    let hereIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "here" })
    let there = try XCTUnwrap(wc.workspaces.first { $0.name == "there" })
    let tabA = try XCTUnwrap(wc.workspaces[hereIndex].tabs.first)
    let tabC = try XCTUnwrap(there.tabs.first)
    _ = wc.controlActivateWorkspace(workspaceId: there.id)
    wc.switchWorkspace(to: hereIndex)
    window.isKey = true

    // 経路 1: 全面ブラウザ上の ⌘E（全面閉＋エディター開）。tabA の端末は見えないので done は残る。
    wc.setBrowserMode(.full, animated: false)
    reportDone(wc, tabA)
    XCTAssertEqual(tabA.agentState, "done", "前提")
    wc.toggleEditorFace()
    XCTAssertEqual(wc.browserMode, .closed)
    XCTAssertTrue(tabA.group.view.isEditorOpen)
    XCTAssertEqual(tabA.agentState, "done", "全面ブラウザ→エディター直行では端末が見えないので done が残る")

    // 経路 2: 全面ブラウザから別 workspace の tabC へ open_file。tabA も tabC も端末は見えない。
    wc.select(0)  // tabA を端末へ戻す
    wc.setBrowserMode(.full, animated: false)
    wc.controlReportAgent(tab: tabA, report: AgentHookReport(agent: "claude", state: "working"))
    reportDone(wc, tabA)
    reportDone(wc, tabC)
    XCTAssertEqual([tabA.agentState, tabC.agentState], ["done", "done"], "前提")
    let file = try caseFile("target.txt", "body")
    guard case .success = wc.controlOpenFile(tabId: tabC.id, path: file.path) else {
      return XCTFail("open_file は success")
    }
    XCTAssertEqual(wc.browserMode, .closed)
    XCTAssertTrue(wc.activeTab === tabC)
    XCTAssertTrue(tabC.group.view.isEditorOpen)
    XCTAssertEqual(tabA.agentState, "done", "移り先ではない tabA の done は消えない")
    XCTAssertEqual(tabC.agentState, "done", "エディターで開いた tabC の done も消えない")
  }
}
