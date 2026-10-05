import AppKit
import XCTest

@testable import Orbe

/// 窓が持つ「worktree → そこで動く agent」の索引が、タブの agent の報告に追従すること（完了・休止でも残り、
/// タブが去ると外れる。タブの cwd が worktree の中のどこにあっても、キーは worktree のルート）と、タスク画面
/// の詳細の agent の場所からそのタブへ移れること。
///
/// 壊れると何が起きるか: agent が作業を始めても、入力待ちになっても、タスクの行の札が変わらない（画面を
/// 開き直すまで古い状態を言う）。応答を終えた agent のタブへ、結果を見にタスク画面から移れない。worktree の
/// 中のサブディレクトリで動く agent がタスクに結び付かない。
/// 詳細の「claude が取り掛かっている」で ↵ を押しても、そのタブへ移れない。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerWorktreeAgentsTests: OrbeTestCase {
  /// caseDir に git の worktree を作り、その中のサブディレクトリで開いたタブと、git の外のタブを持つ窓。
  /// 前面のタブは git の外のタブ。
  private func launch() throws -> (WindowController, root: String) {
    let root = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("repo").path
    let nested = (root as NSString).appendingPathComponent("Sources")
    try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
    XCTAssertTrue(GitRunner.shared.runSync(["init", "-q"], cwd: root).isSuccess)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 1,
          tabs: [
            TabState(cwd: nested, agent: nil, explicitTitle: nil),
            TabState(cwd: "/tmp", agent: nil, explicitTitle: nil),
          ])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    return (WindowController(), GitWorktreeRoot.normalizedPath(root))
  }

  private func pump(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
  }

  private func report(_ state: String, on tab: TerminalTab, in wc: WindowController) {
    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: state, sessionId: "s-1"))
  }

  func testTheIndexFollowsTheAgentsReportsUnderItsWorktreeRoot() throws {
    let (wc, root) = try launch()
    let tab = try XCTUnwrap(wc.current.tabs.first)

    report("working", on: tab, in: wc)
    XCTAssertTrue(pump { wc.worktreeAgents.agents[root]?.state == .working }, "作業中が載る")
    XCTAssertEqual(wc.worktreeAgents.agents[root]?.tabId, tab.id)
    XCTAssertEqual(wc.worktreeAgents.agents[root]?.name, "claude")

    report("waiting", on: tab, in: wc)
    XCTAssertTrue(pump { wc.worktreeAgents.agents[root]?.state == .waiting }, "入力待ちへ追従する")

    report("done", on: tab, in: wc)
    XCTAssertTrue(pump { wc.worktreeAgents.agents[root]?.state == .done }, "応答を終えても残る")
    report("idle", on: tab, in: wc)
    XCTAssertTrue(pump { wc.worktreeAgents.agents[root]?.state == .idle }, "休止しても残る")

    _ = wc.controlCloseTab(tabId: tab.id)
    XCTAssertTrue(pump { wc.worktreeAgents.agents[root] == nil }, "タブが去ると外れる")
  }

  /// worktree の作業のブランチが確定していれば（既定ブランチ以外で付けた）、タスクがその worktree の
  /// agent を示すのはそのブランチにいる間だけ——ブランチを切り替えて使い回す main worktree で、別の作業
  /// の agent をタスクに示さない。戻ればまた示す。
  func testATaskShowsTheAgentOnlyWhileItsWorktreeIsOnTheBranchItWasAttachedAt() throws {
    let (wc, root) = try launch()
    let git = { (args: [String]) in
      XCTAssertTrue(
        GitRunner.shared.runSync(args, cwd: root).isSuccess, args.joined(separator: " "))
    }
    git([
      "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty",
      "-m", "init",
    ])
    git(["checkout", "-q", "-b", "task"])
    let tab = try XCTUnwrap(wc.current.tabs.first)
    let task = try wc.taskStore.add(TaskDraft(title: "a", worktree: TaskWorktree(key: root)))

    report("working", on: tab, in: wc)
    XCTAssertTrue(pump { task.agent(in: wc.worktreeAgents.agents) != nil }, "付けたときのブランチ")

    git(["checkout", "-q", "-b", "other"])
    report("waiting", on: tab, in: wc)
    XCTAssertTrue(pump { wc.worktreeAgents.agents[root]?.state == .waiting })
    XCTAssertNil(task.agent(in: wc.worktreeAgents.agents), "別のブランチにいる間")

    git(["checkout", "-q", "task"])
    report("working", on: tab, in: wc)
    XCTAssertTrue(pump { task.agent(in: wc.worktreeAgents.agents) != nil }, "戻った後")
  }

  func testGoingToTheAgentFromTheTaskDetailFocusesItsTabAndClosesTheScreen() throws {
    let (wc, root) = try launch()
    let tab = try XCTUnwrap(wc.current.tabs.first)
    report("working", on: tab, in: wc)
    XCTAssertTrue(pump { wc.worktreeAgents.agents[root] != nil })
    let task = try wc.taskStore.add(TaskDraft(title: "a", worktree: TaskWorktree(key: root)))
    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))
    let palette = try XCTUnwrap(wc.model.taskPalette)
    palette.reconcile()
    XCTAssertEqual(palette.selectedID, .task(task.id))
    palette.enterDetail()
    palette.moveField(-1)
    palette.moveField(-1)
    XCTAssertEqual(palette.area, .detail(.agent), "前提: 詳細の agent の場所にいる")
    XCTAssertNotEqual(wc.current.active, 0, "前提: 前面は別のタブ")

    palette.focusAgentTab()

    XCTAssertEqual(wc.presentedOverlay, .none, "タスク画面を閉じる")
    XCTAssertEqual(wc.current.active, 0, "agent のタブが前面になる")
  }
}
