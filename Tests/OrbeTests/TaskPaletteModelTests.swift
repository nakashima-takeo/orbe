import XCTest

@testable import Orbe

/// タスク画面（⌘⇧X）のモデル `TaskPaletteModel` が、本物の `TaskStore` を読み書きしながら、選択・範囲・
/// タブ・追加・完了・削除・並べ替えと、agent の変更への付け直しを正しく扱うことを固定する。
///
/// 壊れると何が起きるか: space や ⌘⌫ が、光っている行とは別のタスクを完了・削除する（agent が上に行を
/// 足した直後や、完了の欄を開いているとき）。足したタスクが別の workspace に付く、または選ばれず見失う。
/// ⌥↑↓ が見えていないタスクを飛び越えて並びを崩す。詳細に居る間に agent がそのタスクを消すと、消えた
/// タスクの詳細と下書きが残る。
///
/// 列の変化はカードの `.onChange(of: store.tasks)` が `reconcile()` へ届けるので、agent の変更はストアを
/// 直接変えてから `reconcile()` を呼んで再現する。
@MainActor
final class TaskPaletteModelTests: OrbeTestCase {
  let openedWorkspace = TaskPaletteWorkspaces.Entry(id: UUID(), name: "orbe")
  let otherWorkspace = TaskPaletteWorkspaces.Entry(id: UUID(), name: "web-app")

  func task(
    _ id: Int, _ title: String, _ status: TaskItem.Status = .todo,
    _ mutate: (inout TaskItem) -> Void = { _ in }
  ) -> TaskItem {
    var item = TaskItem(
      id: id, title: title, status: status, waiting: nil, priority: .medium, due: nil,
      workspace: nil, memo: "", createdAt: DesignSceneFixtures.taskToday, createdBy: nil)
    mutate(&item)
    return item
  }

  func model(_ tasks: [TaskItem]) -> TaskPaletteModel {
    let file = TasksFile(
      version: TaskPersistence.version, nextId: (tasks.map(\.id).max() ?? 0) + 1, tasks: tasks)
    return TaskPaletteModel(
      store: TaskStore(file: file),
      workspaces: TaskPaletteWorkspaces(
        opened: openedWorkspace, all: [openedWorkspace, otherWorkspace]),
      now: DesignSceneFixtures.taskToday, calendar: DesignSceneFixtures.taskCalendar)
  }

  /// 未着手 3 件（a・b・c）。
  func threeTodos() -> TaskPaletteModel {
    model([task(1, "a"), task(2, "b"), task(3, "c")])
  }

  func storedTask(_ palette: TaskPaletteModel, _ id: Int) throws -> TaskItem {
    try XCTUnwrap(palette.store.tasks.first { $0.id == id })
  }

  // MARK: - 開いたとき・入力

  func testOpeningSelectsTheFirstRowInAllScopeOnTheTasksTabWithDoneCollapsed() {
    let palette = model([task(1, "a", .done), task(2, "b", .inProgress), task(3, "c")])

    XCTAssertEqual(palette.selectedID, .task(2), "先頭の行（進行中の欄の先頭）")
    XCTAssertEqual(palette.scope, .all)
    XCTAssertEqual(palette.tab, .tasks)
    XCTAssertFalse(palette.doneExpanded)
    XCTAssertEqual(palette.area, .list)
  }

  func testTypingSelectsTheAddRowAndClearingTheQuerySelectsTheFirstRow() {
    let palette = threeTodos()
    palette.move(1)

    palette.query = "b"
    XCTAssertEqual(palette.selectedID, .add)

    palette.query = ""
    XCTAssertEqual(palette.selectedID, .task(1))
  }

  func testEnterOnTheAddRowAppendsATodoTaskOnTheOpenedWorkspaceClearsTheQueryAndSelectsIt() throws {
    let palette = model([task(1, "a") { $0.workspace = self.otherWorkspace.id }])
    palette.query = "  PR の説明を書く "

    palette.submit()

    let added = try XCTUnwrap(palette.store.tasks.last)
    XCTAssertEqual(palette.store.tasks.map(\.id), [1, added.id], "列の末尾に足す")
    XCTAssertEqual(added.title, "PR の説明を書く")
    XCTAssertEqual(added.status, .todo)
    XCTAssertEqual(added.workspace, openedWorkspace.id, "開いた workspace に付く")
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.selectedID, .task(added.id))
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

  func testCompletingMovesTheSelectionToTheRowAtTheSamePositionEvenWhenDoneIsExpanded() throws {
    let palette = model([task(1, "a"), task(2, "b"), task(3, "c"), task(9, "z", .done)])
    palette.toggleDoneExpanded()
    palette.move(1)
    XCTAssertEqual(palette.selectedID, .task(2), "前提")

    palette.submit()

    XCTAssertEqual(try storedTask(palette, 2).status, .done)
    XCTAssertEqual(palette.selectedID, .task(3), "完了の欄へ追わず、同じ位置に来た行を選ぶ")
  }

  func testReopeningADoneTaskAlwaysReturnsItToTodo() throws {
    let palette = model([task(1, "a", .inProgress)])
    palette.toggleDone(1)
    XCTAssertEqual(try storedTask(palette, 1).status, .done, "前提")

    palette.toggleDone(1)

    XCTAssertEqual(try storedTask(palette, 1).status, .todo, "完了前の進行中には戻さない")
  }

  func testEnterOnTheDoneHeaderTogglesTheDoneSection() {
    let palette = model([task(1, "a"), task(2, "b", .done)])
    palette.move(1)
    XCTAssertEqual(palette.selectedID, .doneHeader, "前提")

    palette.submit()
    XCTAssertTrue(palette.rows.contains { $0.selectableID == .task(2) })

    palette.submit()
    XCTAssertFalse(palette.rows.contains { $0.selectableID == .task(2) })
  }

  func testDeletingRemovesTheTaskAndSelectsTheRowAtTheSamePosition() {
    let palette = threeTodos()
    palette.move(1)

    palette.delete(2)

    XCTAssertEqual(palette.store.tasks.map(\.id), [1, 3])
    XCTAssertEqual(palette.selectedID, .task(3))
  }

  func testDeletingTheLastRowSelectsTheNewLastRow() {
    let palette = threeTodos()
    palette.jump(1)

    palette.delete(3)

    XCTAssertEqual(palette.selectedID, .task(2))
  }

  // MARK: - 並べ替え

  func testReorderSwapsWithTheVisibleNeighbourInTheSameSectionAndPersists() {
    let palette = model([
      task(1, "PR を書く"), task(2, "経費精算"), task(3, "PR を直す"), task(4, "進行中", .inProgress),
    ])
    palette.query = "PR"
    palette.move(2)
    XCTAssertEqual(palette.selectedID, .task(3), "前提: 絞り込んだ未着手の 2 件目")

    palette.reorder(-1)

    XCTAssertEqual(palette.store.tasks.map(\.id), [3, 1, 2, 4], "見えていない 2 を飛ばして 1 の前へ")
    XCTAssertEqual(palette.selectedID, .task(3), "動かしたタスクを選んだまま")
    XCTAssertEqual(TaskStore().tasks.map(\.id), [3, 1, 2, 4], "並びは保存される")
  }

  func testReorderDoesNothingAtTheSectionEdgeOrOnADoneTask() {
    let palette = model([task(1, "進行中", .inProgress), task(2, "a"), task(3, "z", .done)])
    palette.move(1)
    XCTAssertEqual(palette.selectedID, .task(2), "前提: 未着手の欄の先頭")

    palette.reorder(-1)
    XCTAssertEqual(palette.store.tasks.map(\.id), [1, 2, 3], "欄の端では進行中の欄へ越えない")

    palette.toggleDoneExpanded()
    palette.jump(1)
    XCTAssertEqual(palette.selectedID, .task(3), "前提: 完了のタスク")
    palette.reorder(-1)
    XCTAssertEqual(palette.store.tasks.map(\.id), [1, 2, 3], "完了のタスクは並べ替えない")
  }

  // MARK: - 範囲とタブ

  func testSwitchingScopeKeepsAStillVisibleSelectionOrMovesToTheSamePosition() {
    let palette = model([
      task(1, "a") { $0.workspace = self.openedWorkspace.id }, task(2, "b"),
      task(3, "c") { $0.workspace = self.openedWorkspace.id },
    ])
    palette.jump(1)

    palette.toggleScope()
    XCTAssertEqual(palette.scope, .opened)
    XCTAssertEqual(palette.selectedID, .task(3), "見えたままなら同じタスク")

    palette.toggleScope()
    palette.move(-1)
    XCTAssertEqual(palette.selectedID, .task(2), "前提")
    palette.toggleScope()
    XCTAssertEqual(palette.selectedID, .task(3), "見えなくなったら同じ位置の行")
  }

  func testGitHubTabHasNoRowsAndEnterDoesNothing() throws {
    let palette = threeTodos()

    palette.toggleTab()
    palette.submit()

    XCTAssertEqual(palette.tab, .github)
    XCTAssertEqual(palette.rows, [])
    XCTAssertEqual(try storedTask(palette, 1).status, .todo)
  }

  // MARK: - agent の変更への追従

  func testAgentInsertingAboveKeepsTheSelectedTask() throws {
    let palette = threeTodos()
    palette.move(1)

    let inserted = try palette.store.add(TaskDraft(title: "agent が足した"))
    try palette.store.move(inserted.id, .before, 1)
    palette.reconcile()

    XCTAssertEqual(palette.selectedID, .task(2), "位置ではなく同じタスクを選んだまま")
  }

  func testSelectedTaskDeletedByAgentMovesTheSelectionToTheSamePosition() throws {
    let palette = threeTodos()
    palette.move(1)

    try palette.store.delete(2)
    palette.reconcile()

    XCTAssertEqual(palette.selectedID, .task(3))
  }

  /// 付け直しより先に space が届いても、消えたタスクのエラーは出さずに同じ位置の行へ移る。
  func testCompletingATaskAlreadyDeletedByAgentShowsNoErrorAndMovesOn() throws {
    let palette = threeTodos()
    palette.move(1)
    try palette.store.delete(2)

    palette.toggleDone(2)

    XCTAssertNil(palette.error)
    XCTAssertEqual(palette.selectedID, .task(3))
    XCTAssertEqual(try storedTask(palette, 3).status, .todo, "別のタスクは完了にならない")
  }

  // MARK: - ホバー

  func testHoverFollowsOnlyAfterRealPointerMovementAndKeysTakeTheSelectionBack() {
    let palette = threeTodos()

    palette.hoverSelect(.task(3))
    XCTAssertEqual(palette.selectedID, .task(1), "キーボード操作中はカーソル下を横切っても奪わない")

    palette.inputModality = .pointer
    palette.hoverSelect(.task(3))
    XCTAssertEqual(palette.selectedID, .task(3))

    palette.move(-1)
    palette.hoverSelect(.task(1))
    XCTAssertEqual(palette.selectedID, .task(2), "キーで動かしたらホバーは再び実マウス移動まで効かない")
  }
}
