import AppKit
import XCTest

@testable import Orbe

/// タスクから開いた ⌘T の ↵ を、実 `WindowController` と実 git で固定する。⌘T はタスクの workspace に
/// 結び付き、worktree が用意できたら（遅れたブランチの最新化を通っても）タスクを進行中にしてその worktree を
/// 付け、その workspace とタブを前面にする。用意できなかったら、タスクは変わらない。札を外したら、開いた
/// 時点の workspace とそのリポジトリへ戻り、いつもの ⌘T と同じく振る舞う。
///
/// 壊れると何が起きるか: web-app のタスクから ⌘T を開いたのに、今見ている orbe の workspace に worktree を
/// 作ってタブを開く。タブが背景の workspace に開いて、↵ の後に何も起きなかったように見える。作成に失敗した
/// タスクが進行中になる。PR のブランチ（遅れていることが多い）を最新化してから開くと、タスクに何も付かない。
/// 札を外して「いつもの ⌘T」にしたつもりが、タスクの workspace にタブを開いてそこへ画面が飛ぶ。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerTaskWorktreeEnterTests: OrbeTestCase {
  private let webId = UUID()
  private var dir: String!
  private var local: String!

  /// origin（bare）と、それを clone した手元。手元の `stale` は origin の `stale` を追跡し、1 コミット遅れる。
  override func setUpWithError() throws {
    dir = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("git").path
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

  private func git(_ args: [String], in cwd: String) throws {
    let output = GitRunner.shared.runSync(args, cwd: cwd)
    XCTAssertTrue(output.isSuccess, "git \(args.joined(separator: " ")): \(output.stderrText)")
  }

  private func identify(_ repo: String) throws {
    try git(["config", "user.email", "t@example.com"], in: repo)
    try git(["config", "user.name", "t"], in: repo)
  }

  /// 前面は main（git の外。`mainRepository` を渡せば、それを root path にした 0 タブの workspace）。タスクは
  /// 0 タブの web（root path が手元のリポジトリ）に付く。
  private func launch(mainRepository: String? = nil) throws -> (WindowController, TaskItem) {
    let main =
      mainRepository.map {
        WorkspaceState(name: "main", rootPath: $0, activeTab: 0, tabs: [])
      }
      ?? WorkspaceState(
        name: "main", rootPath: "/tmp", activeTab: 0,
        tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        main,
        WorkspaceState(name: "web", rootPath: local, activeTab: 0, tabs: [], persistentId: webId),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    let wc = WindowController()
    let task = try wc.taskStore.add(TaskDraft(title: "検索を速くする", workspace: webId))
    return (wc, task)
  }

  private func pump(_ condition: () -> Bool, timeout: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
  }

  /// タスクの ⌘T を開き、`action` の行が出るまで待ってから、起動先を shell にする。
  private func open(
    _ wc: WindowController, for task: TaskItem, row action: WorktreePaletteAction
  ) throws -> WorktreePaletteModel {
    wc.showWorktreePalette(task: task.id)
    let palette = try XCTUnwrap(wc.model.worktreePalette)
    XCTAssertTrue(pump { palette.items.contains { $0.action == action } }, "行が出る: \(action)")
    palette.chooseTarget(at: try XCTUnwrap(palette.targets.firstIndex(of: .shell)))
    return palette
  }

  private var toplevel: String {
    GitRunner.shared.runSync(["rev-parse", "--show-toplevel"], cwd: local).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func stored(_ task: TaskItem, in wc: WindowController) -> TaskItem? {
    wc.taskStore.tasks.first { $0.id == task.id }
  }

  func testEnterOpensInTheTasksWorkspaceStartsTheTaskAndBringsItForward() throws {
    let (wc, task) = try launch()
    let row = WorktreePaletteAction.open(.directory(path: toplevel))
    let palette = try open(wc, for: task, row: row)
    XCTAssertEqual(wc.model.worktreePaletteProvider?.cwd, local, "タスクの workspace から探す")
    XCTAssertEqual(wc.current.name, "main", "前提: 前面は別の workspace")

    palette.activate(at: try XCTUnwrap(palette.items.firstIndex { $0.action == row }))

    XCTAssertEqual(stored(task, in: wc)?.status, .inProgress, "タスクは進行中になる")
    XCTAssertEqual(
      stored(task, in: wc)?.worktree?.path, GitWorktreeRoot.normalizedPath(toplevel),
      "開いた worktree が付く")
    XCTAssertEqual(wc.current.name, "web", "タスクの workspace が前面になる")
    XCTAssertEqual(wc.current.tabs.map(\.cwd), [toplevel], "そこにタブが開く")
    XCTAssertTrue(wc.workspaces[0].tabs.allSatisfy { $0.cwd == "/tmp" }, "前面だった workspace には開かない")
  }

  func testAFailedCreationLeavesTheTaskUnchanged() throws {
    let (wc, task) = try launch()
    let palette = try open(wc, for: task, row: .open(.directory(path: toplevel)))

    palette.onExecute(.newBranch(name: "issue/9", base: .ref("origin/no-such-branch")))

    XCTAssertTrue(pump { palette.errorMessage != nil }, "作成に失敗する")
    XCTAssertEqual(stored(task, in: wc), task, "タスクは変わらない")
  }

  /// 札を外すと、いつもの ⌘T と同じく開いた時点の workspace（main。git の外）に結び付き直す。タスクの
  /// リポジトリの行は捨てて main の場所を読み直す。↵ は、その後に前面の workspace が替わっても main に
  /// タブを開き、どの workspace も前面にしない。タスクも変わらない。
  func testRemovingTheTaskReturnsToTheOpenedWorkspaceAndEnterLeavesTheTaskAlone() throws {
    let (wc, task) = try launch()
    let repositoryRow = WorktreePaletteAction.open(.directory(path: toplevel))
    let palette = try open(wc, for: task, row: repositoryRow)
    let mainTabs = wc.workspaces[0].tabs.count

    palette.clearTaskContext()

    XCTAssertTrue(
      pump { palette.items.contains { $0.glyph == .directory } }, "開いた時点の workspace の場所を読み直す")
    XCTAssertFalse(
      palette.items.contains { $0.action == repositoryRow }, "タスクの workspace のリポジトリの行は残らない")
    wc.switchWorkspace(to: 1)
    palette.activate(at: try XCTUnwrap(palette.items.firstIndex { $0.glyph == .directory }))

    XCTAssertEqual(wc.model.overlay, .none, "タブを開いて閉じる")
    XCTAssertEqual(wc.workspaces[0].tabs.count, mainTabs + 1, "開いた時点の workspace にタブが開く")
    XCTAssertTrue(wc.workspaces[1].tabs.isEmpty, "タスクの workspace には開かない")
    XCTAssertEqual(wc.current.name, "web", "前面は動かさない")
    XCTAssertEqual(stored(task, in: wc), task, "札を外した後の ↵ はタスクを変えない")
  }

  /// 札を外した時点でタスクのリポジトリの読み取り（提示時の fetch）がまだ途中でも、それが後から着地して
  /// パレットにタスクのリポジトリの行を書き戻すことはない。git の一覧の読み取りは provider を強く捕まえる
  /// ので、途中の読み取りがある間は前の provider が生き残る——その状態をテストが provider を持つことで作る。
  func testAReadOfTheTasksRepositoryLandingAfterRemovingTheTaskDoesNotComeBack() throws {
    let gate = (dir as NSString).appendingPathComponent("fetch-gate")
    let wrapper = (dir as NSString).appendingPathComponent("held-upload-pack")
    try FileManager.default.createDirectory(atPath: gate, withIntermediateDirectories: true)
    try "#!/bin/sh\nwhile [ -d \"\(gate)\" ]; do sleep 0.05; done\nexec git-upload-pack \"$@\"\n"
      .write(toFile: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
    try git(["config", "remote.origin.uploadpack", wrapper], in: local)
    let (wc, task) = try launch()
    let repositoryRow = WorktreePaletteAction.open(.directory(path: toplevel))
    let palette = try open(wc, for: task, row: repositoryRow)
    let taskProvider = try XCTUnwrap(wc.model.worktreePaletteProvider)
    XCTAssertFalse(taskProvider.remoteFetchLanded, "前提: タスクのリポジトリの fetch はまだ着地していない")

    palette.clearTaskContext()
    XCTAssertTrue(pump { palette.items.contains { $0.glyph == .directory } })
    try FileManager.default.removeItem(atPath: gate)

    XCTAssertTrue(pump { taskProvider.remoteFetchLanded }, "前提: タスクのリポジトリの fetch が着地した")
    XCTAssertFalse(
      pump({ palette.items.contains { $0.action == repositoryRow } }, timeout: 1),
      "タスクのリポジトリの行は戻らない")
  }

  /// 遅れたブランチは最新化の画面を通ってから作られる。その経路でもタスクは進行中になり、worktree が付く。
  func testEnterThroughTheRefreshScreenStillStartsTheTask() throws {
    let (wc, task) = try launch()
    let palette = try open(wc, for: task, row: .open(.localBranch(name: "stale")))

    palette.activate(
      at: try XCTUnwrap(
        palette.items.firstIndex { $0.action == .open(.localBranch(name: "stale")) })
    )
    XCTAssertTrue(pump { palette.mode == .refresh }, "前提: 遅れているので最新化の画面に入る")
    palette.confirmRefresh(.refreshed)

    XCTAssertTrue(pump { stored(task, in: wc)?.status == .inProgress }, "タスクは進行中になる")
    let worktree = try XCTUnwrap(stored(task, in: wc)?.worktree)
    XCTAssertEqual(
      GitRunner.shared.runSync(["branch", "--show-current"], cwd: worktree.path).stdoutText
        .trimmingCharacters(in: .whitespacesAndNewlines), "stale", "作った stale の worktree が付く")
  }

  /// 名前を打ったまま札をクリックして別のリポジトリへ読み直しても、その名前がブランチ名として有効かの答え
  /// （リポジトリに依らない）は残り、↵ が預かられたまま固まらない（読み直した先の fetch の着地で決まる）。
  func testRemovingTheTaskWithANameTypedKeepsItsAnswerAndEnterDoesNotHang() throws {
    let home = (dir as NSString).appendingPathComponent("home")
    try git(["init", "-q", "-b", "main", home], in: dir)
    try identify(home)
    try git(["commit", "-q", "--allow-empty", "-m", "a"], in: home)
    let (wc, task) = try launch(mainRepository: home)
    let palette = try open(wc, for: task, row: .open(.directory(path: toplevel)))
    let name = "feat/new-name"
    palette.query = name
    palette.onQueryChanged()
    XCTAssertTrue(
      pump { palette.items.contains { $0.action == .createBranch(name: name) } },
      "前提: 打った名前の作成行が出る")

    palette.clearTaskContext()

    XCTAssertTrue(
      pump { wc.model.worktreePaletteProvider?.cwd == home && palette.newBranchRules != nil },
      "前提: 開いた時点の workspace のリポジトリを読み直した")
    XCTAssertFalse(palette.isAwaitingBranchNameAnswer, "名前の答えは残る")
    palette.activate()
    XCTAssertTrue(pump { !palette.hasPendingActivation }, "↵ は預かられたままにならない")
  }
}
