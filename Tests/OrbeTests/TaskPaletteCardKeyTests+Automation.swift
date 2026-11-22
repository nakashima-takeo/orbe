import AppKit
import XCTest

@testable import Orbe

/// 提案タブのキー（入力欄の絞り込み欄と候補の一覧、カードの器の棚）。
///
/// 壊れると何が起きるか: 絞り込みに「x」を打つと候補が消える。入力を消そうと押した ⌘⌫（そのリピート）が候補を捨てる。
/// ⇧⇥ で棚から焦点が逃げる。棚で ↵ を押し続けると候補がタスクになる。別の口で候補や自動化が消えた後の ↵・⌘↵ が
/// 空振りする。
extension TaskPaletteCardKeyTests {
  private func automationModel() -> TaskPaletteModel {
    let model = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a")],
      automations: DesignSceneFixtures.automationRunner(
        DesignSceneFixtures.automationDesignSamples()),
      workspaces: { DesignSceneFixtures.taskWorkspaces })
    model.setTab(.automation)
    return model
  }

  /// 候補の一覧に居る提案タブ。
  private func listedAutomationModel() -> TaskPaletteModel {
    let model = automationModel()
    model.automation.enterProposals()
    return model
  }

  /// 開いた直後は絞り込み欄に居て、打てばすぐ絞り込む。↵ は覚えている行をタスクにしない。
  func testAutomationOpensOnTheFieldWhereTypingFiltersAndEnterDoesNothing() {
    let model = automationModel()
    let window = mount(model)

    type("週報", into: window)
    XCTAssertEqual(model.automation.proposalIDs, [3])
    send(Key.enter, "\r", to: window)
    send(Key.delete, "\u{7F}", .command, to: window)
    send(Key.delete, "\u{7F}", .command, to: window)

    XCTAssertEqual(model.store.tasks.count, 1, "タスクにしない")
    XCTAssertEqual(model.automation.store.proposals.map(\.state), [.open, .open, .open], "捨てない")
    XCTAssertEqual(model.automation.place, .field)
  }

  /// x は文字として入り、⌘⌫ は文字があれば行頭まで消すだけ。空の入力欄の ⌘⌫ で選んだ候補を捨てる。↵ でタスクにする。
  func testAutomationFieldTypesXAndCommandDeleteDismissesOnlyWhenEmpty() throws {
    let model = listedAutomationModel()
    let window = mount(model)

    type("x", into: window)
    XCTAssertEqual(model.query, "x")
    send(Key.delete, "\u{7F}", .command, to: window)
    XCTAssertEqual(model.query, "")
    XCTAssertEqual(model.automation.store.proposals.map(\.state), [.open, .open, .open])

    send(Key.delete, "\u{7F}", .command, to: window)
    XCTAssertEqual(
      try model.automation.store.decision(of: 1), .dismissed,
      "空の入力欄の ⌘⌫ で選んだ候補を捨てる。testAutomationOpensOnTheFieldWhereTypingFiltersAndEnterDoesNothing の"
        + "「捨てない」と testAutomationCommandDeleteHeldDownAfterClearingTheFieldDismissesNothing の「リピートでは捨てない」"
        + "の対で、これが待たずに成り立たなくなったら、それらのテストが確かめる時点も成り立たない")
    XCTAssertEqual(model.automation.proposalList.selectedID, 2)

    send(Key.enter, "\r", to: window)
    XCTAssertTrue(
      model.store.tasks.contains { $0.title == "オンボーディングの環境構築手順を見る" },
      "↵ で選んだ候補をタスクにする。testAutomationOpensOnTheFieldWhereTypingFiltersAndEnterDoesNothing の"
        + "「タスクにしない」と testAutomationEnterHeldOnTheShelfStopsAtTheProposals の「リピートではタスクにしない」"
        + "の対で、これが待たずに成り立たなくなったら、それらのテストが確かめる時点も成り立たない")
  }

  /// 入力を行頭まで消した ⌘⌫ を押し続けても、空になった後のリピートでは候補を捨てない（捨てた候補は戻せない）。
  func testAutomationCommandDeleteHeldDownAfterClearingTheFieldDismissesNothing() {
    let model = listedAutomationModel()
    let window = mount(model)
    type("x", into: window)

    send(Key.delete, "\u{7F}", .command, to: window)
    send(Key.delete, "\u{7F}", .command, repeating: true, to: window)
    send(Key.delete, "\u{7F}", .command, repeating: true, to: window)

    XCTAssertEqual(model.query, "")
    XCTAssertEqual(model.automation.store.proposals.map(\.state), [.open, .open, .open])
  }

  /// 棚で ↵ を押し続けても、押し始めの ↵ で候補の一覧へ入って止まる——続くリピートで候補をタスクにしない。
  func testAutomationEnterHeldOnTheShelfStopsAtTheProposals() {
    let model = automationModel()
    let window = mount(model)
    arrow(Key.down, to: window)

    send(Key.enter, "\r", to: window)
    send(Key.enter, "\r", repeating: true, to: window)
    send(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(model.automation.place, .proposals)
    XCTAssertEqual(model.store.tasks.count, 1)
  }

  /// 棚でも ⇥・⇧⇥ でタブを巡り、戻ると居場所が残る。移った先では入力欄がキーを受ける。
  func testTabOnTheShelfCyclesTheTabsAndKeepsThePlace() {
    let model = automationModel()
    let window = mount(model)
    arrow(Key.down, to: window)

    send(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(model.tab, .github)
    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .automation)
    XCTAssertEqual(model.automation.place, .shelf, "戻ると棚に居る")

    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .tasks)
    type("x", into: window)
    XCTAssertEqual(model.query, "x", "移った先の入力欄が続く打鍵を受ける")
  }

  /// 選んでいる候補が別の口でさばかれたら、カードが付け直しへ届け、↵ が次の候補に効く（黙って何もしないにならない）。
  func testProposalHandledElsewhereMovesTheSelectionSoEnterStillWorks() throws {
    let model = listedAutomationModel()
    let window = mount(model)
    XCTAssertEqual(model.automation.proposalList.selectedID, 1)

    try model.automation.store.dismiss(1, now: DesignSceneFixtures.automationNow)
    flush(window)

    XCTAssertEqual(model.automation.proposalList.selectedID, 2)
    send(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.contains { $0.title == "オンボーディングの環境構築手順を見る" })
  }

  /// 候補を持たない自動化が別の口で消えたら、カードが棚の選択を同じ位置の段へ付け直し、⌘↵ はその段の更新になる（消えた
  /// 自動化を指したまま黙って何もしないにならない）。
  func testAutomationDeletedElsewhereMovesTheShelfSelectionSoCommandEnterStillRefreshes() throws {
    let model = automationModel()
    let window = mount(model)
    model.automation.tapShelf(.automation(3))
    flush(window)

    try model.automation.runner.delete(3)
    flush(window)
    send(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(model.automation.shelfList.selectedID, .automation(4))
    XCTAssertTrue(model.automation.runner.isFlowing(4))
  }
}
