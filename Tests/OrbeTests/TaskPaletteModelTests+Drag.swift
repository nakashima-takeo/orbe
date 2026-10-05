import XCTest

@testable import Orbe

/// 一覧の行を掴んで同じ欄の中で並べ替える。View の `DragGesture` が渡すのと同じ `dragChanged` /
/// `dragEnded` を呼び、掴み中の行のずれ・線はモデルの `drag` から、確定は本物のストアの並びから読む。
///
/// 壊れると何が起きるか: 離した場所と別の位置へ落ちる、欄をまたいでステータスが変わる、絞り込み中に
/// 隠れたタスクを飛び越えて並びが崩れる。agent が掴み中に並びを変えたのに古い並びで確定し、agent の
/// 並べ替えを潰す。捨てた掴みの続きや、終わりの届かなかった前の掴みが、次の操作で勝手に確定する。
/// 掴んだ行が欄の外へはみ出して描かれ、線が落ちる位置と違う行の縁に出る。
extension TaskPaletteModelTests {
  var rowHeight: CGFloat { TaskPaletteRowMetrics.line }
  var grabPoint: CGPoint { CGPoint(x: 120, y: 80) }
  var nextGrabPoint: CGPoint { CGPoint(x: 120, y: 160) }

  func order(_ palette: TaskPaletteModel) -> [Int] { palette.store.tasks.map(\.id) }

  /// 掴んで `rows` 行ぶん（下が正）動かし、離す。
  func drop(_ palette: TaskPaletteModel, _ id: Int, by rows: CGFloat) {
    palette.dragChanged(id, start: grabPoint, translation: rows * rowHeight)
    palette.dragEnded()
  }

  // MARK: - 掴む・離す

  func testGrabbingSelectsTheRowAndReleasingMovesItThereOnceAndPersists() {
    let palette = threeTodos()

    palette.dragChanged(3, start: grabPoint, translation: -2 * rowHeight)
    XCTAssertEqual(palette.selectedID, .task(3), "掴んだ行が選ばれる")
    XCTAssertEqual(order(palette), [1, 2, 3], "掴み中はストアを変えない")
    XCTAssertNil(TaskPersistence.load(), "掴み中は保存しない")

    palette.dragEnded()

    XCTAssertEqual(order(palette), [3, 1, 2])
    XCTAssertEqual(palette.selectedID, .task(3), "動かしたタスクを選んだまま")
    XCTAssertEqual(TaskStore().tasks.map(\.id), [3, 1, 2], "並びは保存される")
  }

  func testReleasingAtTheOriginalPositionChangesAndSavesNothing() {
    let palette = threeTodos()

    drop(palette, 2, by: 0.4)

    XCTAssertEqual(order(palette), [1, 2, 3])
    XCTAssertNil(palette.error, "失敗も出さない")
    XCTAssertNil(TaskPersistence.load(), "保存も起きない")
  }

  /// 落ちる位置は、動かした距離に最も近い行。欄の端より外へ引いても欄の端に落ち、隣の欄へは越えない。
  func testDropLandsOnTheNearestRowAndStopsAtTheSectionEdge() throws {
    let tasks = [
      task(1, "進行中 1", .inProgress), task(2, "進行中 2", .inProgress), task(3, "a"), task(4, "b"),
      task(5, "c"),
    ]
    let nearest = model(tasks)
    drop(nearest, 3, by: 0.6)
    XCTAssertEqual(order(nearest), [1, 2, 4, 3, 5], "半分を越えたら隣の行の位置")

    let edge = model(tasks)
    drop(edge, 5, by: -10)
    XCTAssertEqual(order(edge), [1, 2, 5, 3, 4], "未着手の欄の先頭で止まる")
    XCTAssertEqual(try storedTask(edge, 5).status, .todo, "ステータスは変わらない")
  }

  func testDoneTasksCannotBeGrabbed() {
    let palette = model([task(1, "a"), task(2, "b"), task(9, "z", .done)])
    palette.toggleDoneExpanded()

    drop(palette, 9, by: -2)

    XCTAssertEqual(order(palette), [1, 2, 9])
    XCTAssertEqual(palette.selectedID, .task(1), "掴めない行は選びもしない")
  }

  /// 掴み中のポインタの動きでは、ほかの行の上を通ってもホバーで選択が動かない。
  func testHoverDoesNotMoveTheSelectionWhileGrabbing() {
    let palette = threeTodos()
    palette.inputModality = .pointer

    palette.dragChanged(1, start: grabPoint, translation: 2 * rowHeight)
    palette.hoverSelect(.task(3))

    XCTAssertEqual(palette.selectedID, .task(1))
  }

  func testGrabbingWhileEditingCommitsTheEditAndReturnsToTheList() throws {
    let palette = detailOfFirst()
    edit(palette, .description, "掴む前に書いた")

    palette.dragChanged(2, start: grabPoint, translation: -rowHeight)

    XCTAssertEqual(try storedTask(palette, 1).description, "掴む前に書いた", "編集していたタスクへ書く")
    XCTAssertNil(palette.draft)
    XCTAssertEqual(palette.area, .list)
    XCTAssertEqual(palette.selectedID, .task(2))
  }

  // MARK: - 掴み中の見た目

  /// 掴んだ行は指に付いて動き、欄の先頭の行の上端から末尾の行の下端までに収まる。
  func testGrabbedRowFollowsThePointerWithinItsSection() throws {
    let palette = threeTodos()

    palette.dragChanged(2, start: grabPoint, translation: 0.3 * rowHeight)
    XCTAssertEqual(try XCTUnwrap(palette.drag.session).offset, 0.3 * rowHeight)

    palette.dragChanged(2, start: grabPoint, translation: 5 * rowHeight)
    XCTAssertEqual(try XCTUnwrap(palette.drag.session).offset, rowHeight, "末尾の行の位置で止まる")

    palette.dragChanged(2, start: grabPoint, translation: -5 * rowHeight)
    XCTAssertEqual(try XCTUnwrap(palette.drag.session).offset, -rowHeight, "先頭の行の位置で止まる")
  }

  /// 線は、下へ落ちるなら落ちる行の下端、上へなら上端に出る（掴んだ行の元の上端から測る）。元の位置に
  /// 落ちるなら出ない。
  func testDropLineMarksTheEdgeOfTheRowItLandsOn() throws {
    let palette = threeTodos()

    palette.dragChanged(2, start: grabPoint, translation: 0.3 * rowHeight)
    XCTAssertNil(try XCTUnwrap(palette.drag.session).indicatorY, "元の位置")

    palette.dragChanged(2, start: grabPoint, translation: 0.6 * rowHeight)
    XCTAssertEqual(try XCTUnwrap(palette.drag.session).indicatorY, 2 * rowHeight, "c の下端")

    palette.dragChanged(2, start: grabPoint, translation: -0.6 * rowHeight)
    XCTAssertEqual(try XCTUnwrap(palette.drag.session).indicatorY, -rowHeight, "a の上端")
  }

  // MARK: - 絞り込み中（⌥↑↓ と同じ落とし先）

  /// 見えている兄弟の中で動かし、間に隠れたタスクは越えない。⌥↑↓ を同じ回数押したのと同じ並びになる。
  func testDropWhileFilteredLandsWhereTheSameNumberOfReorderPressesWould() {
    let tasks = [
      task(1, "PR を書く"), task(2, "経費精算"), task(3, "PR を直す"), task(4, "PR を出す"),
      task(5, "進行中", .inProgress),
    ]
    func filtered() -> TaskPaletteModel {
      let palette = model(tasks)
      palette.query = "PR"
      return palette
    }
    func pressed(_ id: Int, _ direction: Int) -> [Int] {
      let palette = filtered()
      palette.tapRow(.task(id))
      palette.reorder(direction)
      palette.reorder(direction)
      return order(palette)
    }

    let down = filtered()
    drop(down, 1, by: 2)
    XCTAssertEqual(order(down), [2, 3, 4, 1, 5], "下へは直上の見えている行（4）の直後")
    XCTAssertEqual(order(down), pressed(1, 1))

    let up = filtered()
    drop(up, 4, by: -2)
    XCTAssertEqual(order(up), [4, 1, 2, 3, 5], "上へは直下の見えている行（1）の直前")
    XCTAssertEqual(order(up), pressed(4, -1))
  }

  // MARK: - 掴み中の並びの変化

  func testAgentChangingTheGrabbedSectionDiscardsTheGrabAndReleaseDoesNothing() throws {
    let palette = threeTodos()
    palette.dragChanged(3, start: grabPoint, translation: -2 * rowHeight)

    let added = try palette.store.add(TaskDraft(title: "agent が足した"))
    palette.reconcile()
    XCTAssertNil(palette.drag.session, "掴んだ行は元に戻る")

    palette.dragEnded()
    XCTAssertEqual(order(palette), [1, 2, 3, added.id])
  }

  /// 兄弟の並びが同じでも、上の欄の増減で掴んだ行の一覧の中の位置がずれたら捨てる。
  func testRowsAddedAboveTheGrabbedSectionDiscardTheGrab() throws {
    let palette = threeTodos()
    palette.dragChanged(3, start: grabPoint, translation: -2 * rowHeight)

    let added = try palette.store.add(TaskDraft(title: "agent が進行中に足した"))
    var update = TaskUpdate()
    update.status = .inProgress
    _ = try palette.store.update(added.id, update)
    palette.reconcile()
    XCTAssertNil(palette.drag.session)

    palette.dragEnded()
    XCTAssertEqual(order(palette), [1, 2, 3, added.id])
  }

  /// 入力で追加の行が出て、掴んだ行の位置がずれたら捨てる。
  func testTypingWhileGrabbingDiscardsTheGrab() {
    let palette = model([task(1, "PR a"), task(2, "PR b"), task(3, "PR c")])
    palette.dragChanged(3, start: grabPoint, translation: -2 * rowHeight)

    palette.query = "PR"
    XCTAssertNil(palette.drag.session)

    palette.dragEnded()
    XCTAssertEqual(order(palette), [1, 2, 3])
  }

  func testChangesOutsideTheGrabbedSectionKeepTheGrab() throws {
    let palette = model([
      task(1, "進行中 1", .inProgress) { $0.description = "人が書いた" },
      task(2, "進行中 2", .inProgress),
    ])
    palette.dragChanged(
      2, start: grabPoint, translation: -TaskPaletteRowMetrics.taskWithDescription)

    let added = try palette.store.add(TaskDraft(title: "agent が未着手に足した"))
    var update = TaskUpdate()
    update.description = "agent が兄弟の詳細を書き換えた"
    _ = try palette.store.update(1, update)
    palette.reconcile()
    XCTAssertNotNil(palette.drag.session, "下の欄の変化と、空かどうかが変わらない兄弟の詳細では捨てない")

    palette.dragEnded()
    XCTAssertEqual(order(palette), [2, 1, added.id])
  }

  /// 付け直しより先に離すイベントが届いても、離した時点の並びを確かめて、古い並びで確定しない。
  func testReleaseArrivingBeforeTheAgentChangeIsReconciledDoesNotCommitTheStaleOrder() throws {
    let palette = threeTodos()
    palette.dragChanged(3, start: grabPoint, translation: -2 * rowHeight)

    try palette.store.move(1, .after, 2)
    palette.dragEnded()

    XCTAssertEqual(order(palette), [2, 1, 3], "agent の並べ替えのまま")
  }

  /// 捨てた掴みの続きは無視し（指を離すまで掴み直さない）、次の掴みは普通に効く。
  func testMovesOfADiscardedGrabAreIgnoredAndTheNextGrabWorks() throws {
    let palette = threeTodos()
    palette.dragChanged(3, start: grabPoint, translation: -rowHeight)
    let added = try palette.store.add(TaskDraft(title: "agent が足した"))
    palette.reconcile()

    palette.dragChanged(3, start: grabPoint, translation: -2 * rowHeight)
    XCTAssertNil(palette.drag.session, "同じ掴みの続き")
    palette.dragEnded()
    XCTAssertEqual(order(palette), [1, 2, 3, added.id])

    palette.dragChanged(3, start: nextGrabPoint, translation: -2 * rowHeight)
    palette.dragEnded()
    XCTAssertEqual(order(palette), [3, 1, 2, added.id])
  }

  /// 前の掴みの終わりが届かないまま次の掴みが始まっても、前の掴みは確定しない。
  func testANewGrabBeforeThePreviousOneEndedDoesNotCommitThePrevious() {
    let palette = threeTodos()
    palette.dragChanged(1, start: grabPoint, translation: 2 * rowHeight)

    palette.dragChanged(2, start: nextGrabPoint, translation: 0.2 * rowHeight)
    palette.dragEnded()

    XCTAssertEqual(order(palette), [1, 2, 3])
    XCTAssertEqual(palette.selectedID, .task(2))
  }
}
