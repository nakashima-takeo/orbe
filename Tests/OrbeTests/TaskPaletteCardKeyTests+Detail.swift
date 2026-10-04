import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 詳細（→ で入る右の欄）の項目に焦点があるときと、詳細の編集欄のキー、詳細から入力欄へのクリック。
extension TaskPaletteCardKeyTests {
  /// 一覧から → で詳細へ入る。→ 以外の詳細のテストは、ここに依らずモデルから詳細へ入れて測る。
  func testRightArrowEntersTheDetailOfTheSelectedTask() {
    let model = model()
    let window = mount(model)

    arrow(Key.right, to: window)

    XCTAssertEqual(model.area, .detail(.field(.status)))
  }

  /// 詳細の項目に入れた状態（焦点はカードの器へ移る）。
  func enterDetail(
    _ model: TaskPaletteModel, at field: TaskDetailField, in window: NSWindow
  ) {
    model.enterDetail()
    model.area = .detail(.field(field))
    flush(window)
  }

  func testArrowsInDetailMoveFieldsAndChangeValuesAndLeftOnAPlainFieldReturnsToTheList() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .status, in: window)

    arrow(Key.right, to: window)
    XCTAssertEqual(status(model, 1), .inProgress, "→ で値を変える")

    arrow(Key.down, to: window)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.area, .detail(.field(.priority)))
    arrow(Key.left, to: window)
    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.priority, .high, "← で値を変える")

    arrow(Key.down, to: window)
    arrow(Key.left, to: window)
    XCTAssertEqual(model.area, .list, "選択式でない項目の ← は一覧へ戻る")
    type("x", into: window)
    XCTAssertEqual(model.query, "x", "一覧へ戻ると入力欄が再びキーを受ける")
  }

  func testSpaceAndEscapeInDetail() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .status, in: window)

    press(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(model.area, .list, "詳細の esc は一覧へ戻る")

    enterDetail(model, at: .priority, in: window)
    press(Key.space, " ", to: window)
    XCTAssertEqual(status(model, 1), .done, "詳細でも space はそのタスクに効く")
    XCTAssertEqual(model.area, .list)
  }

  func testSpaceKeyRepeatInDetailCompletesNothing() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .priority, in: window)

    press(Key.space, " ", repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.map(\.status), [.todo, .todo, .todo])
    XCTAssertEqual(model.area, .detail(.field(.priority)))
  }

  /// 詳細で編集している間に入力欄をクリックすると、打った内容を確定して一覧へ戻り、続く打鍵は入力欄に入る。
  func testClickingTheFieldFromTheDetailCommitsAndReturnsTheKeysToTheField() throws {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .memo, in: window)
    press(Key.enter, "\r", to: window)
    type("abc", into: window)
    XCTAssertNotNil(model.draft, "前提: メモを編集中")
    flush(window)

    try click(atFieldOf: window)
    type("x", into: window)

    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.memo, "abc", "打った内容は確定して残る")
    XCTAssertNil(model.draft)
    XCTAssertEqual(model.area, .list)
    XCTAssertEqual(model.query, "x", "続く打鍵は入力欄に入る")
  }

  func testEnterOnATextFieldEditsInTheDetailAndEnterCommitsAndEscapeCancels() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .waiting, in: window)

    press(Key.enter, "\r", to: window)
    type("review", into: window)
    XCTAssertEqual(model.query, "", "打った文字は一覧の入力に入らない")
    press(Key.enter, "\r", to: window)

    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.waiting?.reason, "review")
    XCTAssertNil(model.draft)

    press(Key.enter, "\r", to: window)
    type("x", into: window)
    press(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(
      model.store.tasks.first { $0.id == 1 }?.waiting?.reason, "review", "esc は編集を取り消す")
    XCTAssertEqual(model.area, .detail(.field(.waiting)), "取り消した後も項目に居る")
    arrow(Key.down, to: window)
    XCTAssertEqual(model.area, .detail(.field(.priority)), "器が再びキーを受ける")
  }

  func testMemoTakesNewlinesWithEnterAndCommitsWithCommandEnter() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .memo, in: window)

    press(Key.enter, "\r", to: window)
    type("1", into: window)
    press(Key.enter, "\r", to: window)
    type("2", into: window)
    press(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.memo, "1\n2")
  }
}
