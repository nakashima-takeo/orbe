import XCTest

@testable import Orbe

/// ⌘⇧X の受信タブ——棚と提案の一覧を同一性で選び、居場所（提案の一覧・棚・中身）を移り、提案をタスクにする・捨てる、受信を
/// 今すぐ受信・止める・消す。本物の `IntakeStore`・`IntakeRunner`・`TaskStore` を読み書きする（取得は始まっても終わらない）。
///
/// 壊れると何が起きるか。↵ や ⌘⌫ が光っている行とは別の提案に当たる（タスクにした・捨てた直後や、裏の回が確定した直後）。
/// タスクにした提案が Home に付かず、期限やリンクを失う。消えた受信の中身が残り、⌘⌫ が別の受信を消す。
/// 走っている受信の今すぐ受信が黙って無視される。
@MainActor
final class TaskPaletteIntakeModelTests: OrbeTestCase {
  func palette() -> TaskPaletteModel {
    let palette = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a")],
      intakes: DesignSceneFixtures.intakeRunner(DesignSceneFixtures.intakeDesignFile()))
    palette.setTab(.intake)
    return palette
  }

  // MARK: - 行

  func testOpeningShowsAllAndEveryOpenProposalNewestRunFirst() {
    let intake = palette().intake

    XCTAssertEqual(intake.shelfIDs, [.all, .intake(1), .intake(2), .intake(3), .intake(4)])
    XCTAssertEqual(intake.shelfRows.map(\.count), [3, 2, 1, 0, 0])
    XCTAssertEqual(intake.shelfList.selectedID, .all)
    XCTAssertEqual(intake.proposalIDs, [1, 2, 3], "同じ回の中は判定の出力順")
    XCTAssertEqual(intake.proposalList.selectedID, 1)
    XCTAssertEqual(intake.place, .proposals)
  }

  func testProposalsOfALaterRunComeFirst() throws {
    let runner = DesignSceneFixtures.intakeRunner(DesignSceneFixtures.intakeDesignFile())
    let item = DesignSceneFixtures.intakeItem("C03-9", "後の回", at: DesignSceneFixtures.intakeNow)
    runner.store.commit(
      2, DesignSceneFixtures.intakeRun(at: DesignSceneFixtures.intakeNow, items: 3, newItems: 1),
      fetched: runner.store.intake(2)!.lastFetched.map {
        IntakeItem(id: $0.id, link: $0.link, body: "", time: DesignSceneFixtures.intakeNow)
      } + [item], judged: [item], decisions: [.propose(itemId: "C03-9", title: "後の提案", due: nil)])
    let palette = TaskPaletteSamples.model([], intakes: runner)

    XCTAssertEqual(palette.intake.proposalIDs, [4, 1, 2, 3])
  }

  func testShelfSelectionFiltersProposalsAndSelectsTheFirst() {
    let intake = palette().intake
    intake.moveProposal(1)

    intake.moveShelf(1)
    XCTAssertEqual(intake.shelfList.selectedID, .intake(1))
    XCTAssertEqual(intake.proposalIDs, [1, 2])
    XCTAssertEqual(intake.proposalList.selectedID, 1)

    intake.tapShelf(.intake(2))
    XCTAssertEqual(intake.proposalIDs, [3], "棚に出る受信で絞る（重ねて取っているリンクは提案した受信の棚）")
  }

  func testQueryMatchesTitleOrBodyAndDoesNotChangeTheTabCount() {
    let palette = palette()

    palette.query = "週報"
    XCTAssertEqual(palette.intake.proposalIDs, [3], "本文に一致")
    palette.query = "オンボーディング"
    XCTAssertEqual(palette.intake.proposalIDs, [2], "タイトルに一致")
    XCTAssertEqual(palette.intake.proposalList.selectedID, 2)
    XCTAssertEqual(palette.intake.openCount, 3)
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
      intakes: DesignSceneFixtures.intakeRunner(DesignSceneFixtures.intakeDesignFile()))
    palette.setScope(.opened)
    palette.setTab(.intake)

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
    XCTAssertEqual(palette.intake.store.proposals[0].state, .accepted(taskId: task.id))
    XCTAssertEqual(palette.intake.proposalIDs, [2, 3])
    XCTAssertEqual(palette.intake.proposalList.selectedID, 2)
    XCTAssertNil(palette.intake.error)
  }

  func testDismissMakesNoTaskAndSelectsTheSamePosition() {
    let palette = palette()
    palette.intake.moveProposal(1)

    palette.intake.dismiss()

    XCTAssertEqual(palette.store.tasks.count, 1)
    XCTAssertEqual(palette.intake.store.proposals[1].state, .dismissed)
    XCTAssertEqual(palette.intake.proposalIDs, [1, 3])
    XCTAssertEqual(palette.intake.proposalList.selectedID, 3)
  }

  /// 選んでいる提案が付け直しの前にさばかれていた（判定の確定や別の口と行き違った）なら、↵ は何もせず赤も出さない。
  func testEnterOnAProposalThatIsNoLongerOpenDoesNothing() throws {
    let palette = palette()
    try palette.intake.store.dismiss(1)

    palette.submit()

    XCTAssertNil(palette.intake.error)
    XCTAssertEqual(palette.store.tasks.count, 1, "タスクは足さない")
  }

  func testOpenLinkOpensTheProposalLink() {
    let palette = palette()
    var opened: [URL] = []
    palette.onOpenURL = { opened.append($0) }

    palette.intake.openLink()

    XCTAssertEqual(opened, [URL(string: "https://example.slack.com/archives/D01-1")!])
  }

  // MARK: - 居場所

  func testPlacesAndFocus() {
    let palette = palette()
    let intake = palette.intake
    XCTAssertEqual(palette.focusTarget, .field)

    intake.enterContents()
    XCTAssertEqual(intake.place, .proposals, "「すべて」に中身は無い")

    intake.enterShelf()
    XCTAssertEqual(palette.focusTarget, .card)
    intake.moveShelf(1)
    intake.showProposals()
    intake.enterContents()
    XCTAssertEqual(intake.place, .contents)
    XCTAssertEqual(palette.focusTarget, .card)

    palette.returnToField()
    XCTAssertEqual(intake.place, .proposals)
    XCTAssertEqual(palette.focusTarget, .field)
  }

  func testSwitchingTabsKeepsTheIntakeState() {
    let palette = palette()
    palette.intake.tapShelf(.intake(2))

    palette.setTab(.tasks)
    palette.setTab(.intake)

    XCTAssertEqual(palette.intake.shelfList.selectedID, .intake(2))
  }

  // MARK: - 受信の中身

  func testRunNowShowsRunningAndRefusesWhileRunning() {
    let intake = palette().intake
    intake.tapShelf(.intake(1))
    intake.enterContents()

    intake.runNow()
    XCTAssertTrue(intake.isRunning(intake.selectedIntake!))
    XCTAssertNil(intake.error)

    intake.runNow()
    XCTAssertEqual(intake.error, .running, "走っている間は赤で断る")
  }

  /// 受信タブの赤は、タブを替えた操作の境目で消える（戻ったときに当てはまらない赤が残らない）。
  func testLeavingTheTabClearsItsError() {
    let palette = palette()
    palette.intake.tapShelf(.intake(1))
    palette.intake.enterContents()
    palette.intake.runNow()
    palette.intake.runNow()
    XCTAssertEqual(palette.intake.error, .running)

    palette.setTab(.tasks)
    palette.setTab(.intake)

    XCTAssertNil(palette.intake.error)
  }

  func testSpaceTogglesPause() {
    let intake = palette().intake
    intake.tapShelf(.intake(4))

    intake.togglePause()
    XCTAssertEqual(intake.selectedIntake?.paused, false)
    XCTAssertNotNil(intake.nextRunAt(intake.selectedIntake!), "再開すれば次の時刻が出る")
    intake.togglePause()
    XCTAssertEqual(intake.selectedIntake?.paused, true)
  }

  func testDeleteReturnsToProposalsAndSelectsTheSameShelfPosition() {
    let intake = palette().intake
    intake.tapShelf(.intake(2))
    intake.enterContents()

    intake.deleteIntake()

    XCTAssertNil(intake.store.intake(2))
    XCTAssertEqual(intake.place, .proposals)
    XCTAssertEqual(intake.shelfList.selectedID, .intake(3))
  }
}
