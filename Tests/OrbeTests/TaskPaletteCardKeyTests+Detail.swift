import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 右の欄（→ で入る）の項目に焦点があるときと、右の欄の編集欄のキー、右の欄から入力欄へのクリック。
extension TaskPaletteCardKeyTests {
  /// 一覧から → で右の欄へ入る。→ 以外の右の欄のテストは、ここに依らずモデルから右の欄へ入れて測る。
  func testRightArrowEntersTheDetailOfTheSelectedTask() {
    let model = model()
    let window = mount(model)

    arrow(Key.right, to: window)

    XCTAssertEqual(model.area, .detail(.field(.status)))
  }

  /// 右の欄の項目に入れた状態（焦点はカードの器へ移る）。
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
    XCTAssertEqual(model.area, .list, "右の欄の esc は一覧へ戻る")

    enterDetail(model, at: .priority, in: window)
    press(Key.space, " ", to: window)
    XCTAssertEqual(status(model, 1), .done, "右の欄でも space はそのタスクに効く")
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

  /// 右の欄で編集している間に入力欄をクリックすると、打った内容を確定して一覧へ戻り、続く打鍵は入力欄に入る。
  func testClickingTheFieldFromTheDetailCommitsAndReturnsTheKeysToTheField() throws {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .description, in: window)
    press(Key.enter, "\r", to: window)
    type("abc", into: window)
    XCTAssertNotNil(model.draft, "前提: 詳細の欄を編集中")
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

  /// ⌘↵ は 1 行の項目の確定のキーなので、文字の項目（編集していない状態）で押しても編集を始めない。
  func testCommandEnterOnATextFieldDoesNotStartEditing() {
    let model = model()
    let window = mount(model)

    for field in [TaskDetailField.title, .description] {
      enterDetail(model, at: field, in: window)
      press(Key.enter, "\r", .command, to: window)
      XCTAssertNil(model.draft, "\(field)")
    }
  }

  /// 詳細の欄は ↵ が改行で（押し続けたリピートも改行）、esc で確定して欄に居たまま編集を終える。もう一度の
  /// esc で一覧へ戻る。
  func testDescriptionTakesNewlinesWithEnterAndCommitsWithEscape() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .description, in: window)

    press(Key.enter, "\r", to: window)
    type("1", into: window)
    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    type("2", into: window)
    press(Key.escape, "\u{1B}", to: window)

    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.description, "1\n\n\n2")
    XCTAssertNil(model.draft)
    XCTAssertEqual(model.area, .detail(.field(.description)))

    press(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(model.area, .list)
  }

  /// 詳細の欄の編集中の ⌘↵ は何もしない——確定も改行もせず、編集が続く。
  func testCommandEnterWhileEditingTheDescriptionDoesNothing() {
    let model = model()
    let window = mount(model)
    enterDetail(model, at: .description, in: window)
    press(Key.enter, "\r", to: window)
    type("1", into: window)

    press(Key.enter, "\r", .command, to: window)

    XCTAssertNotNil(model.draft, "編集が続く")
    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.description, "", "確定しない")
    type("2", into: window)
    press(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(model.store.tasks.first { $0.id == 1 }?.description, "12", "同じ編集が続き、改行は入らない")
  }
}
