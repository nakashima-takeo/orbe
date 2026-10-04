import XCTest

@testable import Orbe

/// 画面の付け替え・選んで結び付ける `attach`（項目を前の持ち主から外し、選んだタスクの末尾に足す 1 回の変異）。
///
/// 壊れると何が起きるか: 付け替えた項目が前のタスクにも残り、1 項目 1 タスクの不変条件が破れて次の起動で
/// tasks.json ごと退避される。外した側に記録が残らないと、ブランチの PR が ⌘⇧X を開くたびに前のタスクへ
/// 付き直る。保存が漏れると、付け替えが再起動で戻る。
extension TaskStoreTests {
  private func attachLink(_ kind: GitHubItemKind, _ number: Int) throws -> TaskLink {
    TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/n", number: number)), kind: kind)
  }

  private func links(_ links: [TaskLink]) -> TaskUpdate {
    var update = TaskUpdate()
    update.links = links
    return update
  }

  func testAttachMovesTheItemFromItsOwnerToTheEndOfTheChosenTask() throws {
    let store = TaskStore()
    let moved = try attachLink(.issue, 221)
    let kept = try attachLink(.pr, 230)
    let owner = try store.add(draft("owner") { $0.links = [moved] })
    let target = try store.add(draft("target") { $0.links = [kept] })

    let previous = try store.attach(moved, to: target.id)

    XCTAssertEqual(previous, owner.id, "前の持ち主を返す")
    XCTAssertEqual(store.tasks.map(\.links), [[], [kept, moved]], "前から消え、選んだタスクの末尾に入る")
    XCTAssertEqual(relaunched().tasks.map(\.links), [[], [kept, moved]], "読み直しても付け替わったまま")
  }

  /// 外した側は外した項目に記録し、足した側からは記録を消す（`update` で外す・付けるのと同じ規則）。
  func testAttachRemembersTheItemOnTheOwnerAndForgetsItOnTheTarget() throws {
    let store = TaskStore()
    let item = try attachLink(.pr, 230)
    let owner = try store.add(draft("owner"))
    let target = try store.add(draft("target") { $0.links = [item] })
    _ = try store.update(target.id, links([]))
    _ = try store.update(owner.id, links([item]))
    XCTAssertEqual(store.tasks.map(\.unlinked), [[], [item.item]], "前提: 選ぶタスクが一度外している")

    try store.attach(item, to: target.id)

    XCTAssertEqual(store.tasks.map(\.unlinked), [[item.item], []])
    XCTAssertEqual(relaunched().tasks.map(\.unlinked), [[item.item], []])
  }

  func testAttachingAnUnlinkedItemReturnsNoPreviousOwner() throws {
    let store = TaskStore()
    let item = try attachLink(.issue, 221)
    let target = try store.add(draft("target"))

    XCTAssertNil(try store.attach(item, to: target.id))
    XCTAssertEqual(store.tasks.first?.links, [item])
  }

  /// 選んだタスクが既に持っていれば何もしない（並びも外した項目の記録も変えない）。
  func testAttachingAnItemTheTaskAlreadyHasChangesNothing() throws {
    let store = TaskStore()
    let first = try attachLink(.issue, 221)
    let second = try attachLink(.pr, 230)
    let task = try store.add(draft("a") { $0.links = [first, second] })

    XCTAssertNil(try store.attach(first, to: task.id))
    XCTAssertEqual(store.tasks.first?.links, [first, second], "末尾へ移さない")
  }

  func testAttachToAMissingTaskLeavesTheOwnerUntouched() throws {
    let store = TaskStore()
    let item = try attachLink(.issue, 221)
    let owner = try store.add(draft("owner") { $0.links = [item] })

    XCTAssertThrowsError(try store.attach(item, to: owner.id + 1)) { error in
      XCTAssertEqual(error as? TaskStoreError, .notFound(owner.id + 1))
    }
    XCTAssertEqual(store.tasks.first?.links, [item], "持ち主から外さない")
    XCTAssertEqual(store.tasks.first?.unlinked, [])
  }
}
