import AppKit
import XCTest

@testable import Orbe

/// 提案タブのキー（入力欄の提案の一覧、カードの器の棚と中身）。
///
/// 壊れると何が起きるか: 絞り込みに「x」を打つと提案が消える。入力を消そうと押した ⌘⌫（そのリピート）が提案を捨てる。
/// リンクを開くつもりの ⌘O が提案をタスクにする。⌘↵ でタスクになっても agent を開く画面が出ない、押し続けるとタスクが
/// いくつもできる。← で文字の間を動けない、または棚へ入れない。中身の space が入力欄に
/// 空白を打つ。⇧⇥ で棚から焦点が逃げる。中身の ↵ が今すぐ実行にならず提案をタスクにする、⌘⌫ が受信でなく提案を捨てる。
/// 提案の一覧の esc で画面が閉じない。
extension TaskPaletteCardKeyTests {
  private enum AutomationKey {
    static let o: UInt16 = 31
  }

  private func automationModel() -> TaskPaletteModel {
    let model = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a")],
      automations: DesignSceneFixtures.automationRunner(DesignSceneFixtures.automationDesignFile()))
    model.setTab(.automation)
    return model
  }

  /// x は文字として入り、⌘⌫ は文字があれば行頭まで消すだけ。空の入力欄の ⌘⌫ で選んだ提案を捨てる。↵ でタスクにする。
  func testAutomationFieldTypesXAndCommandDeleteDismissesOnlyWhenEmpty() {
    let model = automationModel()
    let window = mount(model)

    type("x", into: window)
    XCTAssertEqual(model.query, "x")
    send(Key.delete, "\u{7F}", .command, to: window)
    XCTAssertEqual(model.query, "")
    XCTAssertEqual(model.automation.store.proposals.map(\.state), [.open, .open, .open])

    send(Key.delete, "\u{7F}", .command, to: window)
    XCTAssertEqual(model.automation.store.proposals[0].state, .dismissed)
    XCTAssertEqual(model.automation.proposalList.selectedID, 2)

    send(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.contains { $0.title == "オンボーディングの環境構築手順を見る" })
  }

  /// 入力を行頭まで消した ⌘⌫ を押し続けても、空になった後のリピートでは提案を捨てない（捨てた提案は戻せない）。
  func testAutomationCommandDeleteHeldDownAfterClearingTheFieldDismissesNothing() {
    let model = automationModel()
    let window = mount(model)
    type("x", into: window)

    send(Key.delete, "\u{7F}", .command, to: window)
    send(Key.delete, "\u{7F}", .command, repeating: true, to: window)
    send(Key.delete, "\u{7F}", .command, repeating: true, to: window)

    XCTAssertEqual(model.query, "")
    XCTAssertEqual(model.automation.store.proposals.map(\.state), [.open, .open, .open])
  }

  /// ⌘O は選んでいる提案のリンクをブラウザで開くだけで、タスクにはしない。
  func testAutomationCommandOOpensTheLinkWithoutMakingATask() {
    let model = automationModel()
    var opened: [String] = []
    model.onOpenURL = { opened.append($0.absoluteString) }
    let window = mount(model)

    send(AutomationKey.o, "o", .command, to: window)

    XCTAssertEqual(opened, ["https://example.slack.com/archives/D01-1"])
    XCTAssertEqual(model.store.tasks.count, 1, "タスクにしない")
    XCTAssertEqual(model.automation.store.proposals[0].state, .open)
  }

  /// ⌘↵ は選んでいる提案を ↵ と同じくタスクにし、そのタスクの agent を開く口へ渡す。押し続けても 1 回だけ。
  func testAutomationCommandEnterMakesATaskAndOpensItOnceEvenWhenHeldDown() throws {
    let model = automationModel()
    var opened: [Int] = []
    model.onOpenWorktreePalette = { opened.append($0) }
    let window = mount(model)

    send(Key.enter, "\r", .command, to: window)
    send(Key.enter, "\r", .command, repeating: true, to: window)
    send(Key.enter, "\r", .command, repeating: true, to: window)

    let task = try XCTUnwrap(model.store.tasks.first { $0.title == "見積もりを山田さんに送る" })
    XCTAssertEqual(model.store.tasks.count, 2, "タスクは 1 つだけ")
    XCTAssertEqual(task.workspace, TaskPaletteSamples.home, "↵ と同じく Home に付く")
    XCTAssertEqual(model.automation.store.proposals[0].state, .accepted(taskId: task.id))
    XCTAssertEqual(model.automation.store.proposals[1].state, .open, "リピートで次の提案をさばかない")
    XCTAssertEqual(opened, [task.id])
  }

  /// 押した瞬間だけ効くキーは、押し続けても 1 回だけ効く（提案の ⌘O、中身の space・↵）。
  func testAutomationKeysHeldDownActOnce() {
    let model = automationModel()
    var opened: [String] = []
    model.onOpenURL = { opened.append($0.absoluteString) }
    let window = mount(model)

    send(AutomationKey.o, "o", .command, to: window)
    send(AutomationKey.o, "o", .command, repeating: true, to: window)
    send(AutomationKey.o, "o", .command, repeating: true, to: window)
    XCTAssertEqual(opened.count, 1, "ブラウザを 1 つだけ開く")

    arrow(Key.left, to: window)
    arrow(Key.down, to: window)
    arrow(Key.right, to: window)
    arrow(Key.right, to: window)
    send(Key.space, " ", to: window)
    send(Key.space, " ", repeating: true, to: window)
    XCTAssertEqual(model.automation.selectedAutomation?.paused, true, "止める ⇄ 再開は 1 回だけ（往復しない）")

    send(Key.enter, "\r", to: window)
    send(Key.enter, "\r", repeating: true, to: window)
    XCTAssertTrue(model.automation.runner.isRunning(1))
    XCTAssertNil(model.automation.error, "リピートで「実行中のため今すぐ実行できません」の赤を出さない")
  }

  /// ← で棚（入力欄が空のときだけ）、棚の ↓ で受信を選び → で戻る、→ で中身、中身の space で止める ⇄ 再開、esc で戻る。
  func testAutomationArrowsMoveBetweenShelfProposalsAndContents() {
    let model = automationModel()
    let window = mount(model)

    arrow(Key.left, to: window)
    XCTAssertEqual(model.automation.place, .shelf)
    send(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(model.visibleTab, .automation, "棚では ⇧⇥ でタブを替えない")
    arrow(Key.down, to: window)
    XCTAssertEqual(model.automation.shelfList.selectedID, .automation(1))
    arrow(Key.right, to: window)
    XCTAssertEqual(model.automation.place, .proposals)

    arrow(Key.right, to: window)
    XCTAssertEqual(model.automation.place, .contents)
    send(Key.space, " ", to: window)
    XCTAssertEqual(model.automation.selectedAutomation?.paused, true)
    XCTAssertEqual(model.query, "", "空白は入力欄に入らない")
    send(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(model.automation.place, .proposals)

    type("a", into: window)
    arrow(Key.left, to: window)
    XCTAssertEqual(model.automation.place, .proposals, "文字があるときの ← は文字の間を動く")
  }

  /// 中身の ↵ は今すぐ実行、⌘⌫ は確認なしで受信を消して提案の一覧へ戻る。どちらも提案には触れない。
  func testAutomationContentsEnterRunsNowAndCommandDeleteRemovesTheAutomation() {
    let model = automationModel()
    let window = mount(model)
    arrow(Key.left, to: window)
    arrow(Key.down, to: window)
    arrow(Key.right, to: window)
    arrow(Key.right, to: window)
    XCTAssertEqual(model.automation.place, .contents)

    send(Key.enter, "\r", to: window)
    XCTAssertTrue(model.automation.runner.isRunning(1))
    XCTAssertEqual(model.store.tasks.count, 1, "提案をタスクにしない")

    send(Key.delete, "\u{7F}", .command, to: window)
    XCTAssertNil(model.automation.store.automation(1))
    XCTAssertEqual(model.automation.place, .proposals)
    XCTAssertFalse(
      model.automation.store.proposals.contains { $0.state == .dismissed }, "提案を捨てない")
  }

  /// 提案の一覧の esc は画面を閉じる。
  func testAutomationEscapeOnTheProposalsClosesTheScreen() {
    let model = automationModel()
    var dismissed = false
    model.onDismiss = { dismissed = true }
    let window = mount(model)

    send(Key.escape, "\u{1B}", to: window)

    XCTAssertTrue(dismissed)
  }

  /// AI が中身を見ている受信を消したら、カードが受信のストアの変化を付け直しへ届け、提案の一覧へ戻って同じ位置の受信を
  /// 選ぶ。
  func testAutomationDeletedElsewhereWhileInContentsReturnsToProposals() throws {
    let model = automationModel()
    let window = mount(model)
    model.automation.tapShelf(.automation(1))
    model.automation.enterContents()
    flush(window)

    try model.automation.runner.delete(1)
    flush(window)

    XCTAssertEqual(model.automation.place, .proposals)
    XCTAssertEqual(model.automation.shelfList.selectedID, .automation(2))
  }

  /// 選んでいる提案が別の口でさばかれたら、カードが付け直しへ届け、↵ が次の提案に効く（黙って何もしないにならない）。
  func testProposalHandledElsewhereMovesTheSelectionSoEnterStillWorks() throws {
    let model = automationModel()
    let window = mount(model)
    XCTAssertEqual(model.automation.proposalList.selectedID, 1)

    try model.automation.store.dismiss(1)
    flush(window)

    XCTAssertEqual(model.automation.proposalList.selectedID, 2)
    send(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.contains { $0.title == "オンボーディングの環境構築手順を見る" })
  }
}
