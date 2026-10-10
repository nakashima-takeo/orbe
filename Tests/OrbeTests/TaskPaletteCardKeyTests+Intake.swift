import AppKit
import XCTest

@testable import Orbe

/// 受信タブのキー（入力欄の提案の一覧、カードの器の棚と中身）。
///
/// 壊れると何が起きるか: 絞り込みに「x」を打つと提案が消える。入力を消そうと押した ⌘⌫（そのリピート）が提案を捨てる。
/// リンクを開くつもりの ⌘↵ が提案をタスクにする。← で文字の間を動けない、または棚へ入れない。中身の space が入力欄に
/// 空白を打つ。⇧⇥ で棚から焦点が逃げる。
extension TaskPaletteCardKeyTests {
  private func intakeModel() -> TaskPaletteModel {
    let model = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a")],
      intakes: DesignSceneFixtures.intakeRunner(DesignSceneFixtures.intakeDesignFile()))
    model.setTab(.intake)
    return model
  }

  /// x は文字として入り、⌘⌫ は文字があれば行頭まで消すだけ。空の入力欄の ⌘⌫ で選んだ提案を捨てる。↵ でタスクにする。
  func testIntakeFieldTypesXAndCommandDeleteDismissesOnlyWhenEmpty() {
    let model = intakeModel()
    let window = mount(model)

    type("x", into: window)
    XCTAssertEqual(model.query, "x")
    press(Key.delete, "\u{7F}", .command, to: window)
    XCTAssertEqual(model.query, "")
    XCTAssertEqual(model.intake.store.proposals.map(\.state), [.open, .open, .open])

    press(Key.delete, "\u{7F}", .command, to: window)
    XCTAssertEqual(model.intake.store.proposals[0].state, .dismissed)
    XCTAssertEqual(model.intake.proposalList.selectedID, 2)

    press(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.contains { $0.title == "オンボーディングの環境構築手順を見る" })
  }

  /// 入力を行頭まで消した ⌘⌫ を押し続けても、空になった後のリピートでは提案を捨てない（捨てた提案は戻せない）。
  func testIntakeCommandDeleteHeldDownAfterClearingTheFieldDismissesNothing() {
    let model = intakeModel()
    let window = mount(model)
    type("x", into: window)

    press(Key.delete, "\u{7F}", .command, to: window)
    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)
    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)

    XCTAssertEqual(model.query, "")
    XCTAssertEqual(model.intake.store.proposals.map(\.state), [.open, .open, .open])
  }

  /// ⌘↵ は選んでいる提案のリンクをブラウザで開くだけで、タスクにはしない。
  func testIntakeCommandEnterOpensTheLinkWithoutMakingATask() {
    let model = intakeModel()
    var opened: [String] = []
    model.onOpenURL = { opened.append($0.absoluteString) }
    let window = mount(model)

    press(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(opened, ["https://example.slack.com/archives/D01-1"])
    XCTAssertEqual(model.store.tasks.count, 1, "タスクにしない")
    XCTAssertEqual(model.intake.store.proposals[0].state, .open)
  }

  /// ← で棚（入力欄が空のときだけ）、棚の ↓ で受信を選び → で戻る、→ で中身、中身の space で止める ⇄ 再開、esc で戻る。
  func testIntakeArrowsMoveBetweenShelfProposalsAndContents() {
    let model = intakeModel()
    let window = mount(model)

    arrow(Key.left, to: window)
    XCTAssertEqual(model.intake.place, .shelf)
    press(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(model.visibleTab, .intake, "棚では ⇧⇥ でタブを替えない")
    arrow(Key.down, to: window)
    XCTAssertEqual(model.intake.shelfList.selectedID, .intake(1))
    arrow(Key.right, to: window)
    XCTAssertEqual(model.intake.place, .proposals)

    arrow(Key.right, to: window)
    XCTAssertEqual(model.intake.place, .contents)
    press(Key.space, " ", to: window)
    XCTAssertEqual(model.intake.selectedIntake?.paused, true)
    XCTAssertEqual(model.query, "", "空白は入力欄に入らない")
    press(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(model.intake.place, .proposals)

    type("a", into: window)
    arrow(Key.left, to: window)
    XCTAssertEqual(model.intake.place, .proposals, "文字があるときの ← は文字の間を動く")
  }
}
