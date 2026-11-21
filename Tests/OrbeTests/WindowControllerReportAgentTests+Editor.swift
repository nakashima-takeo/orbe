import AppKit
import XCTest

@testable import Orbe

/// エディターを開いている間の「見ているタブ」——端末が覆われていて結果が見えないので、前面の窓で選んでいるタブでも見ている
/// タブに数えない。⌥ で透かしている間は端末が見えているので数える。別の workspace のタブへ移るとき（`focus_tab`・`open_file`）は、
/// 移り先ではないタブを途中で見ているタブにしない。
///
/// 壊れると何が起きるか。エディターで文書を読んでいる間に終わったエージェントの音も知らせも出ず、done の印も消えて、終わった
/// ことに気づけない。透かして結果を見たのに done の印が残る、あるいは目の前に結果が出ているのに音と知らせが出る。Attention
/// パレットやエージェントの `open_file` で別の workspace のタブへ移るだけで、そこで選んでいた別のタブの done が消える。
extension WindowControllerReportAgentTests {
  private func done(_ wc: WindowController, _ tab: TerminalTab) {
    wc.controlReportAgent(
      tab: tab,
      report: AgentHookReport(
        agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d")))
  }

  /// エディターを開いている間に終わると、音と知らせが出て done の印が残る。閉じて端末が出たら消える。
  func testDoneWhileTheEditorCoversTheTerminalIsNotifiedAndKeptUntilClosed() throws {
    let (wc, tab) = try makeControllerAndTab()
    makeKey(wc)
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    wc.toggleEditorFace()
    XCTAssertNil(wc.visibleTab, "エディターで見せている間は見ているタブに数えない")

    done(wc, tab)
    XCTAssertEqual(wc.attentionStore.transient?.row?.state, "done", "知らせが出る")
    XCTAssertEqual(sound.played.map(\.event), [.done], "音が鳴る")
    XCTAssertEqual(tab.agentState, "done", "done の印が残る")

    wc.toggleEditorFace()
    XCTAssertTrue(wc.visibleTab === tab)
    XCTAssertEqual(tab.agentState, "idle", "端末が出たら消える")
  }

  /// 前面の窓で透かしているタブは見ているタブ——エディターを開いている間に付いた done の印が消え、透かしている最中に終わっても
  /// 音も知らせも出ない。
  func testPeekingCountsAsLookingAtTheTab() throws {
    let (wc, tab) = try makeControllerAndTab()
    let option = OptionHoldDriver(wc)
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    wc.toggleEditorFace()
    done(wc, tab)
    XCTAssertEqual(tab.agentState, "done", "前提: エディターの間の done は残る")
    // 窓を前面にしておける時間はテストが決められない（ほかのアプリが前面を取る）ので、透かしてから前面にし、前面に戻ったときの
    // done の消去で見ているタブかを確かめる。
    wc.optionHold.windowAllows = { true }
    option.hold()

    makeKey(wc)
    XCTAssertTrue(wc.visibleTab === tab, "透かしている間は見ているタブ")
    XCTAssertEqual(tab.agentState, "idle", "見ているタブの done の印は消える")

    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "working"))
    wc.attentionStore.transient = nil
    let played = sound.played.count
    done(wc, tab)
    XCTAssertEqual(sound.played.count, played, "音は鳴らない")
    XCTAssertNil(wc.attentionStore.transient, "知らせは出ない")

    option.send([])
    XCTAssertNil(wc.visibleTab, "離すとエディターに戻り、見ているタブでなくなる")
  }

  /// 背景の workspace の、選んでいるタブ A ともう 1 つのタブ C。
  private struct Background {
    let wc: WindowController
    let a: TerminalTab
    let c: TerminalTab
  }

  /// 背景の workspace の A と C に done を付けて、前面の workspace から返す。
  private func doneInTheBackgroundWorkspace() throws -> Background {
    let tab = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "here", rootPath: "/tmp", activeTab: 0, tabs: [tab]),
        WorkspaceState(name: "there", rootPath: "/tmp", activeTab: 0, tabs: [tab, tab]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    let there = try XCTUnwrap(wc.workspaces.first { $0.name == "there" })
    let (a, c) = (there.tabs[0], there.tabs[1])
    _ = wc.controlActivateWorkspace(workspaceId: there.id)
    pumpMain(until: { c.activated }, "隠れたタブが起きる")
    wc.switchWorkspace(to: try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "here" }))
    makeKey(wc)
    done(wc, a)
    done(wc, c)
    XCTAssertEqual([a.agentState, c.agentState], ["done", "done"], "前提: 背景の workspace の done は残る")
    return Background(wc: wc, a: a, c: c)
  }

  /// `focus_tab`（Attention パレットの移動も通る）で C へ移ると、C の done は消え、A の done は残る。
  func testMovingToATabInAnotherWorkspaceKeepsTheDoneOfItsSelectedTab() throws {
    let bg = try doneInTheBackgroundWorkspace()
    let (wc, a, c) = (bg.wc, bg.a, bg.c)

    _ = wc.controlFocusTab(tabId: c.id)

    XCTAssertTrue(wc.activeTab === c)
    XCTAssertEqual(c.agentState, "idle", "移り先の done は消える")
    XCTAssertEqual(a.agentState, "done", "移り先ではないタブを途中で見ているタブにしない")
  }

  /// `open_file` で C のエディターを開いて移ると、エディターが端末を覆うので C の done も残り、A の done も残る。
  func testOpeningAFileInAnotherWorkspaceKeepsTheDoneOfBothTabs() throws {
    let bg = try doneInTheBackgroundWorkspace()
    let (wc, a, c) = (bg.wc, bg.a, bg.c)
    let file = try caseFile("a.txt", "a")

    guard case .success = wc.controlOpenFile(tabId: c.id, path: file.path) else {
      return XCTFail("open_file は success")
    }

    XCTAssertTrue(wc.activeTab === c)
    XCTAssertEqual(c.agentState, "done", "エディターで見せているタブの done は残る")
    XCTAssertEqual(a.agentState, "done", "移り先ではないタブを途中で見ているタブにしない")
  }
}
