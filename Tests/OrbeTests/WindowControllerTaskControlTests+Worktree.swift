import OrbeTestSupport
import XCTest

@testable import Orbe

/// タスクの worktree の制御 API 側。実在するディレクトリだけを受けて worktree のルートに揃えること、
/// ほかのタスクが持つ worktree の拒否、`null` で外すこと、一覧に出す条件。
///
/// 壊れると何が起きるか: agent が worktree の中から `orb task set 12 --worktree .` と打っても、タスクの行に
/// その worktree の agent の札が出ない。消えたディレクトリが `list_tasks` に出て、agent がそこへ cd しようと
/// する。外した PR の内部の記録が agent に見え、agent が読み書きしようとする。
extension WindowControllerTaskControlTests {
  /// caseDir に置く git の worktree のルートと、その中のサブディレクトリ。
  private func repository() throws -> (root: String, nested: String) {
    let root = TestScratch.caseDir.appendingPathComponent("repo").path
    let nested = (root as NSString).appendingPathComponent("Sources/App")
    try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: root + "/.git", withIntermediateDirectories: true)
    return (root, nested)
  }

  private func addTask(
    _ wc: WindowController, _ title: String, worktree: String
  ) -> Result<Any, ControlError> {
    wc.controlAddTask(
      TaskDraft(title: title), workspaceId: nil, callerTabId: nil, worktree: worktree)
  }

  func testAWorktreeIsLiftedToItsRootAndListedOnlyWhileTheDirectoryExists() throws {
    let wc = try launch()
    let repo = try repository()

    _ = try success(addTask(wc, "a", worktree: repo.nested))

    XCTAssertEqual(
      try listed(wc).first?["worktree"] as? String, GitWorktreeRoot.normalizedPath(repo.root),
      "worktree の中のサブディレクトリはルートに揃う")
    try FileManager.default.removeItem(atPath: repo.root)
    XCTAssertNil(try listed(wc).first?["worktree"], "ディレクトリが消えたら出さない")
  }

  func testAWorktreeThatIsNotAnExistingDirectoryIsRejected() throws {
    let wc = try launch()
    let taskId = try XCTUnwrap(try added(wc)["taskId"] as? Int)
    let gone = TestScratch.caseDir.appendingPathComponent("gone").path

    XCTAssertEqual(code(addTask(wc, "b", worktree: gone)), -32602, "実在しない")
    XCTAssertEqual(
      code(
        wc.controlUpdateTask(
          taskId: taskId, TaskUpdate(), workspaceId: nil, worktree: .set("repo"))), -32602,
      "相対パス")
    XCTAssertEqual(try listed(wc).count, 1, "拒否した追加は一覧に残らない")
  }

  /// 改行・制御文字を含む実在のディレクトリは拒む（受けると、次の起動で tasks.json が丸ごと退避される）。
  func testADirectoryWithANewlineOrControlCharacterIsRejected() throws {
    let wc = try launch()
    let taskId = try XCTUnwrap(try added(wc)["taskId"] as? Int)
    let before = try listed(wc).map { NSDictionary(dictionary: $0) }

    for name in ["a\nb", "a\u{7}b"] {
      let path = TestScratch.caseDir.appendingPathComponent(name).path
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

      XCTAssertEqual(
        code(addTask(wc, "b", worktree: path)), -32602, "add_task: \(name.debugDescription)")
      XCTAssertEqual(
        code(
          wc.controlUpdateTask(
            taskId: taskId, TaskUpdate(), workspaceId: nil, worktree: .set(path))), -32602,
        "update_task: \(name.debugDescription)")
    }
    XCTAssertEqual(
      try listed(wc).map { NSDictionary(dictionary: $0) }, before, "拒否した要求は一覧を変えない")
  }

  func testAWorktreeHeldByAnotherTaskIsRejectedWithThatTasksId() throws {
    let wc = try launch()
    let repo = try repository()
    let owner = try XCTUnwrap(
      try success(addTask(wc, "owner", worktree: repo.root))["task"] as? [String: Any])
    let ownerId = try XCTUnwrap(owner["taskId"] as? Int)
    let taskId = try XCTUnwrap(try added(wc)["taskId"] as? Int)

    guard
      case .failure(let clash) = wc.controlUpdateTask(
        taskId: taskId, TaskUpdate(), workspaceId: nil, worktree: .set(repo.nested))
    else { return XCTFail("ほかのタスクが持つ worktree を付けられた") }

    XCTAssertEqual(clash.code, -32602)
    XCTAssertTrue(
      clash.message.contains("task \(ownerId)"), "拒否の文に相手のタスクの ID: \(clash.message)")
  }

  func testUpdateWithNullDetachesTheWorktree() throws {
    let wc = try launch()
    let repo = try repository()
    let task = try XCTUnwrap(
      try success(addTask(wc, "a", worktree: repo.root))["task"] as? [String: Any])
    let taskId = try XCTUnwrap(task["taskId"] as? Int)

    let updated = try XCTUnwrap(
      success(
        wc.controlUpdateTask(taskId: taskId, TaskUpdate(), workspaceId: nil, worktree: .clear))[
          "task"] as? [String: Any])

    XCTAssertNil(updated["worktree"])
    XCTAssertNil(wc.taskStore.tasks.first?.worktree)
  }

  /// 外した項目は自動の結び付けのための内部の記録で、agent には見せない。
  func testUnlinkedItemsAreNotListed() throws {
    let wc = try launch()
    var draft = TaskDraft(title: "a")
    draft.links = [
      TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/n", number: 230)), kind: .pr)
    ]
    let task = try XCTUnwrap(
      try success(wc.controlAddTask(draft, workspaceId: nil, callerTabId: nil))["task"]
        as? [String: Any])
    var unlink = TaskUpdate()
    unlink.links = []
    _ = try success(
      wc.controlUpdateTask(
        taskId: try XCTUnwrap(task["taskId"] as? Int), unlink, workspaceId: nil))

    XCTAssertEqual(wc.taskStore.tasks.first?.unlinked.count, 1, "前提: 外した PR を覚えている")
    XCTAssertEqual(
      Set(try XCTUnwrap(listed(wc).first).keys),
      ["taskId", "title", "status", "priority", "description", "createdAt"], "外した項目のキーは無い")
  }
}
