import AppKit
import XCTest

@testable import Orbe

/// 提案タブのキー（入力欄の絞り込み欄と候補の一覧、カードの器の棚）。
///
/// 壊れると何が起きるか: 絞り込みに「x」を打つと候補が消える。入力を消そうと押した ⌘⌫（そのリピート）が候補を捨てる。
/// リンクを開くつもりの ⌘O が候補をタスクにする。⌘↵ でタスクになっても agent を開く画面が出ない、押し続けるとタスクが
/// いくつもできる。← で文字の間を動けない、または棚へ入れない。⇧⇥ で棚から焦点が逃げる。棚の ⌘↵ が候補の更新にならず
/// 候補をタスクにする。どこかの居場所の esc で画面が閉じない。棚で ↵ を押し続けると候補がタスクになる。
extension TaskPaletteCardKeyTests {
  private enum AutomationKey {
    static let o: UInt16 = 31
  }

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
  func testAutomationFieldTypesXAndCommandDeleteDismissesOnlyWhenEmpty() {
    let model = listedAutomationModel()
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

  /// ⌘O は選んでいる候補のリンクをブラウザで開くだけで、タスクにはしない。押し続けても 1 回だけ。
  func testAutomationCommandOOpensTheLinkOnceWithoutMakingATask() {
    let model = listedAutomationModel()
    var opened: [String] = []
    model.onOpenURL = { opened.append($0.absoluteString) }
    let window = mount(model)

    send(AutomationKey.o, "o", .command, to: window)
    send(AutomationKey.o, "o", .command, repeating: true, to: window)
    send(AutomationKey.o, "o", .command, repeating: true, to: window)

    XCTAssertEqual(opened, ["https://example.slack.com/archives/D01-1"])
    XCTAssertEqual(model.store.tasks.count, 1, "タスクにしない")
    XCTAssertEqual(model.automation.store.proposals[0].state, .open)
  }

  /// ⌘↵ は選んでいる候補を ↵ と同じくタスクにし、そのタスクの agent を開く口へ渡す。押し続けても 1 回だけ。
  func testAutomationCommandEnterMakesATaskAndOpensItOnceEvenWhenHeldDown() throws {
    let model = listedAutomationModel()
    var opened: [Int] = []
    model.onOpenWorktreePalette = { opened.append($0) }
    let window = mount(model)

    send(Key.enter, "\r", .command, to: window)
    send(Key.enter, "\r", .command, repeating: true, to: window)
    send(Key.enter, "\r", .command, repeating: true, to: window)

    let task = try XCTUnwrap(model.store.tasks.first { $0.title == "見積もりを山田さんに送る" })
    XCTAssertEqual(model.store.tasks.count, 2, "タスクは 1 つだけ")
    XCTAssertEqual(
      task.workspace, DesignSceneFixtures.taskWorkspaces.all[0].id, "↵ と同じく付け先に付く")
    XCTAssertEqual(model.automation.store.proposals[0].state, .accepted(taskId: task.id))
    XCTAssertEqual(model.automation.store.proposals[1].state, .open, "リピートで次の候補をさばかない")
    XCTAssertEqual(opened, [task.id])
  }

  /// 絞り込み欄の ↓ で棚、棚の ↓ で自動化を選び → で候補の一覧（先頭）、← で棚、↵ で同じ行、← と棚の先頭の ↑ で
  /// 絞り込み欄。文字があるときの ← は文字の間を動く。
  func testAutomationArrowsMoveBetweenFieldShelfAndProposals() {
    let model = automationModel()
    let window = mount(model)

    arrow(Key.down, to: window)
    XCTAssertEqual(model.automation.place, .shelf)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.automation.shelfList.selectedID, .automation(1))
    arrow(Key.right, to: window)
    XCTAssertEqual(model.automation.place, .proposals)
    XCTAssertEqual(model.automation.selectedProposal?.id, 1)
    arrow(Key.down, to: window)

    arrow(Key.left, to: window)
    XCTAssertEqual(model.automation.place, .shelf)
    XCTAssertNil(model.automation.selectedProposal, "棚に居る間は候補が選ばれていない")
    send(Key.enter, "\r", to: window)
    XCTAssertEqual(model.automation.selectedProposal?.id, 2, "覚えている行へ戻る")
    XCTAssertEqual(model.store.tasks.count, 1, "棚の ↵ は候補をタスクにしない")

    arrow(Key.left, to: window)
    arrow(Key.up, to: window)
    arrow(Key.up, to: window)
    XCTAssertEqual(model.automation.place, .field)
    type("a", into: window)
    arrow(Key.left, to: window)
    XCTAssertEqual(model.automation.place, .field, "文字があるときの ← は文字の間を動く")
  }

  /// 候補の一覧の → は何もしない（居場所も選んでいる行も変わらない）。
  func testAutomationRightArrowOnTheProposalsDoesNothing() {
    let model = listedAutomationModel()
    let window = mount(model)
    arrow(Key.down, to: window)

    arrow(Key.right, to: window)

    XCTAssertEqual(model.automation.place, .proposals)
    XCTAssertEqual(model.automation.selectedProposal?.id, 2)
    XCTAssertEqual(model.query, "")
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

  /// 棚の ⌘↵ は選んでいる自動化の候補を今すぐ更新し、候補には触れない。押し続けても断りの赤を出さない。
  func testAutomationCommandEnterOnTheShelfRefreshesTheAutomation() {
    let model = automationModel()
    let window = mount(model)
    arrow(Key.down, to: window)
    arrow(Key.down, to: window)

    send(Key.enter, "\r", .command, to: window)
    send(Key.enter, "\r", .command, repeating: true, to: window)

    XCTAssertTrue(model.automation.runner.isFlowing(1))
    XCTAssertNil(model.automation.error, "リピートで「更新中のため、今は更新できません」の赤を出さない")
    XCTAssertEqual(model.automation.place, .shelf)
    XCTAssertEqual(model.store.tasks.count, 1, "候補をタスクにしない")
  }

  /// 一覧に居る間に棚の段をクリックすると棚に居て、続く ⌘↵ は候補をタスクにせず、その自動化の更新になる。
  func testAutomationCommandEnterAfterClickingAShelfRowRefreshesTheAutomation() {
    let model = listedAutomationModel()
    let window = mount(model)

    model.automation.tapShelf(.automation(1))
    flush(window)
    send(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(model.automation.place, .shelf)
    XCTAssertTrue(model.automation.runner.isFlowing(1))
    XCTAssertEqual(model.store.tasks.count, 1, "候補をタスクにしない")
    XCTAssertEqual(model.automation.store.proposals.map(\.state), [.open, .open, .open])
  }

  /// esc はどの居場所でも画面を閉じる。
  func testAutomationEscapeClosesTheScreenFromEveryPlace() {
    for place: TaskPaletteAutomationPlace in [.field, .shelf, .proposals] {
      let model = automationModel()
      var dismissed = false
      model.onDismiss = { dismissed = true }
      let window = mount(model)
      switch place {
      case .field: break
      case .shelf: arrow(Key.down, to: window)
      case .proposals: model.automation.enterProposals()
      }
      flush(window)
      XCTAssertEqual(model.automation.place, place)

      send(Key.escape, "\u{1B}", to: window)

      XCTAssertTrue(dismissed, "\(place)")
    }
  }

  /// 選んでいる候補が別の口でさばかれたら、カードが付け直しへ届け、↵ が次の候補に効く（黙って何もしないにならない）。
  func testProposalHandledElsewhereMovesTheSelectionSoEnterStillWorks() throws {
    let model = listedAutomationModel()
    let window = mount(model)
    XCTAssertEqual(model.automation.proposalList.selectedID, 1)

    try model.automation.store.dismiss(1)
    flush(window)

    XCTAssertEqual(model.automation.proposalList.selectedID, 2)
    send(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.contains { $0.title == "オンボーディングの環境構築手順を見る" })
  }
}
