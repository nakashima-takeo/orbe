import AppKit
import XCTest

@testable import Orbe

/// タスクの 5 動詞のドメイン側を、実 `WindowController` 越しに固定する。外に見せる起動ごとの
/// workspaceId とタスクが持つ永続 ID の変換、呼び出し元タブからの既定の付き先と追加者、
/// ストアの拒否から制御エラーへの写像、応答の形。
///
/// 壊れると何が起きるか: タブ内の agent が workspace を省いて足したタスクが前面の workspace（人が
/// 見ている別の workspace）に付く。workspace を改名・削除しただけでタスクの結び付けが別の workspace へ
/// ずれる、または壊れた参照のまま名前が出る。拒否が成功に化け、`orb task set` が黙って何もしない。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
/// workspace の id はプロセス全域の IdGen で採番され予測不能なため、`controlListWorkspaces()` から読む。
final class WindowControllerTaskControlTests: OrbeTestCase {
  private let backgroundId = UUID()

  func launch() throws -> WindowController {
    let tab = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [tab]),
        WorkspaceState(
          name: "background", rootPath: "/tmp", activeTab: 0, tabs: [tab],
          persistentId: backgroundId),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  private func workspaceId(_ wc: WindowController, _ name: String) throws -> Int {
    try XCTUnwrap(
      wc.controlListWorkspaces().first { $0["name"] as? String == name }?["id"] as? Int)
  }

  private func backgroundTab(_ wc: WindowController) throws -> TerminalTab {
    try XCTUnwrap(wc.workspaces.first { $0.name == "background" }?.tabs.first)
  }

  func success(
    _ result: Result<Any, ControlError>, file: StaticString = #filePath, line: UInt = #line
  ) throws -> [String: Any] {
    switch result {
    case .success(let value):
      return try XCTUnwrap(value as? [String: Any], file: file, line: line)
    case .failure(let error):
      XCTFail("失敗した: \(error.code) \(error.message)", file: file, line: line)
      return [:]
    }
  }

  func code(_ result: Result<Any, ControlError>) -> Int? {
    if case .failure(let error) = result { return error.code }
    return nil
  }

  func added(
    _ wc: WindowController, _ title: String = "a", workspaceId: ClearableValue<Int>? = nil,
    callerTabId: Int? = nil, file: StaticString = #filePath, line: UInt = #line
  ) throws -> [String: Any] {
    try XCTUnwrap(
      success(
        wc.controlAddTask(
          TaskDraft(title: title), workspaceId: workspaceId, callerTabId: callerTabId),
        file: file, line: line)["task"] as? [String: Any], file: file, line: line)
  }

  func listed(_ wc: WindowController, workspaceId: Int? = nil) throws -> [[String: Any]] {
    try XCTUnwrap(
      success(wc.controlListTasks(workspaceId: workspaceId))["tasks"] as? [[String: Any]])
  }

  // MARK: - 既定の付き先と追加者

  func testAddWithoutWorkspaceAttachesToTheCallerTabsWorkspaceAndRecordsItsAgent() throws {
    let wc = try launch()
    let tab = try backgroundTab(wc)
    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "working", sessionId: "s-1"))

    let task = try added(wc, callerTabId: tab.id)

    XCTAssertEqual(
      task["workspaceId"] as? Int, try workspaceId(wc, "background"),
      "前面の workspace ではなく呼び出し元タブの workspace に付く")
    XCTAssertEqual(task["workspaceName"] as? String, "background")
    XCTAssertEqual(task["createdBy"] as? String, "claude", "追加者として呼び出し元タブの agent 名が残る")
  }

  /// 追加者が残るのは agent が自分のターンの中（working）で足したときだけ。ターンを終えた agent の
  /// タブ（終了を報告しない codex / agy が去った後のシェルを含む）から人が打った追加を agent の名で残さない。
  func testAddFromATabWhoseAgentIsNotWorkingRecordsNoAuthor() throws {
    let wc = try launch()
    let tab = try backgroundTab(wc)

    for state in ["idle", "done", "waiting"] {
      wc.controlReportAgent(
        tab: tab, report: AgentHookReport(agent: "codex", state: state, sessionId: "s-1"))
      let task = try added(wc, callerTabId: tab.id)
      XCTAssertEqual(task["workspaceName"] as? String, "background", "\(state): 付き先は呼び出し元タブのまま")
      XCTAssertNil(task["createdBy"], "\(state) を報告しているタブからの追加は追加者を残さない")
    }
  }

  func testAddFromATabWithoutAnAgentAttachesButRecordsNoAuthor() throws {
    let wc = try launch()

    let task = try added(wc, callerTabId: try backgroundTab(wc).id)

    XCTAssertEqual(task["workspaceName"] as? String, "background")
    XCTAssertNil(task["createdBy"], "agent の居ないタブ（人のシェル）からの追加は追加者を残さない")
  }

  func testAddWithoutAKnownCallerAttachesToNoWorkspace() throws {
    let wc = try launch()

    for caller in [nil, 999_999] as [Int?] {
      let task = try added(wc, callerTabId: caller)
      XCTAssertNil(
        task["workspaceId"], "呼び出し元が分からなければ前面の workspace にも付けない: \(String(describing: caller))")
      XCTAssertNil(task["workspaceName"])
      XCTAssertNil(task["createdBy"])
    }
    XCTAssertEqual(try listed(wc).count, 2, "未知のタブを名乗っても追加自体は失敗させない")
  }

  func testExplicitWorkspaceOverridesTheCallerTab() throws {
    let wc = try launch()
    let caller = try backgroundTab(wc).id

    let none = try added(wc, workspaceId: .clear, callerTabId: caller)
    XCTAssertNil(none["workspaceId"], "null は呼び出し元タブがあっても「なし」")

    let main = try added(wc, workspaceId: .set(try workspaceId(wc, "main")), callerTabId: caller)
    XCTAssertEqual(main["workspaceName"] as? String, "main", "id を渡せばその workspace")

    XCTAssertEqual(
      code(wc.controlAddTask(TaskDraft(title: "x"), workspaceId: .set(999_999), callerTabId: nil)),
      -32004, "未知の workspace は -32004")
    XCTAssertEqual(try listed(wc).count, 2, "拒否した追加は一覧に残らない")
  }

  // MARK: - 応答の形と絞り込み

  func testListedTaskCarriesItsValuesAndOmitsAbsentOnes() throws {
    let wc = try launch()
    var draft = TaskDraft(title: "経費精算")
    draft.status = .inProgress
    draft.priority = .high
    draft.due = TaskItem.DueDate("2026-10-06")
    draft.waitingReason = "返事"
    draft.description = "一行目\n二行目"
    draft.links = [
      TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "Owner/Name", number: 221)), kind: .issue),
      TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/n", number: 214)), kind: .pr),
    ]
    _ = try success(wc.controlAddTask(draft, workspaceId: nil, callerTabId: nil))
    _ = try added(wc, "最小")

    let tasks = try listed(wc)
    let full = tasks[0]
    XCTAssertEqual(full["title"] as? String, "経費精算")
    XCTAssertEqual(full["status"] as? String, "in_progress")
    XCTAssertEqual(full["priority"] as? String, "high")
    XCTAssertEqual(full["due"] as? String, "2026-10-06")
    XCTAssertEqual(full["description"] as? String, "一行目\n二行目")
    let waiting = try XCTUnwrap(full["waiting"] as? [String: Any])
    XCTAssertEqual(waiting["reason"] as? String, "返事")
    XCTAssertEqual(
      (full["links"] as? [[String: Any]])?.map { NSDictionary(dictionary: $0) },
      [
        ["kind": "issue", "repo": "owner/name", "number": 221],
        ["kind": "pr", "repo": "o/n", "number": 214],
      ], "結び付きは順のまま {kind, repo, number}、repo は小文字")
    let iso = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
    for stamp in [full["createdAt"], waiting["since"]] {
      let text = try XCTUnwrap(stamp as? String)
      XCTAssertNotNil(
        text.range(of: iso, options: .regularExpression), "時刻は UTC・ミリ秒の ISO 8601: \(text)")
    }

    let minimal = tasks[1]
    XCTAssertEqual(minimal["taskId"] as? Int, (full["taskId"] as? Int).map { $0 + 1 })
    XCTAssertEqual(minimal["status"] as? String, "todo")
    XCTAssertEqual(minimal["priority"] as? String, "medium")
    XCTAssertEqual(minimal["description"] as? String, "")
    for key in ["waiting", "due", "workspaceId", "workspaceName", "createdBy", "links"] {
      XCTAssertNil(minimal[key], "無い値はキーごと出さない: \(key)")
    }
  }

  func testListFiltersByWorkspaceKeepingTheColumnOrder() throws {
    let wc = try launch()
    let main = try workspaceId(wc, "main")
    let caller = try backgroundTab(wc).id
    _ = try added(wc, "m1", workspaceId: .set(main))
    _ = try added(wc, "b1", callerTabId: caller)
    _ = try added(wc, "none")
    _ = try added(wc, "m2", workspaceId: .set(main))

    XCTAssertEqual(
      try listed(wc).compactMap { $0["title"] as? String }, ["m1", "b1", "none", "m2"])
    XCTAssertEqual(
      try listed(wc, workspaceId: main).compactMap { $0["title"] as? String }, ["m1", "m2"])
    XCTAssertEqual(
      code(wc.controlListTasks(workspaceId: 999_999)), -32004, "未知の workspace は -32004")
  }

  // MARK: - 変更・拒否

  func testUpdateMovesTheTaskBetweenWorkspacesAndClearsIt() throws {
    let wc = try launch()
    let taskId = try XCTUnwrap(try added(wc)["taskId"] as? Int)
    let background = try workspaceId(wc, "background")

    let moved = try XCTUnwrap(
      success(wc.controlUpdateTask(taskId: taskId, TaskUpdate(), workspaceId: .set(background)))[
        "task"] as? [String: Any])
    XCTAssertEqual(moved["workspaceId"] as? Int, background)

    XCTAssertEqual(
      code(wc.controlUpdateTask(taskId: taskId, TaskUpdate(), workspaceId: .set(999_999))), -32004)
    XCTAssertEqual(try listed(wc).first?["workspaceId"] as? Int, background, "拒否した変更は付き先を変えない")

    let cleared = try XCTUnwrap(
      success(wc.controlUpdateTask(taskId: taskId, TaskUpdate(), workspaceId: .clear))["task"]
        as? [String: Any])
    XCTAssertNil(cleared["workspaceId"])
  }

  func testStoreRejectionsMapToTheControlErrorVocabulary() throws {
    let wc = try launch()
    let taskId = try XCTUnwrap(try added(wc)["taskId"] as? Int)
    let issue = TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/n", number: 221)), kind: .issue)
    var owner = TaskDraft(title: "owner")
    owner.links = [issue]
    let ownerTask = try XCTUnwrap(
      try success(wc.controlAddTask(owner, workspaceId: nil, callerTabId: nil))["task"]
        as? [String: Any])
    let ownerId = try XCTUnwrap(ownerTask["taskId"] as? Int)
    let before = try listed(wc)

    XCTAssertEqual(
      code(wc.controlUpdateTask(taskId: 999_999, TaskUpdate(title: "x"), workspaceId: nil)), -32004,
      "未知のタスクは -32004")
    XCTAssertEqual(code(wc.controlDeleteTask(taskId: 999_999)), -32004)
    XCTAssertEqual(code(wc.controlMoveTask(taskId: taskId, .before, anchorTaskId: 999_999)), -32004)
    XCTAssertEqual(
      code(wc.controlAddTask(TaskDraft(title: "  "), workspaceId: nil, callerTabId: nil)), -32602,
      "不正な値は -32602")
    XCTAssertEqual(
      code(wc.controlUpdateTask(taskId: taskId, TaskUpdate(), workspaceId: nil)), -32602,
      "変更項目が 1 つも無ければ -32602")
    XCTAssertEqual(
      code(
        wc.controlUpdateTask(
          taskId: taskId, TaskUpdate(status: .done, waitingReason: .set("返事")), workspaceId: nil)),
      -32602, "完了と待ちの同時指定は -32602")
    XCTAssertEqual(code(wc.controlMoveTask(taskId: taskId, .after, anchorTaskId: taskId)), -32602)
    var relink = TaskUpdate()
    relink.links = [issue]
    guard case .failure(let clash) = wc.controlUpdateTask(taskId: taskId, relink, workspaceId: nil)
    else { return XCTFail("ほかのタスクに付いた項目の結び付けが通った") }
    XCTAssertEqual(clash.code, -32602, "ほかのタスクに付いた項目は -32602")
    XCTAssertTrue(
      clash.message.contains("task \(ownerId)"), "拒否の文に相手のタスクの ID: \(clash.message)")

    XCTAssertEqual(
      try listed(wc).map { NSDictionary(dictionary: $0) },
      before.map { NSDictionary(dictionary: $0) },
      "拒否した要求は一覧を変えない")
  }

  func testMoveAndDeleteReachTheList() throws {
    let wc = try launch()
    let a = try XCTUnwrap(try added(wc, "a")["taskId"] as? Int)
    let b = try XCTUnwrap(try added(wc, "b")["taskId"] as? Int)

    XCTAssertEqual(
      try success(wc.controlMoveTask(taskId: b, .before, anchorTaskId: a))["ok"] as? Bool, true)
    XCTAssertEqual(try listed(wc).compactMap { $0["taskId"] as? Int }, [b, a])

    XCTAssertEqual(try success(wc.controlDeleteTask(taskId: a))["ok"] as? Bool, true)
    XCTAssertEqual(try listed(wc).compactMap { $0["taskId"] as? Int }, [b])
  }

  // MARK: - workspace の参照

  func testBindingSurvivesRenameAndRootChange() throws {
    let wc = try launch()
    let background = try workspaceId(wc, "background")
    _ = try added(wc, callerTabId: try backgroundTab(wc).id)

    _ = try success(wc.controlRenameWorkspace(workspaceId: background, name: "renamed"))
    _ = try success(wc.controlSetWorkspaceRoot(workspaceId: background, rootPath: "/tmp/elsewhere"))

    let task = try XCTUnwrap(try listed(wc).first)
    XCTAssertEqual(task["workspaceId"] as? Int, background)
    XCTAssertEqual(task["workspaceName"] as? String, "renamed", "名前は今の名前で見せる")
  }

  func testRemovedWorkspaceReadsAsNoWorkspaceWithoutRewritingTasks() throws {
    let wc = try launch()
    let background = try workspaceId(wc, "background")
    _ = try added(wc, callerTabId: try backgroundTab(wc).id)

    _ = try success(wc.controlRemoveWorkspace(workspaceId: background))

    let task = try XCTUnwrap(try listed(wc).first)
    XCTAssertNil(task["workspaceId"], "削除された workspace への参照は「なし」として見える")
    XCTAssertNil(task["workspaceName"])
    XCTAssertTrue(try listed(wc, workspaceId: try workspaceId(wc, "main")).isEmpty)
    XCTAssertEqual(
      TaskPersistence.load()?.tasks.first?.workspace, backgroundId,
      "tasks.json は書き換えない（workspace 構成の退避物を戻せば結び付きも戻る）")
  }

  func testLaunchReadsSavedTasksAndResolvesThemToRestoredWorkspaces() throws {
    let saved = TaskItem(
      id: 4, title: "前回のタスク", status: .todo, waiting: nil, priority: .low, due: nil,
      workspace: backgroundId, description: "",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      createdBy: "claude")
    TaskPersistence.save(TasksFile(version: TaskPersistence.version, nextId: 7, tasks: [saved]))

    let wc = try launch()

    let task = try XCTUnwrap(try listed(wc).first)
    XCTAssertEqual(task["taskId"] as? Int, 4)
    XCTAssertEqual(task["workspaceName"] as? String, "background", "永続 ID で前回の workspace に結び付く")
    XCTAssertEqual(try added(wc)["taskId"] as? Int, 7, "採番位置も前回から続く")
  }
}
