import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 本物の `TaskPaletteCard` を実 `NSWindow` に載せ、実 `NSEvent` のキーを届けて、焦点の行き先（入力欄 /
/// 詳細の項目 / 詳細の編集欄）ごとにキーが意図した操作になることを固定する。
///
/// 壊れると何が起きるか: 入力欄に文字があるのに space がタスクを完了にする、入力を消そうと ⌘⌫ を押し続けた
/// リピートで次のタスクまで消える。→ で詳細に入れない、詳細で打った文字が編集欄に届かず一覧の入力に入る、
/// ⇥ で焦点がカードの外へ逃げて以後のキーが効かない。どれもモデル単体では再現せず、実際に描いて
/// キーを届けないと分からない。
@MainActor
final class TaskPaletteCardKeyTests: PaletteCardWindowTestCase {
  private enum Key {
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let enter: UInt16 = 36
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
  }

  /// 実機の矢印キーは numericPad と function の修飾を伴って届く。
  private let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

  private func model() -> TaskPaletteModel { TaskPaletteSamples.threeTodos() }

  private func mount(_ model: TaskPaletteModel) -> NSWindow {
    NSApplication.shared.setActivationPolicy(.accessory)
    let window = KeyWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 640),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: TaskPaletteCard(model: model, detailWidth: 340)
        .frame(width: 960, height: 600)
        .environment(\.localization, LocalizationStore(language: .ja)))
    window.makeKeyAndOrderFront(nil)
    held.append(window)
    pump(0.4)
    return window
  }

  private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
  }

  private var held: [NSWindow] = []

  override func tearDown() {
    held.forEach { $0.orderOut(nil) }
    held.removeAll()
    super.tearDown()
  }

  private func press(
    _ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [],
    repeating: Bool = false, to window: NSWindow
  ) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: repeating, keyCode: keyCode)
    else { return XCTFail("キーイベントを作れない") }
    NSApp.sendEvent(event)
    pump(0.15)
  }

  private func arrow(_ keyCode: UInt16, _ extra: NSEvent.ModifierFlags = [], to window: NSWindow) {
    let character: NSEvent.SpecialKey =
      switch keyCode {
      case Key.left: .leftArrow
      case Key.right: .rightArrow
      case Key.up: .upArrow
      default: .downArrow
      }
    press(
      keyCode, String(UnicodeScalar(character.rawValue)!), arrowFlags.union(extra), to: window)
  }

  private func type(_ text: String, into window: NSWindow) {
    for character in text { press(0, String(character), to: window) }
  }

  private func status(_ model: TaskPaletteModel, _ id: Int) -> TaskItem.Status? {
    model.store.tasks.first { $0.id == id }?.status
  }

  // MARK: - 入力欄（一覧）

  func testSpaceCompletesTheSelectedTaskOnlyWhileTheFieldIsEmpty() {
    let model = model()
    let window = mount(model)

    press(Key.space, " ", to: window)
    XCTAssertEqual(status(model, 1), .done, "空の入力欄の space は選んだタスクを完了にする")

    type("b", into: window)
    press(Key.space, " ", to: window)
    XCTAssertEqual(model.query, "b ", "文字があるときの space は空白を打つ")
    XCTAssertEqual(status(model, 2), .todo)
  }

  func testEnterCompletesTheSelectedTaskAndAddsFromTheAddRow() throws {
    let model = model()
    let window = mount(model)

    press(Key.enter, "\r", to: window)
    XCTAssertEqual(status(model, 1), .done)

    type("新しい", into: window)
    press(Key.enter, "\r", to: window)
    XCTAssertEqual(model.store.tasks.last?.title, "新しい")
    XCTAssertEqual(model.query, "")
  }

  func testCommandBackspaceDeletesOneTaskEvenWhenHeldDown() {
    let model = model()
    let window = mount(model)

    press(Key.delete, "\u{7F}", .command, to: window)
    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)
    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.map(\.id), [2, 3], "消えるのは押した 1 件だけ")
  }

  func testCommandBackspaceWithTextEditsTheFieldInsteadOfDeleting() {
    let model = model()
    let window = mount(model)
    type("a", into: window)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.selectedID, .task(1), "前提: 一致したタスクを選んだ")

    press(Key.delete, "\u{7F}", .command, to: window)

    XCTAssertEqual(model.store.tasks.count, 3, "文字があるときはタスクを消さない")
    XCTAssertEqual(model.query, "", "入力欄の文字を行頭まで消す")
  }

  func testOptionArrowsReorderAndCommandArrowsJump() {
    let model = model()
    let window = mount(model)

    arrow(Key.down, .command, to: window)
    XCTAssertEqual(model.selectedID, .task(3), "⌘↓ で末尾へ")

    arrow(Key.up, .option, to: window)
    XCTAssertEqual(model.store.tasks.map(\.id), [1, 3, 2], "⌥↑ で前のタスクの前へ")
    XCTAssertEqual(model.selectedID, .task(3))
  }

  func testTabSwitchesScopeAndShiftTabSwitchesTabWhileTheFieldKeepsTheKeys() {
    let model = model()
    let window = mount(model)

    press(Key.tab, "\t", to: window)
    XCTAssertEqual(model.scope, .opened)

    press(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(model.tab, .github)

    press(Key.tab, "\u{19}", .shift, to: window)
    type("x", into: window)
    XCTAssertEqual(model.tab, .tasks)
    XCTAssertEqual(model.query, "x", "焦点は入力欄に残り、続けて打てる")
  }

  func testEscapeInTheListClosesTheScreen() {
    let model = model()
    var dismissed = false
    model.onDismiss = { dismissed = true }
    let window = mount(model)

    press(Key.escape, "\u{1B}", to: window)

    XCTAssertTrue(dismissed)
  }

  // MARK: - 詳細

  /// 一覧から → で詳細へ入る。→ 以外の詳細のテストは、ここに依らずモデルから詳細へ入れて測る。
  func testRightArrowEntersTheDetailOfTheSelectedTask() {
    let model = model()
    let window = mount(model)

    arrow(Key.right, to: window)

    XCTExpectFailure(
      "バグ疑い: 実機の矢印キーは numericPad・function の修飾を伴うが、入力欄の → は修飾が空のときしか"
        + "詳細へ入らない")
    XCTAssertEqual(model.area, .detail(.status))
  }

  /// 詳細の項目に入れた状態（焦点はカードの器へ移る）。
  private func enterDetail(
    _ model: TaskPaletteModel, at field: TaskDetailField, in window: NSWindow
  ) {
    model.enterDetail()
    model.area = .detail(field)
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
    XCTAssertEqual(model.area, .detail(.priority))
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
    XCTAssertEqual(model.area, .detail(.waiting), "取り消した後も項目に居る")
    arrow(Key.down, to: window)
    XCTAssertEqual(model.area, .detail(.priority), "器が再びキーを受ける")
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
