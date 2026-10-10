import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// タスクから作業を始める口（`start_task`）を、実 `WindowController` と実 git・偽 agent で固定する。リポジトリの
/// workspace のタスクは ⌘T と同じ規則で worktree を用意し、Home のタスクは Home の中のタスクのフォルダを作業場にし、
/// どちらもタスクを進行中にして作業場を付け、人の見ている workspace とタブを変えずに agent のタブを起こす。
/// 決まらない・リポジトリが違う・付き先が無いときは理由付きで拒み、タスクを変えない。
///
/// 壊れると何が起きるか: 秘書が agent に取り掛からせるたびに人の画面が飛ぶ。Home のタスクが Home の直下で動き、
/// 行の agent の札が付かない。2 回目に別のフォルダができる。決まらないまま人の作業中の worktree に agent が重なる。
/// 主の Issue と別のリポジトリに worktree を作ってタスクに付ける。
///
/// agent は必ず偽物（`stageFakeAgent`）。
final class WindowControllerTaskStartTests: OrbeTestCase {
  let webId = UUID()
  var local: String!

  /// origin（bare）と、それを clone した手元。手元の `stale` は origin の `stale` を追跡し、1 コミット遅れる。
  override func setUpWithError() throws {
    let dir = TestScratch.caseDir.appendingPathComponent("git").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let origin = (dir as NSString).appendingPathComponent("origin.git")
    local = (dir as NSString).appendingPathComponent("web")
    let other = (dir as NSString).appendingPathComponent("other")
    try git(["init", "-q", "--bare", "-b", "main", origin], in: dir)
    try git(["clone", "-q", origin, other], in: dir)
    try identify(other)
    try git(["commit", "-q", "--allow-empty", "-m", "a"], in: other)
    try git(["push", "-q", "origin", "HEAD:main", "HEAD:stale"], in: other)
    try git(["clone", "-q", origin, local], in: dir)
    try identify(local)
    try git(["branch", "-q", "--track", "stale", "origin/stale"], in: local)
    try git(["commit", "-q", "--allow-empty", "-m", "b"], in: other)
    try git(["push", "-q", "origin", "HEAD:stale"], in: other)
  }

  func git(_ args: [String], in cwd: String) throws {
    let output = GitRunner.shared.runSync(args, cwd: cwd)
    XCTAssertTrue(output.isSuccess, "git \(args.joined(separator: " ")): \(output.stderrText)")
  }

  func identify(_ repo: String) throws {
    try git(["config", "user.email", "t@example.com"], in: repo)
    try git(["config", "user.name", "t"], in: repo)
  }

  /// 前面は main（素のタブ 1 枚）、背景に web（root が手元のリポジトリ・0 タブ）と Home。`webRoot`・`webTabs` で
  /// web の root とタブを、`frontWeb` で前面を web に替える。
  func launch(webRoot: String? = nil, webTabs: [TabState] = [], frontWeb: Bool = false) throws
    -> WindowController
  {
    _ = try stageFakeAgent("claude")
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: frontWeb ? 1 : 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "web", rootPath: webRoot ?? local, activeTab: 0, tabs: webTabs,
          persistentId: webId),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    let wc = WindowController()
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        wc.agentLauncher.detectedCommands.contains("claude")
      }, "偽 claude が検出されない")
    return wc
  }

  func homeId(_ wc: WindowController) throws -> UUID {
    try XCTUnwrap(wc.store.homeWorkspaceId)
  }

  func start(_ wc: WindowController, _ request: TaskStartRequest) -> Result<
    [String: Any], ControlError
  > {
    var outcome: Result<Any, ControlError>?
    wc.controlStartTask(request) { outcome = $0 }
    XCTAssertTrue(waitUntil(20) { outcome != nil }, "start_task が答えない")
    switch outcome {
    case .success(let value)?: return .success(value as? [String: Any] ?? [:])
    case .failure(let error)?: return .failure(error)
    case nil: return .failure(ControlError(code: 0, message: "no answer"))
    }
  }

  func stored(_ wc: WindowController, _ id: Int) -> TaskItem? {
    wc.taskStore.tasks.first { $0.id == id }
  }

  func tab(_ wc: WindowController, _ id: Int?) -> TerminalTab? {
    id.flatMap { id in wc.workspaces.flatMap(\.tabs).first { $0.id == id } }
  }

  private func commit(_ ref: String, in path: String) -> String {
    GitRunner.shared.runSync(["rev-parse", ref], cwd: path).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Home

  func testHomeTaskGetsItsOwnFolderAndAnUnselectedAgentTabWithTheTaskAsFirstInput() throws {
    let wc = try launch()
    var draft = TaskDraft(title: "見積もりを 山田さん/経理 に送る", workspace: try homeId(wc))
    draft.description = "金額は 10 万円"
    let task = try wc.taskStore.add(draft)
    let front = wc.activeTab?.id

    let result = try start(wc, TaskStartRequest(taskId: task.id, prompt: "急ぎで")).get()

    let home = try XCTUnwrap(HomeFolder.url).path
    let folder = "\(home)/tasks/\(task.id)-見積もりを-山田さん-経理-に送る"
    XCTAssertEqual(result["workdir"] as? String, GitWorktreeRoot.root(of: folder))
    XCTAssertEqual(result["created"] as? Bool, true)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory))
    let started = try XCTUnwrap(stored(wc, task.id))
    XCTAssertEqual(started.status, .inProgress)
    XCTAssertEqual(started.worktree?.path, GitWorktreeRoot.root(of: folder), "作業場として付く")

    XCTAssertEqual(wc.current.name, "main", "見ている workspace は変わらない")
    XCTAssertEqual(wc.activeTab?.id, front, "見ているタブは変わらない")
    let opened = try XCTUnwrap(tab(wc, result["tabId"] as? Int))
    let homeWorkspace = try homeId(wc)
    XCTAssertTrue(
      try XCTUnwrap(wc.workspaces.first { $0.persistentId == homeWorkspace }).tabs.contains {
        $0 === opened
      }, "Home に開く")
    let command = try XCTUnwrap(opened.surface.initialCommand)
    for part in ["見積もりを 山田さん/経理 に送る", "急ぎで"] {
      XCTAssertTrue(command.contains(part), "最初の入力に \(part): \(command)")
    }
    XCTAssertFalse(
      command.contains("金額は 10 万円"), "詳細は最初の入力に載せない（外の文面が入りうる）: \(command)")

    let again = try start(wc, TaskStartRequest(taskId: task.id)).get()
    XCTAssertEqual(again["workdir"] as? String, result["workdir"] as? String, "2 回目は同じフォルダ")
    XCTAssertEqual(again["created"] as? Bool, false)
  }

  /// Home のタスクの ⌘T は、タスクのフォルダ（無ければ作る）を「このディレクトリ」として開き、↵ でそこをタスクの
  /// 作業場として付けて、そこにタブを開く。
  func testCommandTOnAHomeTaskOpensItsFolderAndEnterStartsTheTaskThere() throws {
    let wc = try launch()
    let home = try homeId(wc)
    let task = try wc.taskStore.add(TaskDraft(title: "歯医者", workspace: home))
    let folder = "\(try XCTUnwrap(HomeFolder.url).path)/tasks/\(task.id)-歯医者"
    let row = WorktreePaletteAction.open(.directory(path: folder))

    wc.showWorktreePalette(task: task.id)
    let palette = try XCTUnwrap(wc.model.worktreePalette)
    XCTAssertTrue(waitUntil(20) { palette.items.contains { $0.action == row } }, "フォルダの行が出る")
    palette.chooseTarget(at: try XCTUnwrap(palette.targets.firstIndex(of: .shell)))
    palette.activate(at: try XCTUnwrap(palette.items.firstIndex { $0.action == row }))

    let started = try XCTUnwrap(stored(wc, task.id))
    XCTAssertEqual(started.status, .inProgress)
    XCTAssertEqual(started.worktree?.path, GitWorktreeRoot.root(of: folder), "タスクのフォルダが作業場として付く")
    XCTAssertEqual(wc.current.persistentId, home)
    XCTAssertEqual(wc.current.tabs.map(\.cwd), [folder], "そのフォルダにタブが開く")
  }

  // MARK: - 拒否

  func testUnknownTaskOrATaskWithoutWorkspaceIsRefusedAndLeftAsIs() throws {
    let wc = try launch()
    let loose = try wc.taskStore.add(TaskDraft(title: "どこにも付かない"))
    let tabs = wc.workspaces.map { $0.tabs.map(\.id) }

    guard case .failure(let unknown) = start(wc, TaskStartRequest(taskId: 999)) else {
      return XCTFail("未知のタスクは拒む")
    }
    XCTAssertEqual(unknown.code, -32004)
    guard case .failure(let noWorkspace) = start(wc, TaskStartRequest(taskId: loose.id)) else {
      return XCTFail("workspace の無いタスクは拒む")
    }
    XCTAssertEqual(noWorkspace.code, -32602)
    XCTAssertTrue(noWorkspace.message.contains("update_task"), noWorkspace.message)
    XCTAssertEqual(stored(wc, loose.id)?.status, .todo)
    XCTAssertEqual(wc.workspaces.map { $0.tabs.map(\.id) }, tabs, "タブは開かない")
  }

  func testRepositoryTaskWithoutAnyWayToDecideTheBranchAsksForOne() throws {
    let wc = try launch()
    let task = try wc.taskStore.add(TaskDraft(title: "検索を速くする", workspace: webId))

    guard case .failure(let error) = start(wc, TaskStartRequest(taskId: task.id)) else {
      return XCTFail("決まらなければ拒む")
    }
    XCTAssertEqual(error.code, -32602)
    XCTAssertTrue(error.message.contains("pass branch"), error.message)
    XCTAssertEqual(stored(wc, task.id)?.status, .todo, "タスクは変わらない")
    XCTAssertNil(stored(wc, task.id)?.worktree)
  }

  /// 主の結び付きのリポジトリを指す remote が手元に無ければ、branch を渡しても拒み、ブランチも作らない。
  func testRepositoryWithoutARemoteForTheLinkedRepositoryIsRefusedEvenWithABranch() throws {
    let wc = try launch()
    var draft = TaskDraft(title: "別のリポジトリの Issue", workspace: webId)
    draft.links = [
      TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/n", number: 5)), kind: .issue)
    ]
    let task = try wc.taskStore.add(draft)

    guard case .failure(let error) = start(wc, TaskStartRequest(taskId: task.id, branch: "feat/x"))
    else { return XCTFail("リポジトリが違えば拒む") }
    XCTAssertEqual(error.code, -32602)
    XCTAssertTrue(error.message.contains("repository mismatch"), error.message)
    XCTAssertEqual(stored(wc, task.id), task, "タスクは変わらない")
    XCTAssertFalse(
      GitRunner.shared.runSync(["rev-parse", "--verify", "-q", "feat/x"], cwd: local).isSuccess,
      "ブランチを作らない")
  }

  // MARK: - リポジトリ

  /// Issue に結び付いたタスクは、branch を渡さなくても ⌘T と同じ issue/<番号> の worktree で始まる。
  func testIssueTaskStartsOnTheIssueBranchWithoutABranch() throws {
    try git(["remote", "add", "upstream", "https://github.com/o/n.git"], in: local)
    let wc = try launch()
    var draft = TaskDraft(title: "Issue を直す", workspace: webId)
    draft.links = [
      TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/n", number: 5)), kind: .issue)
    ]
    let task = try wc.taskStore.add(draft)

    let result = try start(wc, TaskStartRequest(taskId: task.id)).get()

    XCTAssertEqual(result["branch"] as? String, "issue/5")
    XCTAssertEqual(stored(wc, task.id)?.worktree?.path, result["workdir"] as? String)
  }

  func testBranchIsCreatedFromTheDefaultBaseAndTheTaskStartsThere() throws {
    let wc = try launch()
    let task = try wc.taskStore.add(TaskDraft(title: "検索を速くする", workspace: webId))
    let front = wc.activeTab?.id

    let result = try start(wc, TaskStartRequest(taskId: task.id, branch: "feat/search")).get()

    let workdir = try XCTUnwrap(result["workdir"] as? String)
    XCTAssertEqual(result["branch"] as? String, "feat/search")
    XCTAssertEqual(result["created"] as? Bool, true)
    XCTAssertEqual(stored(wc, task.id)?.worktree?.path, workdir)
    XCTAssertEqual(stored(wc, task.id)?.status, .inProgress)
    let opened = try XCTUnwrap(tab(wc, result["tabId"] as? Int))
    XCTAssertEqual(GitWorktreeRoot.root(of: opened.cwd), workdir, "その worktree で開く")
    XCTAssertTrue(
      try XCTUnwrap(wc.workspaces.first { $0.persistentId == webId }).tabs.contains {
        $0 === opened
      }, "タスクの workspace に開く")
    XCTAssertEqual(wc.activeTab?.id, front, "見ているタブは変わらない")
  }

  /// 遅れたローカルブランチは、fast-forward してから worktree にする（⌘T では人に問う最新化）。
  func testStaleLocalBranchIsFastForwardedBeforeOpening() throws {
    let wc = try launch()
    let task = try wc.taskStore.add(TaskDraft(title: "古いブランチ", workspace: webId))

    let result = try start(wc, TaskStartRequest(taskId: task.id, branch: "stale")).get()

    let workdir = try XCTUnwrap(result["workdir"] as? String)
    let origin = ((local as NSString).deletingLastPathComponent as NSString)
      .appendingPathComponent("origin.git")
    XCTAssertEqual(
      commit("HEAD", in: workdir), commit("stale", in: origin), "origin の stale まで進めてある")
  }

  /// タスクに worktree が付いていれば、それを開く（作らない）。
  func testTaskWorktreeIsReused() throws {
    let wc = try launch()
    let first = try wc.taskStore.add(TaskDraft(title: "一度目", workspace: webId))
    let made = try start(wc, TaskStartRequest(taskId: first.id, branch: "feat/again")).get()

    let again = try start(wc, TaskStartRequest(taskId: first.id)).get()

    XCTAssertEqual(again["workdir"] as? String, made["workdir"] as? String)
    XCTAssertEqual(again["created"] as? Bool, false)
  }
}
