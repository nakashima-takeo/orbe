import XCTest

@testable import Orbe

/// 一覧を見える所まで送る先（`scrollTarget`）。一覧は送り先の変化を受けて、その行まで最小の量だけ送る。
///
/// 壊れると何が起きるか: ⌥↑↓ やドラッグで動かしたタスク・↑↓ で選んだ行が一覧の見えている範囲の外へ出て
/// 見失う。同じタスクで ⌥↑↓ を続けて押すと 2 回目から送られない。逆に、人が流して読んでいる一覧が、
/// agent が上の欄を変えただけで選んだ行へ引き戻される。
extension TaskPaletteModelTests {
  func scrollSerial(_ palette: TaskPaletteModel) -> Int { palette.scrollTarget?.serial ?? 0 }

  func testChangingTheSelectedRowSendsTheListToIt() {
    let palette = threeTodos()
    let before = scrollSerial(palette)

    palette.move(1)

    XCTAssertEqual(palette.scrollTarget?.id, .task(2))
    XCTAssertGreaterThan(scrollSerial(palette), before)
  }

  func testReorderPressedAgainOnTheSameTaskSendsTheListAgain() {
    let palette = threeTodos()
    palette.jump(1)
    palette.reorder(-1)
    let first = scrollSerial(palette)

    palette.reorder(-1)

    XCTAssertEqual(palette.store.tasks.map(\.id), [3, 1, 2], "前提: 続けて動いた")
    XCTAssertEqual(palette.scrollTarget?.id, .task(3))
    XCTAssertGreaterThan(scrollSerial(palette), first, "同じ行でも送り直す")
  }

  func testReleasingADragSendsTheListToTheMovedTask() {
    let palette = threeTodos()
    palette.dragChanged(1, start: grabPoint, translation: 2 * rowHeight)
    let grabbed = scrollSerial(palette)

    palette.dragEnded()

    XCTAssertEqual(palette.store.tasks.map(\.id), [2, 3, 1], "前提: 離した位置へ動いた")
    XCTAssertEqual(palette.scrollTarget?.id, .task(1))
    XCTAssertGreaterThan(scrollSerial(palette), grabbed)
  }

  /// 付け直しは選んだタスクを保つが、その一覧の中の位置がずれても送り先は決め直さない。
  func testAgentChangeReconciledAloneDoesNotSendTheList() throws {
    let palette = threeTodos()
    palette.move(1)
    let target = palette.scrollTarget

    let inserted = try palette.store.add(TaskDraft(title: "agent が足した"))
    try palette.store.move(inserted.id, .before, 1)
    palette.reconcile()

    XCTAssertEqual(palette.selectedID, .task(2), "前提: 選んだタスクのまま位置だけがずれた")
    XCTAssertEqual(palette.scrollTarget, target)
  }
}
