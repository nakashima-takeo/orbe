import XCTest

@testable import Orbe

/// 絞り込み・並び・絞り込みのメニューと、選んでいるタスクを絞り込みに合わなくても表に残す規則。
extension TaskPaletteModelTests {
  private func rowIDs(_ palette: TaskPaletteModel) -> [TaskPaletteRowID] {
    palette.rows.compactMap(\.selectableID)
  }

  /// `id` を右の欄で完了まで巡らせ、絞り込みに合わないまま選んで表に残した状態で一覧へ戻る。
  private func keepDone(_ palette: TaskPaletteModel, _ id: Int) throws {
    palette.tapRow(.task(id))
    palette.enterDetail()
    palette.changeValue(1)
    palette.changeValue(1)
    palette.leaveDetail()
    XCTAssertEqual(try storedTask(palette, id).status, .done, "前提")
    XCTAssertEqual(palette.selectedID, .task(id), "前提: 選んだまま")
    XCTAssertTrue(rowIDs(palette).contains(.task(id)), "前提: 完了でも表に残る")
  }

  // MARK: - 並び

  func testTappingAColumnHeaderSortsByItReversesOnTheSecondTapAndKeepsTheSelection() {
    let palette = model([
      task(1, "a") { $0.priority = .high }, task(2, "c") { $0.priority = .low },
      task(3, "b"),
    ])
    palette.tapRow(.task(2))

    palette.setSort(.priority)
    XCTAssertEqual(rowIDs(palette), [.task(1), .task(3), .task(2)], "高 → 低")

    palette.setSort(.priority)
    XCTAssertEqual(rowIDs(palette), [.task(2), .task(3), .task(1)], "同じ列は逆になる")

    palette.setSort(.title)
    XCTAssertEqual(rowIDs(palette), [.task(1), .task(3), .task(2)], "別の列はその列の既定の向き")
    XCTAssertEqual(palette.selectedID, .task(2), "並びを変えても同じタスクを選んだまま")
  }

  // MARK: - 絞り込み

  /// 先頭の行が残していたタスクでも、絞り込みを変えたら残さず、合う行の先頭を選ぶ。
  func testChangingTheFilterSelectsTheFirstMatchingRowWithoutKeepingTheSelectedTask() throws {
    let palette = threeTodos()
    try keepDone(palette, 3)

    palette.toggleState(.inProgress)

    XCTAssertEqual(rowIDs(palette), [.task(2), .task(1)])
    XCTAssertEqual(palette.selectedID, .task(2))
  }

  func testAddedTaskOutsideTheFilterIsSelectedAndShown() throws {
    let palette = model([task(1, "進行中", .inProgress)])
    palette.toggleState(.todo)
    palette.query = "未着手で足す"

    palette.addFromQuery()

    let added = try XCTUnwrap(palette.store.tasks.first { $0.title == "未着手で足す" }).id
    XCTAssertEqual(palette.selectedID, .task(added))
    XCTAssertTrue(rowIDs(palette).contains(.task(added)))
  }

  // MARK: - 残した行

  /// 残した行を ↓ で離れた直後の操作は、残した行が消えた後の並びで「同じ位置」に当たる。
  func testCompletingRightAfterLeavingAKeptRowMovesToTheRowAtTheSamePosition() throws {
    let palette = model([
      task(1, "a"), task(2, "b"), task(3, "c"), task(4, "d"), task(5, "e"),
    ])
    try keepDone(palette, 4)
    palette.move(1)
    XCTAssertEqual(palette.selectedID, .task(3), "前提")
    XCTAssertEqual(rowIDs(palette), [.task(5), .task(3), .task(2), .task(1)], "前提: 離れた行は消える")

    palette.submit()

    XCTAssertEqual(try storedTask(palette, 3).status, .done)
    XCTAssertEqual(palette.selectedID, .task(2))
  }

  func testHoverDoesNotMoveTheSelectionWhileAKeptRowIsShown() throws {
    let palette = threeTodos()
    try keepDone(palette, 2)
    palette.inputModality = .pointer

    palette.hoverSelect(.task(1))

    XCTAssertEqual(palette.selectedID, .task(2))
  }

  // MARK: - 絞り込みのメニュー

  func testTogglingValuesKeepsTheFilterMenuOpenAndEnteringTheDetailClosesIt() {
    let palette = threeTodos()
    palette.toggleFilterMenu(.priority)

    palette.togglePriorityFilter(.medium)
    palette.togglePriorityFilter(.high)
    XCTAssertEqual(palette.openFilterMenu, .priority, "続けて複数の値をオンにできる")

    palette.enterDetail()
    XCTAssertNil(palette.openFilterMenu)
  }
}
