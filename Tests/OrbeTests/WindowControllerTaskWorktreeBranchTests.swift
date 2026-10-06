import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// タスクが worktree に記録した作業のブランチが、既定ブランチで付けた（未確定の）ときも働くこと: 既定
/// ブランチから切ったブランチの agent をタスクに示し、⌘⇧X を開いたときの PR の自動の結び付けがそのブランチで
/// 記録を確定し、確定の後は別のブランチの agent を示さない。ブランチを読めないリポジトリ（reftable）の記録も、
/// 同じ経路で確定する。
///
/// 壊れると何が起きるか: main worktree を既定ブランチのままタスクに付け、そこで作業のブランチを切ると、その
/// ブランチの agent がタスクの行と右の欄から消え、PR も自動で付かない。確定しないままだと、後で別のブランチへ
/// 切り替えたときの agent をタスクに示し続ける。確定の答えが届く前に人が付け直した記録を、古い答えで上書きする。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
/// origin を持たない（GitHub でない）リポジトリなので、PR の問い合わせに gh は使わない。
final class WindowControllerTaskWorktreeBranchTests: OrbeTestCase {
  /// caseDir に 1 コミットのリポジトリを作り、そこで開いたタブを 1 枚持つ窓。
  private func launch(refFormat: String = "files") throws -> (WindowController, root: String) {
    let root = TestScratch.caseDir.appendingPathComponent("repo").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    git(["init", "-q", "-b", "main", "--ref-format=\(refFormat)"], in: root)
    git(
      [
        "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty",
        "-m", "init",
      ], in: root)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: root, activeTab: 0,
          tabs: [TabState(cwd: root, agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    return (WindowController(), GitWorktreeRoot.normalizedPath(root))
  }

  private func git(_ args: [String], in cwd: String) {
    XCTAssertTrue(GitRunner.shared.runSync(args, cwd: cwd).isSuccess, args.joined(separator: " "))
  }

  private func pump(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
  }

  private func report(_ state: String, in wc: WindowController) throws {
    let tab = try XCTUnwrap(wc.current.tabs.first)
    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: state, sessionId: "s-1"))
  }

  private func stored(_ wc: WindowController, _ id: Int) throws -> TaskItem {
    try XCTUnwrap(wc.taskStore.tasks.first { $0.id == id })
  }

  private func shownAgent(_ wc: WindowController, _ id: Int) throws -> WorktreeAgentActivity.Agent?
  {
    try stored(wc, id).agent(in: wc.worktreeAgents.agents)
  }

  /// 既定ブランチで付けた記録は未確定で、そこから切ったブランチの agent も示す。⌘⇧X を開くとそのブランチで
  /// 確定し、以後は別のブランチにいる間は示さず、戻ればまた示す。
  func testARecordMadeOnTheDefaultBranchFollowsTheBranchCutThereAndIsConfirmedOnOpening() throws {
    let (wc, root) = try launch()
    let task = try wc.taskStore.add(TaskDraft(title: "a", worktree: TaskWorktree(key: root)))
    XCTAssertEqual(try stored(wc, task.id).worktreeBranch, "main", "前提: 既定ブランチで付けた")

    git(["switch", "-q", "-c", "feat"], in: root)
    try report("working", in: wc)
    XCTAssertTrue(pump { (try? shownAgent(wc, task.id)) != nil }, "切ったブランチの agent")

    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))
    XCTAssertTrue(
      pump { (try? stored(wc, task.id).worktreeBranch) == "feat" }, "開くと今のブランチで確定")
    XCTAssertEqual(TaskStore().tasks.first { $0.id == task.id }?.worktreeBranch, "feat", "保存される")

    git(["switch", "-q", "-c", "other"], in: root)
    try report("waiting", in: wc)
    XCTAssertTrue(pump { wc.worktreeAgents.agents[root]?.state == .waiting })
    XCTAssertNil(try shownAgent(wc, task.id), "確定の後は別のブランチの agent を示さない")

    git(["switch", "-q", "feat"], in: root)
    try report("working", in: wc)
    XCTAssertTrue(pump { (try? shownAgent(wc, task.id)) != nil }, "戻ればまた示す")
  }

  /// ブランチを読めないリポジトリ（reftable）で付けた記録は無く（未確定）、⌘⇧X を開くと git の答えの
  /// ブランチ名で確定する。
  func testARecordMissingInAReftableRepositoryIsConfirmedOnOpening() throws {
    let (wc, root) = try launch(refFormat: "reftable")
    git(["switch", "-q", "-c", "feat"], in: root)
    let task = try wc.taskStore.add(TaskDraft(title: "a", worktree: TaskWorktree(key: root)))
    XCTAssertNil(try stored(wc, task.id).worktreeBranch, "前提: ブランチを読めない")

    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))

    XCTAssertTrue(pump { (try? stored(wc, task.id).worktreeBranch) == "feat" })
  }

  /// 確定は、答えが届いた時点の記録が、問い合わせたときの記録と同じ場合だけ——その間に人が付け直した記録を、
  /// 古い問い合わせの答えで上書きしない。
  ///
  /// 答えは全 worktree の分が 1 回で届くので、別のリポジトリのタスク（付け直さない）が確定したことで、
  /// 答えが届き終えたことを知る。
  func testTheConfirmationDoesNotOverwriteARecordChangedWhileAsking() throws {
    let (wc, root) = try launch()
    let task = try wc.taskStore.add(TaskDraft(title: "a", worktree: TaskWorktree(key: root)))
    git(["switch", "-q", "-c", "feat"], in: root)
    let other = TestScratch.caseDir.appendingPathComponent("other").path
    git(["init", "-q", "-b", "main", other], in: TestScratch.caseDir.path)
    git(
      [
        "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty",
        "-m", "init",
      ], in: other)
    let sentinel = try wc.taskStore.add(
      TaskDraft(title: "b", worktree: TaskWorktree(key: GitWorktreeRoot.normalizedPath(other))))
    git(["switch", "-q", "-c", "side"], in: other)

    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))
    git(["switch", "-q", "--detach"], in: root)
    var update = TaskUpdate()
    update.worktree = .set(TaskWorktree(key: root))
    _ = try wc.taskStore.update(task.id, update)
    XCTAssertNil(try stored(wc, task.id).worktreeBranch, "前提: 問い合わせの後に付け直した")
    git(["switch", "-q", "feat"], in: root)

    XCTAssertTrue(
      pump { (try? stored(wc, sentinel.id).worktreeBranch) == "side" }, "前提: 答えが届き終えた")
    XCTAssertNil(try stored(wc, task.id).worktreeBranch)
  }
}
