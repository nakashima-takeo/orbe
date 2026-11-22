import SwiftUI
import XCTest

@testable import Orbe

/// worktree パレット（⌘T）の入力欄のキーの入口 `WorktreePaletteFieldKeys.handle` に、キー 1 打の値を直接渡して、一覧の画面と
/// ベースを選ぶ画面の ⇥・⇧⇥・esc が意図した操作になり、入力欄から焦点を逃がさないよう握ることを固定する。
///
/// 壊れると何が起きるか: ⇧⇥ が起動先を回す・⇥ がベースを回す。⇥・⇧⇥ で焦点が入力欄から外へ逃げて、↑↓ と打鍵が効かなくなる。
/// ベースを選ぶ画面の esc で「ほか…」が外れる、または一覧へ戻った後に入力欄が一覧のキーを受けない。
@MainActor
final class WorktreePaletteFieldKeyTests: OrbeTestCase {
  /// キー 1 打を入口へ渡し、握る（入力欄へ届けない）ことを確かめる。
  private func send(
    _ key: KeyEquivalent, _ modifiers: EventModifiers = [], to model: WorktreePaletteModel,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      WorktreePaletteFieldKeys.handle(KeyInput(key, modifiers: modifiers), model: model), .handled,
      "握る（入力欄へ届けない）", file: file, line: line)
  }

  /// 作成行の選択中、⇧⇥ はベースだけを回し、⇥ は起動先だけを回す。
  func testShiftTabCyclesTheBaseAndTabCyclesTheTarget() {
    let model = DesignSceneFixtures.worktreePaletteNewBranchModel()
    XCTAssertEqual(model.selectedBaseChoice?.role, .previous, "前提: 作成行・初めは前回")

    send(.backtab, .shift, to: model)
    XCTAssertEqual(model.selectedBaseChoice?.role, .defaultBranch, "⇧⇥ でベースが進む")
    XCTAssertEqual(model.selectedTargetName, "claude", "⇧⇥ は起動先を動かさない")

    send(.tab, to: model)
    XCTAssertEqual(model.selectedTargetName, "shell", "⇥ で起動先が進む")
    XCTAssertEqual(model.selectedBaseChoice?.role, .defaultBranch, "⇥ はベースを動かさない")

    send(.backtab, .shift, to: model)
    XCTAssertEqual(model.selectedBaseChoice?.role, .current, "焦点は入力欄に残り、続けて効く")
  }

  /// ベースを選ぶ画面の esc は選ばずに一覧へ戻り、ベースは「ほか…」のまま。入力欄は一覧のキーを受け直す。
  func testEscapeFromTheBasePickerKeepsOtherAndTheFieldStillWorks() {
    let model = DesignSceneFixtures.worktreePaletteBasePickerModel()
    XCTAssertEqual(model.mode, .basePicker, "前提: ベースを選ぶ画面")

    send(.escape, to: model)

    XCTAssertEqual(model.mode, .list)
    XCTAssertEqual(model.selectedBaseChoice?.role, .other)
    XCTAssertNil(model.pickedBase)
    send(.backtab, .shift, to: model)
    XCTAssertEqual(model.selectedBaseChoice?.role, .previous, "⇧⇥ が末尾から先頭へ回る")
  }
}
