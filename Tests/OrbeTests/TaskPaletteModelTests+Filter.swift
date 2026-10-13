import XCTest

@testable import Orbe

/// 絞り込み・並び・絞り込みのメニューと、絞り込みから外れた行をリストの更新まで暗く残す規則。
extension TaskPaletteModelTests {
  private func rowIDs(_ palette: TaskPaletteModel) -> [TaskPaletteRowID] {
    palette.rows.compactMap(\.selectableID)
  }

  /// `id` を右の欄で完了まで巡らせ、絞り込みに合わない暗い行として選んだまま一覧へ戻る。
  private func completeInDetail(_ palette: TaskPaletteModel, _ id: Int) throws {
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

  /// 状態で並べていても、完了にした行は次のリストの更新まで並べ直さず、同じ場所に残る（最下段へ動かない）。
  func testCompletingInATableSortedByStateKeepsTheRowInPlace() throws {
    let palette = model([task(1, "a", .inProgress), task(2, "b"), task(3, "c")])
    palette.setSort(.state)
    XCTAssertEqual(rowIDs(palette), [.task(1), .task(3), .task(2)], "前提: 進行中が先")
    palette.tapRow(.task(1))

    palette.submit()

    XCTAssertEqual(try storedTask(palette, 1).status, .done)
    XCTAssertEqual(rowIDs(palette), [.task(1), .task(3), .task(2)])
  }

  /// 列の見出しで組み直して、選んでいた暗い行が消えたら、同じ位置の行ではなく先頭の行を選ぶ。
  func testSortingAfterTheSelectedRowWasDimmedSelectsTheFirstRow() {
    let palette = threeTodos()
    palette.move(1)
    palette.submit()
    XCTAssertEqual(palette.selectedID, .task(2), "前提: 完了にした行を選んだまま")

    palette.setSort(.title)

    XCTAssertEqual(rowIDs(palette), [.task(1), .task(3)], "暗い行は消える")
    XCTAssertEqual(palette.selectedID, .task(1))
  }

  // MARK: - 絞り込み

  /// 選んでいたのが暗い行でも、絞り込みを変えたら組み直して暗い行を消し、合う行の先頭を選ぶ。
  func testChangingTheFilterRebuildsWithoutTheDimmedRowAndSelectsTheFirstMatchingRow() throws {
    let palette = threeTodos()
    try completeInDetail(palette, 3)

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

  // MARK: - 暗い行

  /// 暗い行を ↓ で離れても行は消えないので、直後の space は離れた先の行に効く。
  func testCompletingRightAfterLeavingADimmedRowActsOnTheRowMovedTo() throws {
    let palette = model([
      task(1, "a"), task(2, "b"), task(3, "c"), task(4, "d"), task(5, "e"),
    ])
    try completeInDetail(palette, 4)
    palette.move(1)
    XCTAssertEqual(palette.selectedID, .task(3), "前提")
    XCTAssertEqual(
      rowIDs(palette), [.task(5), .task(4), .task(3), .task(2), .task(1)], "前提: 離れた暗い行も残る")

    palette.submit()

    XCTAssertEqual(try storedTask(palette, 3).status, .done)
    XCTAssertEqual(palette.selectedID, .task(3))
  }

  func testHoverMovesTheSelectionWhileADimmedRowIsShown() throws {
    let palette = threeTodos()
    try completeInDetail(palette, 2)
    palette.inputModality = .pointer

    palette.hoverSelect(.task(1))

    XCTAssertEqual(palette.selectedID, .task(1))
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
