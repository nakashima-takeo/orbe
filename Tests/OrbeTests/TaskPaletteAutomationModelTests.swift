import XCTest

@testable import Orbe

/// ⌘⇧X の受信タブ——棚と提案の一覧を同一性で選び、居場所（提案の一覧・棚・中身）を移り、提案をタスクにする・捨てる、受信を
/// 今すぐ実行・止める・消す。本物の `AutomationStore`・`AutomationRunner`・`TaskStore` を読み書きする（取得は始まっても終わらない）。
///
/// 壊れると何が起きるか。↵ や ⌘⌫ が光っている行とは別の提案に当たる（タスクにした・捨てた直後や、裏の回が確定した直後）。
/// タスクにした提案が Home に付かず、期限やリンクを失う。消えた受信の中身が残り、⌘⌫ が別の受信を消す。
/// 走っている受信の今すぐ実行が黙って無視される。
@MainActor
final class TaskPaletteAutomationModelTests: OrbeTestCase {
  func palette() -> TaskPaletteModel {
    let palette = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a")],
      automations: DesignSceneFixtures.automationRunner(DesignSceneFixtures.automationDesignFile()))
    palette.setTab(.automation)
    return palette
  }

  // MARK: - 行

  func testOpeningShowsAllAndEveryOpenProposalNewestRunFirst() {
    let automation = palette().automation

    XCTAssertEqual(
      automation.shelfIDs, [.all, .automation(1), .automation(2), .automation(3), .automation(4)])
    XCTAssertEqual(automation.shelfRows.map(\.count), [3, 2, 1, 0, 0])
    XCTAssertEqual(automation.shelfList.selectedID, .all)
    XCTAssertEqual(automation.proposalIDs, [1, 2, 3], "同じ回の中は判定の出力順")
    XCTAssertEqual(automation.proposalList.selectedID, 1)
    XCTAssertEqual(automation.place, .proposals)
  }

  func testProposalsOfALaterRunComeFirst() throws {
    let runner = DesignSceneFixtures.automationRunner(DesignSceneFixtures.automationDesignFile())
    let item = DesignSceneFixtures.automationItem(
      "C03-9", "後の回", at: DesignSceneFixtures.automationNow)
    AutomationStoreTests.commit(
      runner.store, 2,
      DesignSceneFixtures.automationRun(
        at: DesignSceneFixtures.automationNow, items: 3, fresh: 1),
      fetched: runner.store.automation(2)!.lastFetched.map {
        AutomationItem(id: $0.id, link: $0.link, body: "", time: DesignSceneFixtures.automationNow)
      } + [item], decisions: [.propose(itemId: "C03-9", title: "後の提案", due: nil)])
    let palette = TaskPaletteSamples.model([], automations: runner)

    XCTAssertEqual(palette.automation.proposalIDs, [4, 1, 2, 3])
  }

  func testShelfSelectionFiltersProposalsAndSelectsTheFirst() {
    let automation = palette().automation
    automation.moveProposal(1)

    automation.moveShelf(1)
    XCTAssertEqual(automation.shelfList.selectedID, .automation(1))
    XCTAssertEqual(automation.proposalIDs, [1, 2])
    XCTAssertEqual(automation.proposalList.selectedID, 1)

    automation.tapShelf(.automation(2))
    XCTAssertEqual(automation.proposalIDs, [3], "棚に出る受信で絞る（重ねて取っているリンクは提案した受信の棚）")
  }

  func testQueryMatchesTitleOrBodyAndDoesNotChangeTheTabCount() {
    let palette = palette()

    palette.query = "週報"
    XCTAssertEqual(palette.automation.proposalIDs, [3], "本文に一致")
    palette.query = "オンボーディング"
    XCTAssertEqual(palette.automation.proposalIDs, [2], "タイトルに一致")
    XCTAssertEqual(palette.automation.proposalList.selectedID, 2)
    XCTAssertEqual(palette.automation.openCount, 3)
  }

  // MARK: - さばく

  /// 範囲を Home 以外の workspace に絞っていても、位置は足すタスクが付く Home の欄で決まる（高い優先度を越えない）。
  func testEnterWhileScopedToAnotherWorkspacePlacesTheTaskInHomesColumn() throws {
    let opened = TaskPaletteSamples.opened.id
    let home = TaskPaletteSamples.home
    let palette = TaskPaletteSamples.model(
      [
        TaskPaletteSamples.task(1, "X") { $0.workspace = opened },
        TaskPaletteSamples.task(2, "Home 高") {
          $0.workspace = home
          $0.priority = .high
        },
        TaskPaletteSamples.task(3, "Home 中") { $0.workspace = home },
      ],
      automations: DesignSceneFixtures.automationRunner(DesignSceneFixtures.automationDesignFile()))
    palette.setScope(.opened)
    palette.setTab(.automation)

    palette.submit()

    let added = try XCTUnwrap(palette.store.tasks.first { $0.id > 3 }).id
    XCTAssertEqual(palette.store.tasks.map(\.id), [1, 2, added, 3])
  }

  /// ⌘⇧X で人が受けて足すタスクなので、入力欄から足すのと同じく、その優先度の未着手の先頭に入る。
  func testEnterMakesATodoTaskOnHomeAtTheHeadOfMediumAndSelectsTheSamePosition() throws {
    let palette = palette()
    let tasks = palette.store.tasks.count

    palette.submit()

    let task = try XCTUnwrap(palette.store.tasks.first { $0.title == "見積もりを山田さんに送る" })
    XCTAssertEqual(palette.store.tasks.count, tasks + 1)
    XCTAssertEqual(
      palette.store.tasks.firstIndex { $0.status == .todo && $0.priority != .high }.map {
        palette.store.tasks[$0].id
      }, task.id, "未着手の中の先頭")
    XCTAssertEqual(task.title, "見積もりを山田さんに送る")
    XCTAssertEqual(task.status, .todo)
    XCTAssertEqual(task.due, TaskItem.DueDate("2025-10-10"))
    XCTAssertEqual(task.workspace, TaskPaletteSamples.home, "Home に付く")
    XCTAssertTrue(task.description.hasPrefix("https://example.slack.com/archives/D01-1\n\n"))
    XCTAssertEqual(palette.automation.store.proposals[0].state, .accepted(taskId: task.id))
    XCTAssertEqual(palette.automation.proposalIDs, [2, 3])
    XCTAssertEqual(palette.automation.proposalList.selectedID, 2)
    XCTAssertNil(palette.automation.error)
  }

  func testDismissMakesNoTaskAndSelectsTheSamePosition() {
    let palette = palette()
    palette.automation.moveProposal(1)

    palette.automation.dismiss()

    XCTAssertEqual(palette.store.tasks.count, 1)
    XCTAssertEqual(palette.automation.store.proposals[1].state, .dismissed)
    XCTAssertEqual(palette.automation.proposalIDs, [1, 3])
    XCTAssertEqual(palette.automation.proposalList.selectedID, 3)
  }

  /// 選んでいる提案が付け直しの前にさばかれていた（判定の確定や別の口と行き違った）なら、↵ は何もせず赤も出さない。
  func testEnterOnAProposalThatIsNoLongerOpenDoesNothing() throws {
    let palette = palette()
    try palette.automation.store.dismiss(1)

    palette.submit()

    XCTAssertNil(palette.automation.error)
    XCTAssertEqual(palette.store.tasks.count, 1, "タスクは足さない")
  }

  func testOpenLinkOpensTheProposalLink() {
    let palette = palette()
    var opened: [URL] = []
    palette.onOpenURL = { opened.append($0) }

    palette.automation.openLink()

    XCTAssertEqual(opened, [URL(string: "https://example.slack.com/archives/D01-1")!])
  }

  // MARK: - 居場所

  func testPlacesAndFocus() {
    let palette = palette()
    let automation = palette.automation
    XCTAssertEqual(palette.focusTarget, .field)

    automation.enterContents()
    XCTAssertEqual(automation.place, .proposals, "「すべて」に中身は無い")

    automation.enterShelf()
    XCTAssertEqual(palette.focusTarget, .card)
    automation.moveShelf(1)
    automation.showProposals()
    automation.enterContents()
    XCTAssertEqual(automation.place, .contents)
    XCTAssertEqual(palette.focusTarget, .card)

    palette.returnToField()
    XCTAssertEqual(automation.place, .proposals)
    XCTAssertEqual(palette.focusTarget, .field)
  }

  func testSwitchingTabsKeepsTheAutomationState() {
    let palette = palette()
    palette.automation.tapShelf(.automation(2))

    palette.setTab(.tasks)
    palette.setTab(.automation)

    XCTAssertEqual(palette.automation.shelfList.selectedID, .automation(2))
  }

  // MARK: - 受信の中身

  func testRunNowShowsRunningAndRefusesWhileRunning() {
    let automation = palette().automation
    automation.tapShelf(.automation(1))
    automation.enterContents()

    automation.perform(.runNow)
    XCTAssertTrue(automation.isRunning(automation.selectedAutomation!))
    XCTAssertNil(automation.error)

    automation.perform(.runNow)
    XCTAssertEqual(automation.error, .refused(.running), "走っている間は赤で断る")
  }

  /// 受信タブの赤は、タブを替えた操作の境目で消える（戻ったときに当てはまらない赤が残らない）。
  func testLeavingTheTabClearsItsError() {
    let palette = palette()
    palette.automation.tapShelf(.automation(1))
    palette.automation.enterContents()
    palette.automation.perform(.runNow)
    palette.automation.perform(.runNow)
    XCTAssertEqual(palette.automation.error, .refused(.running))

    palette.setTab(.tasks)
    palette.setTab(.automation)

    XCTAssertNil(palette.automation.error)
  }

  func testSpaceTogglesPause() {
    let automation = palette().automation
    automation.tapShelf(.automation(4))

    automation.perform(.togglePause)
    XCTAssertEqual(automation.selectedAutomation?.paused, false)
    XCTAssertNotNil(automation.nextRunAt(automation.selectedAutomation!), "再開すれば次の時刻が出る")
    automation.perform(.togglePause)
    XCTAssertEqual(automation.selectedAutomation?.paused, true)
  }

  func testDeleteReturnsToProposalsAndSelectsTheSameShelfPosition() {
    let automation = palette().automation
    automation.tapShelf(.automation(2))
    automation.enterContents()

    automation.perform(.delete)

    XCTAssertNil(automation.store.automation(2))
    XCTAssertEqual(automation.place, .proposals)
    XCTAssertEqual(automation.shelfList.selectedID, .automation(3))
  }
}
