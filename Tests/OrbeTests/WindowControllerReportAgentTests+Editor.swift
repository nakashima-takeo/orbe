import AppKit
import XCTest

@testable import Orbe

/// エディターを開いている間の「見ているタブ」——端末が覆われていて結果が見えないので、前面の窓で選んでいるタブでも見ている
/// タブに数えない。別の workspace のタブへ移るときは、移り先ではないタブを途中で見ているタブにしない。
///
/// 壊れると何が起きるか。エディターで文書を読んでいる間に終わったエージェントの音も知らせも出ず、done の印も消えて、終わった
/// ことに気づけない。Attention パレットから別の workspace のタブへ移るだけで、そこで選んでいた別のタブの done が消える。
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

  /// 別の workspace のタブ C へ移ると、C の done は消え、その workspace で選んでいたタブ A の done は残る。
  func testMovingToATabInAnotherWorkspaceKeepsTheDoneOfItsSelectedTab() throws {
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

    _ = wc.controlFocusTab(tabId: c.id)

    XCTAssertTrue(wc.activeTab === c)
    XCTAssertEqual(c.agentState, "idle", "移り先の done は消える")
    XCTAssertEqual(a.agentState, "done", "移り先ではないタブを途中で見ているタブにしない")
  }
}
