import OrbeTestSupport
import XCTest

@testable import Orbe

/// タスクの worktree の不変条件（1 つの worktree は高々 1 タスク）と、⌘T の ↵ で作業を始める `begin`、
/// 外した Issue・PR の記録、PR の自動の結び付け `linkFromBranch` を固定する。
///
/// 壊れると何が起きるか: 1 つの worktree が 2 つのタスクに付くと、その worktree で動く agent の札も PR の
/// 自動の結び付けも、どのタスクのものか決まらない。`begin` が前の持ち主から外さないと、次の起動で tasks.json
/// ごと退避され一覧が空で始まる。外した PR を覚えないと、人が外した PR が ⌘⇧X を開くたびに付き直る。
extension TaskStoreTests {
  private var worktree: TaskWorktree { TaskWorktree(key: "/repo/wt/issue-221") }

  private func link(_ kind: GitHubItemKind, _ number: Int) throws -> TaskLink {
    TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/n", number: number)), kind: kind)
  }

  private func update(_ mutate: (inout TaskUpdate) -> Void) -> TaskUpdate {
    var update = TaskUpdate()
    mutate(&update)
    return update
  }

  // MARK: - 1 worktree 1 タスク

  func testAWorktreeHeldByAnotherTaskIsRejectedNamingThatTask() throws {
    let store = TaskStore()
    let owner = try store.add(draft("owner") { $0.worktree = worktree })
    let other = try store.add(draft("other"))

    for body in [
      { _ = try store.add(self.draft("b") { $0.worktree = self.worktree }) },
      { _ = try store.update(other.id, self.update { $0.worktree = .set(self.worktree) }) },
    ] {
      XCTAssertThrowsError(try body()) { error in
        guard case .invalid(let message) = error as? TaskStoreError else {
          return XCTFail("不正な値として拒否されていない: \(error)")
        }
        XCTAssertTrue(message.contains("task \(owner.id)"), "拒否の文に持ち主のタスクが無い: \(message)")
      }
    }

    XCTAssertEqual(store.tasks.map(\.title), ["owner", "other"], "拒否した追加は一覧に残らない")
    XCTAssertNil(store.tasks.last?.worktree, "拒否した変更は worktree を変えない")
  }

  func testTheWorktreeSurvivesRelaunchAndIsDetachedByClearing() throws {
    let store = TaskStore()
    let task = try store.add(draft("a") { $0.worktree = worktree })
    XCTAssertEqual(relaunched().tasks.first?.worktree, worktree, "再起動しても残る")

    _ = try store.update(task.id, update { $0.worktree = .clear })

    XCTAssertNil(store.tasks.first?.worktree)
    XCTAssertNil(relaunched().tasks.first?.worktree, "外したことも保存される")
  }

  // MARK: - begin

  func testBeginAttachesTheWorktreeAndStartsATodoTask() throws {
    let store = TaskStore()
    let task = try store.add(draft("a"))

    let previous = try store.begin(task.id, worktree: worktree)

    XCTAssertNil(previous, "前の持ち主はいない")
    XCTAssertEqual(store.tasks.first?.status, .inProgress)
    XCTAssertEqual(store.tasks.first?.worktree, worktree)
    XCTAssertEqual(relaunched().tasks, store.tasks, "保存される")
  }

  func testBeginReopensADoneTask() throws {
    let store = TaskStore()
    let task = try store.add(draft("a") { $0.status = .done })

    try store.begin(task.id, worktree: worktree)

    XCTAssertEqual(store.tasks.first?.status, .inProgress)
  }

  /// 付け替えは 1 つの変異で起こり、読み直した一覧も不変条件を満たす（退避されない）。
  func testBeginMovesTheWorktreeFromItsPreviousOwner() throws {
    let store = TaskStore()
    let owner = try store.add(draft("owner") { $0.worktree = worktree })
    let task = try store.add(draft("a"))

    let previous = try store.begin(task.id, worktree: worktree)

    XCTAssertEqual(previous, owner.id, "外した前の持ち主を返す")
    XCTAssertEqual(store.tasks.map(\.worktree), [nil, worktree])
    XCTAssertEqual(relaunched().tasks.map(\.worktree), [nil, worktree], "読み直しても付け替わったまま")
  }

  func testBeginOnAMissingTaskLeavesTheOwnerUntouched() throws {
    let store = TaskStore()
    let owner = try store.add(draft("owner") { $0.worktree = worktree })

    XCTAssertThrowsError(try store.begin(owner.id + 1, worktree: worktree)) { error in
      XCTAssertEqual(error as? TaskStoreError, .notFound(owner.id + 1))
    }

    XCTAssertEqual(store.tasks.first?.worktree, worktree, "持ち主から外さない")
  }

  // MARK: - 付けたときのブランチ

  /// worktree を付けると（追加・変更・begin のどれでも）、その時そこで checkout していたブランチを記録し、
  /// 再起動しても残る。
  func testAttachingAWorktreeRecordsTheBranchCheckedOutThere() throws {
    let main = TestScratch.caseDir.appendingPathComponent("repo").path
    let linked = TestScratch.caseDir.appendingPathComponent("wt").path
    let git = { (args: [String]) in
      XCTAssertTrue(
        GitRunner.shared.runSync(args, cwd: main).isSuccess, args.joined(separator: " "))
    }
    try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
    git(["init", "-q", "-b", "main"])
    git([
      "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty",
      "-m", "init",
    ])
    git(["worktree", "add", "-q", "-b", "feat", linked])
    let store = TaskStore()

    _ = try store.add(draft("added") { $0.worktree = TaskWorktree(key: main) })
    XCTAssertEqual(store.tasks.last?.worktreeBranch, "main", "追加")
    let updated = try store.add(draft("updated"))
    _ = try store.update(updated.id, update { $0.worktree = .set(TaskWorktree(key: linked)) })
    XCTAssertEqual(store.tasks.last?.worktreeBranch, "feat", "変更")
    git(["checkout", "-q", "-b", "other"])
    let begun = try store.add(draft("begun"))
    try store.begin(begun.id, worktree: TaskWorktree(key: main))
    XCTAssertEqual(store.tasks.last?.worktreeBranch, "other", "begin")

    XCTAssertEqual(relaunched().tasks.map(\.worktreeBranch), store.tasks.map(\.worktreeBranch))
  }

  // MARK: - 外した項目

  func testUnlinkingRemembersTheItemAndLinkingItAgainForgetsIt() throws {
    let store = TaskStore()
    let issue = try link(.issue, 221)
    let pr = try link(.pr, 230)
    let task = try store.add(draft("a") { $0.links = [issue, pr] })

    _ = try store.update(task.id, update { $0.links = [issue] })
    XCTAssertEqual(store.tasks.first?.unlinked, [pr.item], "外した PR を覚える")
    XCTAssertEqual(relaunched().tasks.first?.unlinked, [pr.item], "再起動しても覚えている")

    _ = try store.update(task.id, update { $0.links = [issue, pr] })
    XCTAssertEqual(store.tasks.first?.unlinked, [], "手で付け直すと忘れる")
  }

  // MARK: - linkFromBranch

  func testLinkFromBranchAppendsThePullRequestAfterTheExistingLinks() throws {
    let store = TaskStore()
    let issue = try link(.issue, 221)
    let pr = try link(.pr, 230)
    let task = try store.add(draft("a") { $0.links = [issue] })

    XCTAssertTrue(store.linkFromBranch(task.id, pr))

    XCTAssertEqual(store.tasks.first?.links, [issue, pr], "主は変えず末尾に足す")
    XCTAssertEqual(relaunched().tasks.first?.links, [issue, pr], "保存される")
  }

  func testLinkFromBranchSkipsAPullRequestThePersonUnlinked() throws {
    let store = TaskStore()
    let pr = try link(.pr, 230)
    let task = try store.add(draft("a") { $0.links = [pr] })
    _ = try store.update(task.id, update { $0.links = [] })

    XCTAssertFalse(store.linkFromBranch(task.id, pr))

    XCTAssertEqual(store.tasks.first?.links, [])
    XCTAssertEqual(store.tasks.first?.unlinked, [pr.item], "外した記録は変えない")
  }

  func testLinkFromBranchSkipsADoneTask() throws {
    let store = TaskStore()
    let task = try store.add(draft("a") { $0.status = .done })

    XCTAssertFalse(store.linkFromBranch(task.id, try link(.pr, 230)))

    XCTAssertEqual(store.tasks.first?.links, [])
  }

  func testLinkFromBranchSkipsAPullRequestAlreadyLinkedAnywhere() throws {
    let store = TaskStore()
    let pr = try link(.pr, 230)
    let holder = try store.add(draft("holder") { $0.links = [pr] })
    let task = try store.add(draft("a"))

    XCTAssertFalse(store.linkFromBranch(task.id, pr), "別のタスクが持つ")
    XCTAssertFalse(store.linkFromBranch(holder.id, pr), "自分が既に持つ")

    XCTAssertEqual(store.tasks.map(\.links), [[pr], []])
  }
}
