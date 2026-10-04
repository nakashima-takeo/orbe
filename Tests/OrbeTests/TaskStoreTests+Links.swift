import XCTest

@testable import Orbe

/// タスクと GitHub の Issue・PR の結び付きの不変条件（同じタスクの中で重複しない・1 つの項目は 1 つの
/// タスクにだけ付く）と、結び付きが順ごと保存されること。
///
/// 壊れると何が起きるか: 同じ Issue が 2 つのタスクに付くと、GitHub タブの「結び付いた行」や
/// 「この Issue の worktree」が、どちらのタスクを指すか決められない。拒否の文に相手のタスクが無いと、
/// agent は外す相手を知れず付け替えられない。順が崩れると、行の頭に出る主が入れ替わる。
extension TaskStoreTests {
  private func link(_ kind: GitHubItemKind, _ repo: String, _ number: Int) throws -> TaskLink {
    TaskLink(item: try XCTUnwrap(GitHubItemID(repo: repo, number: number)), kind: kind)
  }

  private func linksUpdate(_ links: [TaskLink]) -> TaskUpdate {
    var update = TaskUpdate()
    update.links = links
    return update
  }

  private func assertInvalid(
    mentioning text: String, _ body: () throws -> Void, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      guard case .invalid(let message) = error as? TaskStoreError else {
        return XCTFail("不正な値として拒否されていない: \(error)", file: file, line: line)
      }
      XCTAssertTrue(
        message.contains(text), "拒否の文に「\(text)」が無い: \(message)", file: file, line: line)
    }
  }

  func testLinksKeepTheGivenOrderAndSurviveRelaunch() throws {
    let store = TaskStore()
    let links = [
      try link(.pr, "o/n", 214), try link(.issue, "o/n", 221), try link(.issue, "x/y", 5),
    ]

    let task = try store.add(draft("a") { $0.links = links })

    XCTAssertEqual(task.links, links, "渡した順のまま持つ（先頭が主）")
    XCTAssertEqual(relaunched().tasks.first?.links, links, "再起動しても順ごと残る")
  }

  /// 項目の同一性はリポジトリ（大小文字を問わない）と番号で、種別は問わない。
  func testAnItemLinkedToAnotherTaskIsRejectedWhateverItsKindOrCase() throws {
    let store = TaskStore()
    let linked = try link(.issue, "o/n", 221)
    let sameItemAsPR = try link(.pr, "O/N", 221)
    let unrelated = try link(.issue, "x/y", 1)
    let owner = try store.add(draft("owner") { $0.links = [linked] })
    let other = try store.add(draft("other"))

    assertInvalid(mentioning: "task \(owner.id)") {
      _ = try store.add(draft("b") { $0.links = [sameItemAsPR] })
    }
    assertInvalid(mentioning: "task \(owner.id)") {
      _ = try store.update(other.id, linksUpdate([unrelated, linked]))
    }

    XCTAssertEqual(store.tasks.map(\.title), ["owner", "other"], "拒否した追加は一覧に残らない")
    XCTAssertEqual(store.tasks.last?.links, [], "拒否した変更は結び付きを変えない")
    XCTAssertEqual(relaunched().tasks, store.tasks)
  }

  func testTheSameItemTwiceInOneTaskIsRejected() throws {
    let store = TaskStore()
    let task = try store.add(draft("a"))
    let issue = try link(.issue, "o/n", 1)
    let sameItemAsPR = try link(.pr, "o/N", 1)

    assertInvalid { _ = try store.add(draft("b") { $0.links = [issue, sameItemAsPR] }) }
    assertInvalid { _ = try store.update(task.id, linksUpdate([issue, issue])) }

    XCTAssertEqual(store.tasks, [task])
  }

  /// 変更は丸ごと置き換える。自分が既に持つ項目は衝突にならず、`[]` で全部外れる。
  func testUpdateReplacesTheLinksAndAnEmptyListUnlinksAll() throws {
    let store = TaskStore()
    let kept = try link(.issue, "o/n", 221)
    let dropped = try link(.pr, "o/n", 214)
    let added = try link(.pr, "o/n", 5)
    let task = try store.add(draft("a") { $0.links = [kept, dropped] })

    XCTAssertEqual(try store.update(task.id, linksUpdate([added, kept])).links, [added, kept])

    XCTAssertEqual(try store.update(task.id, linksUpdate([])).links, [])
    XCTAssertEqual(relaunched().tasks.first?.links, [])
  }

  /// 付け替えは「外す → 付ける」の 2 回。タスクを消しても、その項目は別のタスクに付けられるようになる。
  func testAnItemFreedByUnlinkingOrDeletingCanBeLinkedToAnotherTask() throws {
    let store = TaskStore()
    let item = try link(.issue, "o/n", 221)
    let first = try store.add(draft("first") { $0.links = [item] })
    let second = try store.add(draft("second"))

    _ = try store.update(first.id, linksUpdate([]))
    XCTAssertEqual(try store.update(second.id, linksUpdate([item])).links, [item])

    try store.delete(second.id)
    XCTAssertEqual(try store.add(draft("third") { $0.links = [item] }).links, [item])
  }
}
