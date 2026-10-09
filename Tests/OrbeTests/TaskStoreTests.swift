import XCTest

@testable import Orbe

/// タスク一覧の唯一の正 `TaskStore` の不変条件と、変異が `tasks.json` へ即時に届くことを固定する。
///
/// 壊れると何が起きるか: 制御 API も画面（⌘⇧X）も検証をここに任せているので、ここが緩むと空の
/// タイトルや「完了なのに待ち」のタスクがどの入口からも入る。ID を使い回すと、agent が会話をまたいで
/// 覚えた `orb task set 12` が別のタスクを書き換える。保存が漏れると、強制終了で人が書き溜めた一覧を失う。
///
/// 再起動は、同じ保存先から新しい `TaskStore` を読み直すことで測る。
final class TaskStoreTests: OrbeTestCase {
  private let past = Date(timeIntervalSince1970: 1_800_000_000)

  func draft(_ title: String, _ mutate: (inout TaskDraft) -> Void = { _ in }) -> TaskDraft {
    var d = TaskDraft(title: title)
    mutate(&d)
    return d
  }

  private func due(_ text: String) throws -> TaskItem.DueDate {
    try XCTUnwrap(TaskItem.DueDate(text))
  }

  /// 再起動相当。ディスクから読み直した一覧。
  func relaunched() -> TaskStore { TaskStore() }

  private func assertRejected(
    _ expected: TaskStoreError, _ body: () throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      XCTAssertEqual(error as? TaskStoreError, expected, file: file, line: line)
    }
  }

  func assertInvalid(
    _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      guard case .invalid = error as? TaskStoreError else {
        return XCTFail("不正な値として拒否されていない: \(error)", file: file, line: line)
      }
    }
  }

  // MARK: - 追加

  func testAddAppendsToTheEndWithDefaultsAndTrimmedTitle() throws {
    let store = TaskStore()

    let first = try store.add(draft("経費精算を出す"))
    let second = try store.add(draft("  レビューを返す \n"))

    XCTAssertEqual(store.tasks.map(\.id), [first.id, second.id], "新しいタスクは列の末尾に入る")
    XCTAssertEqual(second.id, first.id + 1)
    XCTAssertEqual(second.title, "レビューを返す", "タイトルは前後の空白を除いて持つ")
    XCTAssertEqual(second.status, .todo, "ステータスの既定は未着手")
    XCTAssertEqual(second.priority, .medium, "優先度の既定は中")
    XCTAssertNil(second.waiting)
    XCTAssertNil(second.due)
    XCTAssertEqual(second.description, "")
  }

  func testAddWithWaitingReasonStartsWaiting() throws {
    let store = TaskStore()

    let task = try store.add(draft("承認を取る") { $0.waitingReason = "  部長の返事  " })

    XCTAssertEqual(task.waiting?.reason, "部長の返事", "待ちの理由は前後の空白を除いて持つ")
  }

  func testAddRejectsBlankOrControlCharacterTitleAndLeavesTheListUnchanged() throws {
    let store = TaskStore()

    for title in ["", "   \n ", "一行目\n二行目", "タブ\t入り", "一行目\u{2028}二行目"] {
      assertInvalid({ _ = try store.add(draft(title)) })
    }

    XCTAssertTrue(store.tasks.isEmpty, "拒否した追加は一覧に残らない")
    XCTAssertTrue(relaunched().tasks.isEmpty, "拒否した追加はディスクにも残らない")
    XCTAssertEqual(try store.add(draft("最初")).id, 1, "拒否した追加は ID を消費しない")
  }

  /// 書式文字は行を壊さないので、ZWJ で組む絵文字やソフトハイフンを含むタイトルは通す。
  func testTitleWithFormatCharactersIsAccepted() throws {
    let store = TaskStore()

    for title in ["🧑‍💻 レビュー", "👨‍👩‍👧 買い物", "soft\u{00AD}hyphen"] {
      XCTAssertEqual(try store.add(draft(title)).title, title)
    }
  }

  func testAddRejectsBlankWaitingReasonOrDoneWithWaiting() throws {
    let store = TaskStore()

    assertInvalid({ _ = try store.add(draft("a") { $0.waitingReason = "  " }) })
    assertInvalid({
      _ = try store.add(
        draft("a") {
          $0.status = .done
          $0.waitingReason = "返事"
        })
    })

    XCTAssertTrue(store.tasks.isEmpty)
  }

  // MARK: - 変更

  func testUpdateChangesOnlyTheGivenFields() throws {
    let store = TaskStore()
    let original = try store.add(
      draft("元のタイトル") {
        $0.priority = .low
        $0.description = "元の詳細"
      })

    let updated = try store.update(
      original.id, TaskUpdate(title: "新しいタイトル", status: .inProgress, due: .set(due("2026-10-06"))))

    XCTAssertEqual(updated.title, "新しいタイトル")
    XCTAssertEqual(updated.status, .inProgress)
    XCTAssertEqual(updated.due, try due("2026-10-06"))
    XCTAssertEqual(updated.priority, .low, "渡していない項目は変わらない")
    XCTAssertEqual(updated.description, "元の詳細", "渡していない項目は変わらない")
    XCTAssertEqual(store.tasks, [updated], "返り値と一覧は同じものを見る")
  }

  func testUpdateClearRemovesDueWaitingWorkspaceAndDescription() throws {
    let store = TaskStore()
    let original = try store.add(
      draft("a") {
        $0.due = try? self.due("2026-10-06")
        $0.waitingReason = "返事"
        $0.workspace = UUID()
        $0.description = "詳細"
      })

    let cleared = try store.update(
      original.id,
      TaskUpdate(due: .clear, waitingReason: .clear, description: "", workspace: .clear))

    XCTAssertNil(cleared.due)
    XCTAssertNil(cleared.waiting)
    XCTAssertNil(cleared.workspace)
    XCTAssertEqual(cleared.description, "")
  }

  func testMarkingDoneClearsWaiting() throws {
    let store = TaskStore()
    let task = try store.add(draft("a") { $0.waitingReason = "返事" })

    let done = try store.update(task.id, TaskUpdate(status: .done))

    XCTAssertEqual(done.status, .done)
    XCTAssertNil(done.waiting, "完了にすると待ちは外れる")
  }

  func testDoneTaskCannotStartWaitingUnlessTheSameUpdateReopensIt() throws {
    let store = TaskStore()
    let task = try store.add(draft("a") { $0.status = .done })

    assertInvalid({ _ = try store.update(task.id, TaskUpdate(waitingReason: .set("返事"))) })
    assertInvalid({
      _ = try store.update(task.id, TaskUpdate(status: .done, waitingReason: .set("返事")))
    })
    XCTAssertEqual(store.tasks.first?.status, .done, "拒否した変更は一覧に残らない")

    let reopened = try store.update(
      task.id, TaskUpdate(status: .todo, waitingReason: .set("返事")))
    XCTAssertEqual(reopened.status, .todo)
    XCTAssertEqual(reopened.waiting?.reason, "返事", "同じ変更でステータスを戻せば待ちを入れられる")
  }

  func testChangingOnlyTheWaitingReasonKeepsWhenTheWaitStarted() throws {
    let waiting = TaskItem(
      id: 1, title: "a", status: .todo, wait: .waiting(.init(reason: "返事", since: past)),
      priority: .medium, due: nil, workspace: nil, description: "", createdAt: past, createdBy: nil)
    let store = TaskStore(
      file: TasksFile(version: TaskPersistence.version, nextId: 2, tasks: [waiting]))

    let updated = try store.update(1, TaskUpdate(waitingReason: .set("部長の返事")))

    XCTAssertEqual(updated.waiting?.reason, "部長の返事")
    XCTAssertEqual(updated.waiting?.since, past, "理由だけを変えても待ち始めた日時は動かない")
  }

  func testRejectedUpdateLeavesTheTaskUnchanged() throws {
    let store = TaskStore()
    let task = try store.add(draft("a"))

    assertInvalid({ _ = try store.update(task.id, TaskUpdate(title: " ", priority: .high)) })
    assertInvalid({
      _ = try store.update(task.id, TaskUpdate(priority: .high, waitingReason: .set("  ")))
    })
    assertInvalid({ _ = try store.update(task.id, TaskUpdate()) })

    XCTAssertEqual(store.tasks, [task], "一部の項目が不正なら、他の項目も変わらない")
    XCTAssertEqual(relaunched().tasks, [task])
  }

  func testUpdatingAnUnknownTaskIsNotFound() {
    let store = TaskStore()

    assertRejected(.notFound(9)) { _ = try store.update(9, TaskUpdate(title: "a")) }
  }

  // MARK: - 並べ替え・削除

  func testMoveBeforeAndAfterAnotherTaskReordersTheList() throws {
    let store = TaskStore()
    let ids = try ["1", "2", "3", "4"].map { try store.add(draft($0)).id }

    try store.move(ids[3], .before, ids[1])
    XCTAssertEqual(store.tasks.map(\.id), [ids[0], ids[3], ids[1], ids[2]], "指したタスクの直前へ入る")

    try store.move(ids[0], .after, ids[2])
    XCTAssertEqual(store.tasks.map(\.id), [ids[3], ids[1], ids[2], ids[0]], "指したタスクの直後へ入る")
  }

  func testMoveRelativeToItselfOrAnUnknownTaskIsRejectedAndKeepsTheOrder() throws {
    let store = TaskStore()
    let a = try store.add(draft("a")).id
    let b = try store.add(draft("b")).id

    assertInvalid({ try store.move(a, .before, a) })
    assertRejected(.notFound(99)) { try store.move(a, .after, 99) }
    assertRejected(.notFound(99)) { try store.move(99, .after, a) }

    XCTAssertEqual(store.tasks.map(\.id), [a, b])
  }

  func testDeleteRemovesTheTaskAndItsIdIsNeverReused() throws {
    let store = TaskStore()
    let a = try store.add(draft("a")).id
    let b = try store.add(draft("b")).id

    try store.delete(b)
    XCTAssertEqual(store.tasks.map(\.id), [a])
    assertRejected(.notFound(b)) { try store.delete(b) }

    let c = try store.add(draft("c")).id
    XCTAssertGreaterThan(c, b, "末尾のタスクを消しても、その ID は振り直さない")
    try store.delete(c)
    let afterRelaunch = try relaunched().add(draft("d")).id
    XCTAssertGreaterThan(afterRelaunch, c, "末尾を消してから再起動しても、採番位置は戻らない")
  }

  // MARK: - 即時保存

  func testEveryMutationReachesDiskWithoutAnExplicitSave() throws {
    let store = TaskStore()
    let workspace = UUID()
    let a = try store.add(
      draft("a") {
        $0.priority = .high
        $0.due = try? self.due("2028-02-29")
        $0.waitingReason = "返事"
        $0.description = "一行目\n二行目"
        $0.workspace = workspace
        $0.createdBy = "claude"
      })
    XCTAssertEqual(relaunched().tasks, store.tasks, "追加は即座にディスクへ届き、全項目が往復で保たれる")

    let b = try store.add(draft("b"))
    try store.move(b.id, .before, a.id)
    XCTAssertEqual(relaunched().tasks.map(\.id), [b.id, a.id], "並べ替えは即座にディスクへ届く")

    _ = try store.update(a.id, TaskUpdate(status: .done))
    XCTAssertEqual(relaunched().tasks, store.tasks, "変更は即座にディスクへ届く")

    try store.delete(b.id)
    XCTAssertEqual(relaunched().tasks, store.tasks, "削除は即座にディスクへ届く")
  }
}
