import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 3 層構成における `⌥` 単層めくり（最上層 1 枚のみめくる・下層エディター監視抑止・全面めくりピル下層判定）、
/// `visibleTab`・完了通知（`done`）の抑制・消費規則、および Home ボード自動化通知のブラウザ覆い判定と
/// 通知クリック時（`showAutomation`）のブラウザ閉鎖を実窓で守る。
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

  // MARK: - Home ボードの自動化通知抑制と Z=2 ブラウザ層

  /// Home ボードで自動化を選んで見ている間、ブラウザが非めくりで開いていれば（右シート・全面とも）
  /// 詳細欄が覆われるため通知を抑制せず、閉鎖中または `⌥` めくり中のみ抑制する。
  @MainActor
  func testBoardAutomationNoticeFollowsBrowserCoverAndPeekState() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain])],
      window: window)
    let option = OptionHoldDriver(wc)
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    window.isKey = true

    let def = AutomationDefinition(
      name: "PR 要約", notify: .menuBar,
      nodes: [
        DesignSceneFixtures.agentNode(
          "digest", "要約", .scheduled(.every(1440)), instruction: "要約", deliver: .report)
      ])
    let id = try wc.automationStore.create(def, now: Date()).id
    try wc.automationStore.record(
      id, nodeKey: "digest", trigger: .now, at: Date(),
      outcome: DesignSceneFixtures.reported("PR は 2 件"))
    wc.showAutomation(id)

    // ブラウザ閉鎖中: 見ているので抑制。
    XCTAssertTrue(wc.isViewingAutomation(id))
    wc.notifyAutomationRecorded(id, "digest")
    XCTAssertNil(wc.attentionStore.transient, "ブラウザ閉鎖中は見ている自動化の通知を抑制する")
    XCTAssertTrue(sound.played.isEmpty)

    // 右シート表示中（非めくり）: ボード詳細欄が覆われるため抑制せず通知・音が鳴る。
    wc.setBrowserMode(.sheet, animated: false)
    XCTAssertFalse(wc.isViewingAutomation(id))
    wc.notifyAutomationRecorded(id, "digest")
    XCTAssertNotNil(wc.attentionStore.transient, "右シートで覆われている間は通知を立てる")
    XCTAssertEqual(sound.played.count, 1)

    // 右シート ⌥ めくり中: ボードが見えるので再び抑制。
    wc.attentionStore.transient = nil
    option.hold()
    XCTAssertTrue(wc.isViewingAutomation(id))
    wc.notifyAutomationRecorded(id, "digest")
    XCTAssertNil(wc.attentionStore.transient, "右シートめくり中は通知を抑制する")
    XCTAssertEqual(sound.played.count, 1)
    option.send([])

    // 全面表示中（非めくり）: 覆われているので抑制せず通知・音が鳴る。
    wc.setBrowserMode(.full, animated: false)
    XCTAssertFalse(wc.isViewingAutomation(id))
    wc.notifyAutomationRecorded(id, "digest")
    XCTAssertNotNil(wc.attentionStore.transient, "全面ブラウザで覆われている間は通知を立てる")
    XCTAssertEqual(sound.played.count, 2)

    // 全面 ⌥ めくり中: ボードが見えるので再び抑制。
    wc.attentionStore.transient = nil
    option.hold()
    XCTAssertTrue(wc.isViewingAutomation(id))
    wc.notifyAutomationRecorded(id, "digest")
    XCTAssertNil(wc.attentionStore.transient, "全面めくり中は通知を抑制する")
    XCTAssertEqual(sound.played.count, 2)
    option.send([])
  }

  /// 自動化通知クリック（`showAutomation`）は全面だけでなく右シートも閉じて Home ボード詳細欄を露出し、
  /// 着地後の再通知を抑制する。一方、通常の `select(.board, ...)` による `yieldBrowserToUnderlay` は
  /// 右シートを維持し、全面ブラウザ下の未視認端末の `done` は `showAutomation` でも誤消費しない。
  @MainActor
  func testShowAutomationClosesSheetAndFullBrowserWithoutConsumingCoveredDone() throws {
    let window = OrbeWindowFake()
    let wc = try restore(
      [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain])],
      window: window)
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    window.isKey = true
    let mainIndex = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "main" })
    let homeIndex = try XCTUnwrap(wc.store.homeIndex)
    let mainTab = try XCTUnwrap(wc.workspaces[mainIndex].tabs.first)

    let def = AutomationDefinition(
      name: "定期確認", notify: .menuBar,
      nodes: [
        DesignSceneFixtures.agentNode(
          "check", "確認", .scheduled(.every(1440)), instruction: "確認", deliver: .report)
      ])
    let id = try wc.automationStore.create(def, now: Date()).id
    try wc.automationStore.record(
      id, nodeKey: "check", trigger: .now, at: Date(),
      outcome: DesignSceneFixtures.reported("結果 1 件"))

    // 1. 右シート表示中（別 workspace の端末上・URL 編集中）に showAutomation → 右シートごと閉じてボード詳細を露出。
    wc.setBrowserMode(.sheet, animated: false)
    wc.browserView.beginURLEditing()
    wc.showAutomation(id)
    XCTAssertEqual(wc.browserMode, .closed, "showAutomation は右シートも閉じる")
    XCTAssertFalse(wc.browserView.isEditingURL, "URL 編集状態も解除される")
    XCTAssertTrue(wc.store.isHome(wc.activeWorkspace))
    XCTAssertEqual(wc.current.selection, .board)
    XCTAssertTrue(wc.boardView.focusIsInside, "showAutomation 後にボードへ焦点が移る")
    XCTAssertFalse(wc.browserView.isBrowserFocused, "ブラウザの焦点見た目が外れる")
    XCTAssertTrue(wc.isViewingAutomation(id), "右シートが閉じたため詳細欄を閲覧中として扱う")
    wc.attentionStore.transient = nil
    let playedBefore = sound.played.count
    wc.notifyAutomationRecorded(id, "check")
    XCTAssertNil(wc.attentionStore.transient, "詳細欄露出後の同自動化通知は抑制される")
    XCTAssertEqual(sound.played.count, playedBefore)

    // 2. 既に Home ボード選択中に右シートが開いていても showAutomation で閉じる（inPlace 経路）。
    wc.setBrowserMode(.sheet, animated: false)
    XCTAssertFalse(wc.isViewingAutomation(id), "前提: 右シートで詳細欄が覆われている")
    wc.showAutomation(id)
    XCTAssertEqual(wc.browserMode, .closed, "Home ボード上の右シートも showAutomation で閉じる")
    XCTAssertTrue(wc.boardView.focusIsInside, "Home ボード上の inPlace 経路でもボードへ焦点が移る")
    XCTAssertFalse(wc.browserView.isBrowserFocused, "ブラウザの焦点見た目が外れる")
    XCTAssertTrue(wc.isViewingAutomation(id))

    // 3. 全面ブラウザで未視認端末の done を覆っている状態で showAutomation → 全面を閉じつつ done は消費しない。
    wc.switchWorkspace(to: mainIndex)
    wc.setBrowserMode(.full, animated: false)
    reportDone(wc, mainTab)
    XCTAssertEqual(mainTab.agentState, "done", "前提: 全面ブラウザ下の未視認端末に done が残る")
    wc.showAutomation(id)
    XCTAssertEqual(wc.browserMode, .closed, "showAutomation は全面ブラウザも閉じる")
    XCTAssertTrue(wc.isViewingAutomation(id))
    XCTAssertEqual(mainTab.agentState, "done", "showAutomation で未視認端末の done を誤消費しない")

    // 4. 対比: 通常のボード遷移（yieldBrowserToUnderlay）は右シートを残す契約を崩さない。
    wc.switchWorkspace(to: mainIndex)
    wc.setBrowserMode(.sheet, animated: false)
    wc.select(.board, inWorkspaceAt: homeIndex)
    XCTAssertEqual(wc.browserMode, .sheet, "通常の select(.board) は右シートを維持する")
    XCTAssertTrue(wc.browserCoversBoard, "右シートが残るためボードは覆われたまま")
    XCTAssertTrue(wc.boardView.focusIsInside, "通常の select(.board) でボードへ焦点が移る")
    XCTAssertFalse(wc.browserView.focusIsInside, "右シートに焦点が残らない")
    XCTAssertFalse(wc.browserView.isBrowserFocused, "右シートの焦点見た目が外れる")
  }
}
