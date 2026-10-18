import XCTest

@testable import Orbe

/// ⌘⇧X の提案タブ——棚と候補の一覧を同一性で選び、居場所（絞り込み欄・棚・候補の一覧）を移り、候補をタスクにする・捨てる、
/// 自動化の候補を今すぐ更新する。本物の `AutomationStore`・`AutomationRunner`・`TaskStore` を読み書きする（部品の回は始まっても
/// 終わらない）。
///
/// 壊れると何が起きるか。↵ や ⌘⌫ が光っている行とは別の候補に当たる（タスクにした・捨てた直後や、裏の回が確定した直後）。
/// 印の無い候補が絞り込み欄の ↵ でタスクになる。タスクにした候補が付け先（無ければ Home）に付かず、期限やリンクを失う。
/// 開いている間に消えた付け先に付き、行き場の無いタスクになる。更新中の自動化の ⌘↵ が黙って無視される。棚の 2 行目が
/// 次に候補が来うる時を言わない。
@MainActor
final class TaskPaletteAutomationModelTests: OrbeTestCase {
  func palette() -> TaskPaletteModel {
    let palette = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a")],
      automations: DesignSceneFixtures.automationRunner(
        DesignSceneFixtures.automationDesignSamples()),
      workspaces: { DesignSceneFixtures.taskWorkspaces })
    palette.setTab(.automation)
    return palette
  }

  /// 候補の一覧に居る提案タブ。
  func listed() -> TaskPaletteModel {
    let palette = palette()
    palette.automation.enterProposals()
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
    XCTAssertEqual(automation.proposalList.selectedID, 1, "覚えている行は先頭")
    XCTAssertEqual(automation.place, .field)
    XCTAssertNil(automation.selectedProposal, "開いた直後は候補が選ばれていない")
  }

  /// 棚は判定の部品を持つ自動化だけを並べる。副作用のコマンドで終わる自動化は候補を出さないので出さない。
  func testTheShelfListsOnlyTaskCandidateAutomations() throws {
    let runner = DesignSceneFixtures.automationRunner(DesignSceneFixtures.automationDesignSamples())
    var command = runner.store.automation(4)!.definition
    command.parts[1] = DesignSceneFixtures.commandPart(
      "judge", "投稿", .arrival, from: ["fetch"], script: "cat", deliver: .sideEffect)
    _ = try runner.set(4, command)
    let palette = TaskPaletteSamples.model([], automations: runner)

    XCTAssertEqual(
      palette.automation.shelfIDs, [.all, .automation(1), .automation(2), .automation(3)])
  }

  func testProposalsOfALaterRunComeFirst() throws {
    let runner = DesignSceneFixtures.automationRunner(DesignSceneFixtures.automationDesignSamples())
    let item = DesignSceneFixtures.automationItem(
      "C03-9", "後の回", at: DesignSceneFixtures.automationNow)
    let fetched = runner.store.automation(2)!.state("fetch").lastOutput.map {
      AutomationItem(id: $0.id, link: $0.link, body: "", time: DesignSceneFixtures.automationNow)
    }
    try WindowControllerAutomationControlTests.round(
      runner.store, 2, fetched: fetched + [item], proposing: [item], titles: ["後の提案"])
    let palette = TaskPaletteSamples.model([], automations: runner)

    XCTAssertEqual(palette.automation.proposalIDs, [4, 1, 2, 3])
  }

  func testShelfSelectionFiltersProposalsAndSelectsTheFirst() {
    let automation = listed().automation
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

  func testEnterMakesATodoTaskOnTheProposalsWorkspaceAndSelectsTheSamePosition() throws {
    let palette = listed()
    let tasks = palette.store.tasks.count

    palette.submit()

    let task = try XCTUnwrap(palette.store.tasks.first { $0.title == "見積もりを山田さんに送る" })
    XCTAssertEqual(palette.store.tasks.count, tasks + 1)
    XCTAssertEqual(task.title, "見積もりを山田さんに送る")
    XCTAssertEqual(task.status, .todo)
    XCTAssertEqual(task.due, TaskItem.DueDate("2025-10-10"))
    XCTAssertEqual(task.workspace, DesignSceneFixtures.taskWorkspaces.all[0].id, "付け先に付く")
    XCTAssertTrue(task.description.hasPrefix("https://example.slack.com/archives/D01-1\n\n"))
    XCTAssertEqual(palette.automation.store.proposals[0].state, .accepted(taskId: task.id))
    XCTAssertEqual(palette.automation.proposalIDs, [2, 3])
    XCTAssertEqual(palette.automation.proposalList.selectedID, 2)
    XCTAssertNil(palette.automation.error)

    palette.submit()

    let homeTask = try XCTUnwrap(
      palette.store.tasks.first { $0.title == "オンボーディングの環境構築手順を見る" })
    XCTAssertEqual(
      homeTask.workspace, DesignSceneFixtures.taskWorkspaces.home, "付け先を持たない提案は Home に付く")
  }

  /// 付け先は今の workspace で解く。解ければそこ、付け先が無いか解けなければ Home。詳細の表示と ↵ が同じ付け先を使う。
  func testEnterAttachesTheTaskToTheProposalsWorkspaceOrElseHome() throws {
    let runner = DesignSceneFixtures.automationRunner(
      DesignSceneFixtures.automationDesignSamples(
        workspaces: [TaskPaletteSamples.other.id, nil, UUID()]))
    let proposals = runner.store.proposals
    let palette = TaskPaletteSamples.model([], automations: runner)
    palette.setTab(.automation)
    let automation = palette.automation
    automation.enterProposals()

    XCTAssertEqual(
      automation.proposals.map { automation.destination(of: $0)?.name },
      ["web-app", "Home", "Home"])
    for _ in proposals { automation.accept() }

    XCTAssertEqual(
      proposals.map { proposal in
        palette.store.tasks.first { $0.title == proposal.title }?.workspace
      },
      [TaskPaletteSamples.other.id, TaskPaletteSamples.home, TaskPaletteSamples.home])
  }

  /// 付け先は開いた時点の写しではなく ↵ の時点の値で解く。開いている間に付け先が消えたら Home に付く。
  func testEnterUsesTheWorkspacesAtThatMomentNotWhenOpened() throws {
    var current = TaskPaletteSamples.workspaces
    let palette = TaskPaletteSamples.model(
      [],
      automations: DesignSceneFixtures.automationRunner(
        DesignSceneFixtures.automationDesignSamples(
          workspaces: [TaskPaletteSamples.other.id, nil, nil])),
      workspaces: { current })
    palette.setTab(.automation)
    palette.automation.enterProposals()
    let proposal = try XCTUnwrap(palette.automation.selectedProposal)
    XCTAssertEqual(palette.automation.destination(of: proposal)?.name, "web-app")

    current = TaskPaletteWorkspaces(
      opened: current.opened, all: current.all.filter { $0 != TaskPaletteSamples.other },
      home: current.home)
    palette.automation.accept()

    XCTAssertEqual(palette.store.tasks.first?.workspace, TaskPaletteSamples.home)
  }

  func testDismissMakesNoTaskAndSelectsTheSamePosition() {
    let palette = listed()
    palette.automation.moveProposal(1)

    palette.automation.dismiss()

    XCTAssertEqual(palette.store.tasks.count, 1)
    XCTAssertEqual(palette.automation.store.proposals[1].state, .dismissed)
    XCTAssertEqual(palette.automation.proposalIDs, [1, 3])
    XCTAssertEqual(palette.automation.proposalList.selectedID, 3)
  }

  /// 選んでいる提案が付け直しの前にさばかれていた（判定の確定や別の口と行き違った）なら、↵ は何もせず赤も出さない。
  func testEnterOnAProposalThatIsNoLongerOpenDoesNothing() throws {
    let palette = listed()
    try palette.automation.store.dismiss(1)

    palette.submit()

    XCTAssertNil(palette.automation.error)
    XCTAssertEqual(palette.store.tasks.count, 1, "タスクは足さない")
  }

  /// タスクのストアが断ったら、タスクにならず agent も開かず、赤を出す。
  func testAcceptAndOpenRefusedByTheTaskStoreOpensNothing() {
    let palette = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a")],
      automations: DesignSceneFixtures.automationRunner(
        DesignSceneFixtures.automationDesignSamples(estimateTitle: "改行\nを含む")))
    palette.setTab(.automation)
    palette.automation.enterProposals()
    var opened: [Int] = []
    palette.onOpenWorktreePalette = { opened.append($0) }

    palette.automation.acceptAndOpen()

    XCTAssertEqual(palette.store.tasks.count, 1, "タスクは足さない")
    XCTAssertEqual(palette.automation.store.proposals[0].state, .open)
    XCTAssertEqual(palette.automation.error, .accept)
    XCTAssertEqual(opened, [])
  }

  func testOpenLinkOpensTheProposalLink() {
    let palette = listed()
    var opened: [URL] = []
    palette.onOpenURL = { opened.append($0) }

    palette.automation.openLink()

    XCTAssertEqual(opened, [URL(string: "https://example.slack.com/archives/D01-1")!])
  }

  /// 絞り込み欄と棚では、覚えている行は選ばれていないので、↵・⌘↵・⌘⌫・⌘O は候補に効かない。
  func testProposalKeysDoNothingOutsideTheList() {
    let palette = palette()
    var opened: [URL] = []
    palette.onOpenURL = { opened.append($0) }
    let automation = palette.automation

    for place in [automation.enterField, automation.enterShelf] {
      place()
      palette.submit()
      automation.acceptAndOpen()
      automation.dismiss()
      automation.openLink()
    }

    XCTAssertEqual(palette.store.tasks.count, 1, "タスクは足さない")
    XCTAssertEqual(automation.store.proposals.map(\.state), [.open, .open, .open])
    XCTAssertEqual(opened, [])
  }

  // MARK: - 居場所

  func testPlacesAndFocus() {
    let palette = palette()
    let automation = palette.automation
    XCTAssertEqual(palette.focusTarget, .field)

    automation.enterShelf()
    XCTAssertEqual(palette.focusTarget, .card)
    automation.moveShelf(1)
    automation.enterProposals()
    XCTAssertEqual(automation.place, .proposals)
    XCTAssertEqual(palette.focusTarget, .field)
    XCTAssertEqual(automation.selectedProposal?.id, 1)

    automation.enterShelf()
    palette.returnToField()
    XCTAssertEqual(automation.place, .field, "棚から入力欄のクリックで絞り込み欄へ")
    XCTAssertEqual(palette.focusTarget, .field)
  }

  /// 棚は端で巡回しない。先頭の ↑ は絞り込み欄へ戻り、末尾の ↓ はそこで止まる。
  func testTheShelfStopsAtItsEndsAndItsTopLeadsToTheField() {
    let automation = palette().automation
    automation.enterShelf()

    automation.moveShelf(-1)
    XCTAssertEqual(automation.place, .field)
    XCTAssertEqual(automation.shelfList.selectedID, .all)

    automation.enterShelf()
    automation.jumpShelf(1)
    automation.moveShelf(1)
    XCTAssertEqual(automation.shelfList.selectedID, .automation(4))
    XCTAssertEqual(automation.place, .shelf)
  }

  /// 候補の一覧の位置は覚えて戻る。棚の段を替えたらその段の先頭。
  func testTheListRemembersItsRowAcrossTheShelf() {
    let automation = listed().automation
    automation.moveProposal(1)

    automation.enterShelf()
    XCTAssertNil(automation.selectedProposal)
    automation.enterProposals()
    XCTAssertEqual(automation.selectedProposal?.id, 2)

    automation.enterShelf()
    automation.moveShelf(1)
    automation.enterProposals()
    XCTAssertEqual(automation.selectedProposal?.id, 1)
  }

  /// 棚の端の ⌘↑ / ⌘↓ で段が変わらなければ、覚えている行は残る。
  func testJumpingTheShelfWithoutChangingTheRowKeepsTheRememberedRow() throws {
    let automation = listed().automation
    automation.moveProposal(1)
    automation.enterShelf()

    automation.jumpShelf(-1)
    automation.enterProposals()
    XCTAssertEqual(automation.selectedProposal?.id, 2, "先頭の段で ⌘↑")

    for id in [2, 3, 4] { try automation.runner.delete(id) }
    automation.reconcile()
    automation.tapShelf(.automation(1))
    automation.moveProposal(1)
    automation.enterShelf()
    automation.jumpShelf(1)
    automation.enterProposals()
    XCTAssertEqual(automation.shelfList.selectedID, .automation(1), "前提: 末尾の段")
    XCTAssertEqual(automation.selectedProposal?.id, 2, "末尾の段で ⌘↓")
  }

  func testSwitchingTabsKeepsTheAutomationState() {
    let palette = palette()
    palette.automation.tapShelf(.automation(2))

    palette.setTab(.tasks)
    palette.setTab(.automation)

    XCTAssertEqual(palette.automation.shelfList.selectedID, .automation(2))
    XCTAssertEqual(palette.automation.place, .proposals)
  }

  // MARK: - 出どころ

  /// 候補の出どころの部品の名前は、候補を出した自動化の定義から引く。消えた自動化の候補は引けない。
  func testSourceNameComesFromTheProposingAutomation() {
    let palette = TaskPaletteSamples.model(
      [],
      automations: DesignSceneFixtures.automationRunner(
        DesignSceneFixtures.automationShelfSamples()))
    let automation = palette.automation
    automation.tapShelf(.automation(1))

    XCTAssertEqual(
      automation.proposals.map(automation.sourceName(of:)), ["GitHub", "Backlog", nil])
  }
}
