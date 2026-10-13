import XCTest

@testable import Orbe

/// タスク画面（⌘⇧X）のモデル `TaskPaletteModel` が、本物の `TaskStore` を読み書きしながら、選択・絞り込み・
/// タブ・追加・完了・削除と、agent の変更への付け直しを正しく扱うことを固定する。
///
/// 壊れると何が起きるか: space や ⌘⌫ が、光っている行とは別のタスクを完了・削除する（agent が上に行を
/// 足した直後など）。足したタスクが別の workspace に付く、または選ばれず見失う。
/// 右の欄に居る間に agent がそのタスクを消すと、消えたタスクの右の欄と下書きが残る。絞り込みを変えたのに外した
/// はずの行が残る、または完了にした行がその場で消えて、次の space が別のタスクに当たる。
///
/// タスク一覧の変化はカードの `.onChange(of: store.tasks)` が `reconcile()` へ届けるので、agent の変更はストアを
/// 直接変えてから `reconcile()` を呼んで再現する。
@MainActor
final class TaskPaletteModelTests: OrbeTestCase {
  let openedWorkspace = TaskPaletteSamples.opened
  let otherWorkspace = TaskPaletteSamples.other

  func task(
    _ id: Int, _ title: String, _ status: TaskItem.Status = .todo,
    _ mutate: (inout TaskItem) -> Void = { _ in }
  ) -> TaskItem {
    TaskPaletteSamples.task(id, title, status, mutate)
  }

  func model(_ tasks: [TaskItem]) -> TaskPaletteModel { TaskPaletteSamples.model(tasks) }

  func threeTodos() -> TaskPaletteModel { TaskPaletteSamples.threeTodos() }

  func storedTask(_ palette: TaskPaletteModel, _ id: Int) throws -> TaskItem {
    try XCTUnwrap(palette.store.tasks.first { $0.id == id })
  }

  // MARK: - 開いたとき・入力

  func testOpeningSelectsTheFirstRowOnTheTasksTabWithDoneFilteredOut() {
    let palette = model([task(1, "a", .done), task(2, "b", .inProgress), task(4, "d", .done)])

    XCTAssertEqual(palette.selectedID, .task(2), "先頭の行（完了は既定の絞り込みで出ない）")
    XCTAssertEqual(palette.filter, TaskPaletteFilter())
    XCTAssertEqual(palette.sort, TaskPaletteSort())
    XCTAssertEqual(palette.tab, .tasks)
    XCTAssertEqual(palette.area, .list)
  }

  func testTypingSelectsTheAddRowAndClearingTheQuerySelectsTheFirstRow() {
    let palette = threeTodos()
    palette.move(1)

    palette.query = "b"
    XCTAssertEqual(palette.selectedID, .add)

    palette.query = ""
    XCTAssertEqual(palette.selectedID, .task(3))
  }

  /// 足したタスクは「今足した」の印で選ばれる。
  func testEnterOnTheAddRowAddsATodoTaskClearsTheQueryAndMarksIt() throws {
    let palette = model([task(1, "進行中", .inProgress)])
    palette.query = "  PR の説明を書く "

    palette.submit()

    let added = try XCTUnwrap(palette.store.tasks.first { $0.title == "PR の説明を書く" })
    XCTAssertEqual(added.status, .todo)
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.selectedID, .task(added.id))
    XCTAssertEqual(palette.justAdded, added.id, "今足した")
  }

  /// 足すタスクの workspace は絞り込みで決まる——workspace がちょうど 1 つならその workspace、そうでなければなし。
  func testTheAddedTasksWorkspaceFollowsTheWorkspaceFilter() throws {
    let palette = model([])
    palette.query = "絞らずに足す"
    palette.submit()
    palette.toggleWorkspaceFilter(openedWorkspace.id)
    palette.query = "orbe で足す"
    palette.submit()
    palette.toggleWorkspaceFilter(TaskPaletteSamples.other.id)
    palette.query = "2 つで絞って足す"
    palette.submit()

    let byTitle = Dictionary(uniqueKeysWithValues: palette.store.tasks.map { ($0.title, $0) })
    XCTAssertNil(try XCTUnwrap(byTitle["絞らずに足す"]).workspace, "workspace で絞っていなければなし")
    XCTAssertEqual(try XCTUnwrap(byTitle["orbe で足す"]).workspace, openedWorkspace.id)
    XCTAssertNil(try XCTUnwrap(byTitle["2 つで絞って足す"]).workspace, "2 つ以上で絞っていればなし")
  }

  /// 入力に文字があっても、↵ は選ばれている行の操作（↓ で一致したタスクを選べば、そのタスクを完了）。
  func testEnterOnAMatchedTaskRowWhileTypingCompletesThatTask() throws {
    let palette = threeTodos()
    palette.query = "b"
    palette.move(1)

    palette.submit()

    XCTAssertEqual(try storedTask(palette, 2).status, .done)
    XCTAssertEqual(palette.store.tasks.count, 3, "追加はしない")
  }

  // MARK: - 完了・削除

  /// 完了にした行は絞り込みから外れても同じ場所に残り、選択も留まるので、もう一度 space で取り消せる。
  func testCompletingKeepsTheRowInPlaceAndSelectedSoItCanBeUndone() throws {
    let palette = threeTodos()
    palette.move(1)
    XCTAssertEqual(palette.selectedID, .task(2), "前提")

    palette.submit()

    XCTAssertEqual(try storedTask(palette, 2).status, .done)
    XCTAssertEqual(palette.selectedID, .task(2), "完了にしたタスクを選んだまま")
    XCTAssertEqual(
      palette.rows.compactMap(\.selectableID), [.task(3), .task(2), .task(1)], "行は同じ場所")

    palette.submit()

    XCTAssertEqual(try storedTask(palette, 2).status, .todo, "もう一度で取り消せる")
  }

  /// 行のアイコンのクリックで、選んでいない（上の）行を完了にしても、選んでいるタスクは変わらない。
  func testCompletingAnUnselectedRowKeepsTheSelectedTask() throws {
    let palette = threeTodos()
    palette.move(1)

    palette.toggleDone(1)

    XCTAssertEqual(try storedTask(palette, 1).status, .done)
    XCTAssertEqual(palette.selectedID, .task(2), "選んでいた b のまま")
  }

  func testReopeningADoneTaskAlwaysReturnsItToTodo() throws {
    let palette = model([task(1, "a", .inProgress)])
    palette.toggleDone(1)
    XCTAssertEqual(try storedTask(palette, 1).status, .done, "前提")

    palette.toggleDone(1)

    XCTAssertEqual(try storedTask(palette, 1).status, .todo, "完了前の進行中には戻さない")
  }

  func testDeletingRemovesTheTaskAndSelectsTheRowAtTheSamePosition() {
    let palette = threeTodos()
    palette.move(1)

    palette.delete(2)

    XCTAssertEqual(palette.store.tasks.map(\.id), [1, 3])
    XCTAssertEqual(palette.selectedID, .task(1))
  }

  func testDeletingTheLastRowSelectsTheNewLastRow() {
    let palette = threeTodos()
    palette.jump(1)

    palette.delete(1)

    XCTAssertEqual(palette.selectedID, .task(2))
  }

  // MARK: - タブ

  func testGitHubTabWithoutListsHasNoRowsAndEnterDoesNothing() throws {
    let palette = threeTodos()

    palette.setTab(.github)
    palette.submit()

    XCTAssertEqual(palette.tab, .github)
    XCTAssertEqual(palette.gitHubRows, [])
    XCTAssertEqual(try storedTask(palette, 1).status, .todo)
  }

  // MARK: - agent の変更への追従

  func testAgentInsertingAboveKeepsTheSelectedTask() throws {
    let palette = threeTodos()
    palette.move(1)

    _ = try palette.store.add(TaskDraft(title: "agent が足した"))
    palette.reconcile()

    XCTAssertEqual(palette.selectedID, .task(2), "位置ではなく同じタスクを選んだまま")
  }

  /// agent が絞り込みから外したタスクも、次のリストの更新まで同じ場所に残り、暗いのはその行だけ。
  func testTaskTakenOutOfTheFilterByAgentStaysInPlaceAndOnlyItIsDimmed() throws {
    let palette = threeTodos()
    var update = TaskUpdate()
    update.status = .done

    _ = try palette.store.update(2, update)
    palette.reconcile()

    XCTAssertEqual(palette.rows.compactMap(\.selectableID), [.task(3), .task(2), .task(1)])
    let dimmed = palette.rows.compactMap { row -> Int? in
      guard case .task(let task) = row, !task.matches else { return nil }
      return task.id
    }
    XCTAssertEqual(dimmed, [2])
  }

  /// agent が足したタスク・絞り込みに合うようにしたタスクは、並びの規則の位置に入る（既定の並びなら新しい順）。
  func testTasksAgentMakesMatchAreInsertedWhereTheSortPutsThem() throws {
    let palette = model([task(1, "a"), task(2, "b", .done), task(3, "c")])
    var reopen = TaskUpdate()
    reopen.status = .todo

    _ = try palette.store.update(2, reopen)
    let added = try palette.store.add(TaskDraft(title: "agent が足した")).id
    palette.reconcile()

    XCTAssertEqual(
      palette.rows.compactMap(\.selectableID), [.task(added), .task(3), .task(2), .task(1)])
  }

  func testSelectedTaskDeletedByAgentMovesTheSelectionToTheSamePosition() throws {
    let palette = threeTodos()
    palette.move(1)

    try palette.store.delete(2)
    palette.reconcile()

    XCTAssertEqual(palette.selectedID, .task(1))
  }

  /// 付け直しより先に space が届いても、消えたタスクのエラーは出さずに同じ位置の行へ移る。
  func testCompletingATaskAlreadyDeletedByAgentShowsNoErrorAndMovesOn() throws {
    let palette = threeTodos()
    palette.move(1)
    try palette.store.delete(2)

    palette.toggleDone(2)

    XCTAssertNil(palette.error)
    XCTAssertEqual(palette.selectedID, .task(1))
    XCTAssertEqual(try storedTask(palette, 1).status, .todo, "別のタスクは完了にならない")
  }

  // MARK: - ホバー

  func testHoverFollowsOnlyAfterRealPointerMovementAndKeysTakeTheSelectionBack() {
    let palette = threeTodos()

    palette.hoverSelect(.task(1))
    XCTAssertEqual(palette.selectedID, .task(3), "キーボード操作中はカーソル下を横切っても奪わない")

    palette.inputModality = .pointer
    palette.hoverSelect(.task(1))
    XCTAssertEqual(palette.selectedID, .task(1))

    palette.move(-1)
    palette.hoverSelect(.task(3))
    XCTAssertEqual(palette.selectedID, .task(2), "キーで動かしたらホバーは再び実マウス移動まで効かない")
  }
}
