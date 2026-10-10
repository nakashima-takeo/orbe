import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// `start_task` の作業場の規則（拒否・タスク自身の worktree・Home の記録・リポジトリの決め方）と、前面の workspace に
/// 開くときの起こし方。
///
/// 壊れると何が起きるか: 秘書の start_task が別のタスクの worktree を黙って奪う・人の本体の作業ツリーで agent を起こす・
/// 作業中の agent の隣に 2 体目を起こす。リポジトリで始めて Home に移したタスクが本体の中にフォルダを作る。worktree を
/// 付けたタスクが remote の照合で始められない。人の開いている別の clone に worktree を作る。前面の workspace で起こした
/// タブが人の見ているタブを奪う・0 タブの画面で隠れたままになる。
extension WindowControllerTaskStartTests {
  private func refusal(_ wc: WindowController, _ request: TaskStartRequest) throws -> ControlError {
    guard case .failure(let error) = start(wc, request) else {
      XCTFail("拒むはず")
      throw ControlError(code: 0, message: "accepted")
    }
    return error
  }

  // MARK: - 拒否

  /// 別のタスクの worktree に行き着いたら、付け替えず拒む（相手のタスクを理由に入れる）。
  func testAnotherTasksWorktreeIsRefusedAndStaysWithItsTask() throws {
    let wc = try launch()
    let owner = try wc.taskStore.add(TaskDraft(title: "持ち主", workspace: webId))
    let made = try start(wc, TaskStartRequest(taskId: owner.id, branch: "feat/owned")).get()
    let other = try wc.taskStore.add(TaskDraft(title: "別のタスク", workspace: webId))

    let error = try refusal(wc, TaskStartRequest(taskId: other.id, branch: "feat/owned"))

    XCTAssertEqual(error.code, -32602)
    XCTAssertTrue(error.message.contains("task \(owner.id)"), error.message)
    XCTAssertEqual(stored(wc, owner.id)?.worktree?.path, made["workdir"] as? String, "持ち主から外さない")
    XCTAssertEqual(stored(wc, other.id)?.status, .todo)
  }

  /// リポジトリの本体（main worktree）は作業場にしない。
  func testTheMainWorktreeIsRefused() throws {
    let wc = try launch()
    let task = try wc.taskStore.add(TaskDraft(title: "本体で", workspace: webId))

    let error = try refusal(wc, TaskStartRequest(taskId: task.id, branch: "main"))

    XCTAssertEqual(error.code, -32602)
    XCTAssertTrue(error.message.contains("main worktree"), error.message)
    XCTAssertNil(stored(wc, task.id)?.worktree)
  }

  /// 作業中・入力待ちの agent がいる作業場には 2 体目を起こさず、そのタブを理由に入れて拒む。
  func testASecondStartWhileAnAgentIsWorkingThereIsRefusedWithItsTab() throws {
    let wc = try launch()
    let task = try wc.taskStore.add(TaskDraft(title: "進行中", workspace: webId))
    let first = try start(wc, TaskStartRequest(taskId: task.id, branch: "feat/busy")).get()
    let agentTab = try XCTUnwrap(tab(wc, first["tabId"] as? Int))
    wc.controlReportAgent(
      tab: agentTab, report: AgentHookReport(agent: "claude", state: "working", sessionId: "s-1"))
    let tabs = wc.workspaces.map { $0.tabs.map(\.id) }

    let error = try refusal(wc, TaskStartRequest(taskId: task.id))

    XCTAssertEqual(error.code, -32602)
    XCTAssertTrue(error.message.contains("tab \(agentTab.id)"), error.message)
    XCTAssertEqual(wc.workspaces.map { $0.tabs.map(\.id) }, tabs, "タブを開かない")
  }

  func testAnUndetectedAgentIsRefused() throws {
    let wc = try launch()
    let task = try wc.taskStore.add(TaskDraft(title: "codex で", workspace: webId))

    let error = try refusal(wc, TaskStartRequest(taskId: task.id, branch: "feat/x", agent: "codex"))

    XCTAssertEqual(error.code, -32602)
    XCTAssertTrue(error.message.contains("agent not detected"), error.message)
    XCTAssertEqual(stored(wc, task.id)?.status, .todo)
  }

  // MARK: - 作業場の決め方

  /// Home のタスクは、Home の `tasks/` の下の記録だけを使う（リポジトリで始めて Home に移したタスクの worktree は
  /// 使わず、Home の下に決め直す）。
  func testHomeTaskUsesOnlyARecordUnderHomeTasks() throws {
    let wc = try launch()
    let task = try wc.taskStore.add(
      TaskDraft(
        title: "移したタスク", workspace: try homeId(wc), worktree: TaskWorktree(directory: local)))

    let result = try start(wc, TaskStartRequest(taskId: task.id)).get()

    let home = GitWorktreeRoot.normalizedPath(try XCTUnwrap(HomeFolder.url).path)
    let workdir = try XCTUnwrap(result["workdir"] as? String)
    XCTAssertTrue(workdir.hasPrefix(home + "/tasks/\(task.id)-"), workdir)
  }

  /// タスク自身の worktree が付いていればそれを使い、主の結び付きの remote は照合しない（追跡用の別リポジトリの
  /// Issue を主にしたタスクでも始められる）。
  func testTheTasksOwnWorktreeIsUsedWithoutMatchingRemotes() throws {
    let path = ((local as NSString).deletingLastPathComponent as NSString)
      .appendingPathComponent("web-own")
    try git(["worktree", "add", "-q", "-b", "feat/own", path], in: local)
    let wc = try launch()
    var draft = TaskDraft(
      title: "追跡用の Issue", workspace: webId, worktree: TaskWorktree(directory: path))
    draft.links = [
      TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/elsewhere", number: 5)), kind: .issue)
    ]
    let task = try wc.taskStore.add(draft)

    let result = try start(wc, TaskStartRequest(taskId: task.id)).get()

    XCTAssertEqual(result["workdir"] as? String, GitWorktreeRoot.normalizedPath(path))
    XCTAssertEqual(result["created"] as? Bool, false)
  }

  /// リポジトリは人の画面で決めない: workspace のアクティブタブが別の clone にいても、workspace の root のリポジトリに
  /// 作る。
  func testRepositoryIsNotDecidedByTheActiveTab() throws {
    let other = ((local as NSString).deletingLastPathComponent as NSString)
      .appendingPathComponent("other")
    let wc = try launch(webTabs: [TabState(cwd: other, agent: nil, explicitTitle: nil)])
    let task = try wc.taskStore.add(TaskDraft(title: "root のリポジトリで", workspace: webId))

    let result = try start(wc, TaskStartRequest(taskId: task.id, branch: "feat/root")).get()

    XCTAssertEqual(
      (result["repo"] as? String).map(GitWorktreeRoot.normalizedPath),
      GitWorktreeRoot.normalizedPath(local))
  }

  /// workspace の root が git の外なら `repo` を求め、渡せばそのリポジトリに作る。
  func testRootOutsideGitNeedsRepo() throws {
    let outside = TestScratch.caseDir.appendingPathComponent("outside").path
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    let wc = try launch(webRoot: outside)
    let task = try wc.taskStore.add(TaskDraft(title: "repo を渡す", workspace: webId))

    let error = try refusal(wc, TaskStartRequest(taskId: task.id, branch: "feat/repo"))
    XCTAssertTrue(error.message.contains("pass repo"), error.message)

    let result = try start(wc, TaskStartRequest(taskId: task.id, branch: "feat/repo", repo: local))
      .get()
    XCTAssertEqual(
      (result["repo"] as? String).map(GitWorktreeRoot.normalizedPath),
      GitWorktreeRoot.normalizedPath(local))
  }

  // MARK: - 前面の workspace

  /// 前面の workspace に開いても選ばない: 見ているタブはそのまま、開いたタブの surface は起きる。
  func testStartingInTheFrontWorkspaceKeepsTheActiveTabAndWakesTheNewOne() throws {
    let wc = try launch(
      webTabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)], frontWeb: true)
    let front = wc.activeTab?.id
    let task = try wc.taskStore.add(TaskDraft(title: "前面で", workspace: webId))

    let result = try start(wc, TaskStartRequest(taskId: task.id, branch: "feat/front")).get()

    XCTAssertEqual(wc.activeTab?.id, front, "見ているタブは変わらない")
    let opened = try XCTUnwrap(tab(wc, result["tabId"] as? Int))
    XCTAssertTrue(waitUntil { opened.surface.surfacePtr != nil }, "開いたタブは起きる")
  }

  /// 前面の workspace が 0 タブなら、開いたタブを選んで見せる（隠すと、選んでいるタブが見えない）。
  func testStartingInAnEmptyFrontWorkspaceShowsTheNewTab() throws {
    let wc = try launch(frontWeb: true)
    let task = try wc.taskStore.add(TaskDraft(title: "空の前面で", workspace: webId))

    let result = try start(wc, TaskStartRequest(taskId: task.id, branch: "feat/empty")).get()

    XCTAssertEqual(wc.activeTab?.id, result["tabId"] as? Int, "選ばれる")
    XCTAssertFalse(try XCTUnwrap(wc.activeTab).view.isHidden, "見える")
  }

  // MARK: - ⌘T

  /// Home のタスクの ⌘T で札を外すと、タスクのフォルダの一覧を捨てて Home の場所を読み直す（同じ Home でも）。
  func testRemovingTheTaskFromAHomeTasksCommandTRereadsHome() throws {
    let wc = try launch()
    let homeIndex = try XCTUnwrap(wc.store.homeIndex)
    wc.switchWorkspace(to: homeIndex)
    let task = try wc.taskStore.add(TaskDraft(title: "札を外す", workspace: try homeId(wc)))
    let folder = "\(try XCTUnwrap(HomeFolder.url).path)/tasks/\(task.id)-札を外す"
    let folderRow = WorktreePaletteAction.open(.directory(path: folder))
    wc.showWorktreePalette(task: task.id)
    let palette = try XCTUnwrap(wc.model.worktreePalette)
    XCTAssertTrue(waitUntil(20) { palette.items.contains { $0.action == folderRow } }, "前提: フォルダの行")

    palette.clearTaskContext()

    XCTAssertTrue(
      waitUntil(20) {
        !palette.items.contains { $0.action == folderRow }
          && palette.items.contains { $0.glyph == .directory }
      }, "タスクのフォルダの行を捨てて Home の場所を読み直す")
  }
}
