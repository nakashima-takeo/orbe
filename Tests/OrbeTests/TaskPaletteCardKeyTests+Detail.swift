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
    enterDetail(model, at: .description, in: window)
    press(Key.enter, "\r", to: window)
    type("abc", into: window)
    XCTAssertNotNil(model.draft, "前提: 詳細を編集中")
    flush(window)

    try click(atFieldOf: window)
    type("x", into: window)

    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.description, "abc", "打った内容は確定して残る")
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

  /// 文字の項目で ↵ を押し続けても、編集の開始と確定を繰り返さない——押した ↵ で編集を始め、続くリピートは
  /// 確定しない（編集のまま）。リピートだけが届いても編集を始めない。
  func testEnterHeldOnAOneLineFieldStartsEditingOnceAndKeepsEditing() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .waiting, in: window)

    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    press(Key.enter, "\r", repeating: true, to: window)

    XCTAssertNotNil(model.draft, "リピートで確定しない")
  }

  func testEnterKeyRepeatAloneDoesNotStartEditing() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .waiting, in: window)

    press(Key.enter, "\r", repeating: true, to: window)

    XCTAssertNil(model.draft)
  }

  /// 詳細の編集中に ↵ を押し続けると、リピートも改行として入る。
  func testEnterHeldInTheDescriptionTypesANewlinePerRepeat() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .description, in: window)

    press(Key.enter, "\r", to: window)
    type("1", into: window)
    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    type("2", into: window)
    press(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.description, "1\n\n\n2")
  }

  /// 詳細の ⌘↵ を押し続けても確定は 1 回——リピートだけでは確定せず、確定の後に続くリピートで編集を
  /// 始め直さない。
  func testCommandEnterHeldInTheDescriptionCommitsOnce() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .description, in: window)
    press(Key.enter, "\r", to: window)
    type("1", into: window)

    press(Key.enter, "\r", .command, repeating: true, to: window)
    XCTAssertNotNil(model.draft, "リピートだけでは確定しない")

    press(Key.enter, "\r", .command, to: window)
    press(Key.enter, "\r", .command, repeating: true, to: window)
    press(Key.enter, "\r", .command, repeating: true, to: window)

    XCTAssertNil(model.draft, "確定した後に編集を始め直さない")
    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.description, "1")
    XCTAssertEqual(model.area, .detail(.field(.description)))
  }

  /// ⌘↵ は確定のキーなので、詳細の文字の項目（編集していない状態）で押しても編集を始めない。
  func testCommandEnterOnATextFieldDoesNotStartEditing() {
    let model = model()
    let window = mount(model)

    for field in [TaskDetailField.title, .description] {
      enterDetail(model, at: field, in: window)
      press(Key.enter, "\r", .command, to: window)
      XCTAssertNil(model.draft, "\(field)")
    }
  }

  func testDescriptionTakesNewlinesWithEnterAndCommitsWithCommandEnter() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .description, in: window)

    press(Key.enter, "\r", to: window)
    type("1", into: window)
    press(Key.enter, "\r", to: window)
    type("2", into: window)
    press(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.description, "1\n2")
  }
}
