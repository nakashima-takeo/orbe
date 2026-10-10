import AppKit
import XCTest

@testable import Orbe

/// 受信タブのキー（入力欄の提案の一覧、カードの器の棚と中身）。
///
/// 壊れると何が起きるか: 絞り込みに「x」を打つと提案が消える。入力を消そうと押した ⌘⌫（そのリピート）が提案を捨てる。
/// リンクを開くつもりの ⌘↵ が提案をタスクにする。← で文字の間を動けない、または棚へ入れない。中身の space が入力欄に
/// 空白を打つ。⇧⇥ で棚から焦点が逃げる。中身の ↵ が今すぐ受信にならず提案をタスクにする、⌘⌫ が受信でなく提案を捨てる。
/// 提案の一覧の esc で画面が閉じない。
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

  /// 押した瞬間だけ効くキーは、押し続けても 1 回だけ効く（提案の ⌘↵、中身の space・↵）。
  func testIntakeKeysHeldDownActOnce() {
    let model = intakeModel()
    var opened: [String] = []
    model.onOpenURL = { opened.append($0.absoluteString) }
    let window = mount(model)

    press(Key.enter, "\r", .command, to: window)
    press(Key.enter, "\r", .command, repeating: true, to: window)
    press(Key.enter, "\r", .command, repeating: true, to: window)
    XCTAssertEqual(opened.count, 1, "ブラウザを 1 つだけ開く")

    arrow(Key.left, to: window)
    arrow(Key.down, to: window)
    arrow(Key.right, to: window)
    arrow(Key.right, to: window)
    press(Key.space, " ", to: window)
    press(Key.space, " ", repeating: true, to: window)
    press(Key.space, " ", repeating: true, to: window)
    XCTAssertEqual(model.intake.selectedIntake?.paused, true, "止める ⇄ 再開は 1 回だけ")

    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    XCTAssertTrue(model.intake.runner.isRunning(1))
    XCTAssertNil(model.intake.error, "リピートで「受信中」の赤を出さない")
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

  /// 中身の ↵ は今すぐ受信、⌘⌫ は確認なしで受信を消して提案の一覧へ戻る。どちらも提案には触れない。
  func testIntakeContentsEnterRunsNowAndCommandDeleteRemovesTheIntake() {
    let model = intakeModel()
    let window = mount(model)
    arrow(Key.left, to: window)
    arrow(Key.down, to: window)
    arrow(Key.right, to: window)
    arrow(Key.right, to: window)
    XCTAssertEqual(model.intake.place, .contents)

    press(Key.enter, "\r", to: window)
    XCTAssertTrue(model.intake.runner.isRunning(1))
    XCTAssertEqual(model.store.tasks.count, 1, "提案をタスクにしない")

    press(Key.delete, "\u{7F}", .command, to: window)
    XCTAssertNil(model.intake.store.intake(1))
    XCTAssertEqual(model.intake.place, .proposals)
    XCTAssertFalse(
      model.intake.store.proposals.contains { $0.state == .dismissed }, "提案を捨てない")
  }

  /// 提案の一覧の esc は画面を閉じる。
  func testIntakeEscapeOnTheProposalsClosesTheScreen() {
    let model = intakeModel()
    var dismissed = false
    model.onDismiss = { dismissed = true }
    let window = mount(model)

    press(Key.escape, "\u{1B}", to: window)

    XCTAssertTrue(dismissed)
  }

  /// AI が中身を見ている受信を消したら、カードが受信のストアの変化を付け直しへ届け、提案の一覧へ戻って同じ位置の受信を
  /// 選ぶ。
  func testIntakeDeletedElsewhereWhileInContentsReturnsToProposals() throws {
    let model = intakeModel()
    let window = mount(model)
    model.intake.tapShelf(.intake(1))
    model.intake.enterContents()
    flush(window)

    try model.intake.runner.delete(1)
    flush(window)

    XCTAssertEqual(model.intake.place, .proposals)
    XCTAssertEqual(model.intake.shelfList.selectedID, .intake(2))
  }

  /// 選んでいる提案が別の口でさばかれたら、カードが付け直しへ届け、↵ が次の提案に効く（黙って何もしないにならない）。
  func testProposalHandledElsewhereMovesTheSelectionSoEnterStillWorks() throws {
    let model = intakeModel()
    let window = mount(model)
    XCTAssertEqual(model.intake.proposalList.selectedID, 1)

    try model.intake.store.dismiss(1)
    flush(window)

    XCTAssertEqual(model.intake.proposalList.selectedID, 2)
    press(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.contains { $0.title == "オンボーディングの環境構築手順を見る" })
  }
}
