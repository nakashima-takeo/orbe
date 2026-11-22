import SwiftUI
import XCTest

@testable import Orbe

/// 提案タブのキー（入力欄の絞り込み欄と候補の一覧、カードの器の棚）。
extension TaskPaletteKeyTests {
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

  /// ⌘O は選んでいる候補のリンクをブラウザで開くだけで、タスクにはしない。押し続けても 1 回だけ。
  func testAutomationCommandOOpensTheLinkOnceWithoutMakingATask() {
    let model = listedAutomationModel()
    var opened: [String] = []
    model.onOpenURL = { opened.append($0.absoluteString) }

    send("o", .command, to: model)
    send("o", .command, repeating: true, to: model)
    send("o", .command, repeating: true, to: model)

    XCTAssertEqual(opened, ["https://example.slack.com/archives/D01-1"])
    XCTAssertEqual(model.store.tasks.count, 1, "タスクにしない")
    XCTAssertEqual(model.automation.store.proposals[0].state, .open)
  }

  /// ⌘↵ は選んでいる候補を ↵ と同じくタスクにし、そのタスクの agent を開く口へ渡す。押し続けても 1 回だけ。
  func testAutomationCommandEnterMakesATaskAndOpensItOnceEvenWhenHeldDown() throws {
    let model = listedAutomationModel()
    var opened: [Int] = []
    model.onOpenWorktreePalette = { opened.append($0) }

    send(.return, .command, to: model)
    send(.return, .command, repeating: true, to: model)
    send(.return, .command, repeating: true, to: model)

    let task = try XCTUnwrap(model.store.tasks.first { $0.title == "見積もりを山田さんに送る" })
    XCTAssertEqual(model.store.tasks.count, 2, "タスクは 1 つだけ")
    XCTAssertEqual(
      task.workspace, DesignSceneFixtures.taskWorkspaces.all[0].id, "↵ と同じく付け先に付く")
    XCTAssertEqual(try model.automation.store.decision(of: 1), .accepted(taskId: task.id))
    XCTAssertNil(try model.automation.store.decision(of: 2), "リピートで次の候補をさばかない")
    XCTAssertEqual(opened, [task.id])
  }

  /// 絞り込み欄の ↓ で棚、棚の ↓ で自動化を選び → で候補の一覧（先頭）、← で棚、↵ で同じ行、← と棚の先頭の ↑ で
  /// 絞り込み欄。文字があるときの ← は文字の間を動く。
  func testAutomationArrowsMoveBetweenFieldShelfAndProposals() {
    let model = automationModel()

    send(.downArrow, .command, to: model)
    XCTAssertEqual(model.automation.place, .field, "絞り込み欄の ⌘↓ は何もしない")
    send(.downArrow, to: model)
    XCTAssertEqual(model.automation.place, .shelf)
    send(.downArrow, to: model)
    XCTAssertEqual(model.automation.shelfList.selectedID, .automation(1))
    send(.rightArrow, to: model)
    XCTAssertEqual(model.automation.place, .proposals)
    XCTAssertEqual(model.automation.selectedProposal?.id, 1)
    send(.downArrow, to: model)

    send(.leftArrow, to: model)
    XCTAssertEqual(model.automation.place, .shelf)
    XCTAssertNil(model.automation.selectedProposal, "棚に居る間は候補が選ばれていない")
    send(.return, to: model)
    XCTAssertEqual(model.automation.selectedProposal?.id, 2, "覚えている行へ戻る")
    XCTAssertEqual(model.store.tasks.count, 1, "棚の ↵ は候補をタスクにしない")

    send(.leftArrow, to: model)
    send(.upArrow, to: model)
    send(.upArrow, to: model)
    XCTAssertEqual(model.automation.place, .field)
    model.query = "a"
    send(.leftArrow, to: model, expect: .ignored)
    XCTAssertEqual(model.automation.place, .field, "文字があるときの ← は文字の間を動く")
  }

  /// 候補の一覧の → は何もしない（居場所も選んでいる行も変わらない）。
  func testAutomationRightArrowOnTheProposalsDoesNothing() {
    let model = listedAutomationModel()
    send(.downArrow, to: model)

    send(.rightArrow, to: model, expect: .ignored)

    XCTAssertEqual(model.automation.place, .proposals)
    XCTAssertEqual(model.automation.selectedProposal?.id, 2)
    XCTAssertEqual(model.query, "")
  }

  /// 棚の ⌘↵ は選んでいる自動化の候補を今すぐ更新し、候補には触れない。押し続けても断りの赤を出さない。
  func testAutomationCommandEnterOnTheShelfRefreshesTheAutomation() {
    let model = automationModel()
    send(.downArrow, to: model)
    send(.downArrow, to: model)

    send(.return, .command, to: model)
    send(.return, .command, repeating: true, to: model)

    XCTAssertTrue(model.automation.runner.isFlowing(1))
    XCTAssertNil(model.automation.error, "リピートで「更新中のため、今は更新できません」の赤を出さない")
    XCTAssertEqual(model.automation.place, .shelf)
    XCTAssertEqual(model.store.tasks.count, 1, "候補をタスクにしない")
  }

  /// 一覧に居る間に棚の段をクリックすると棚に居て、続く ⌘↵ は候補をタスクにせず、その自動化の更新になる。
  func testAutomationCommandEnterAfterClickingAShelfRowRefreshesTheAutomation() {
    let model = listedAutomationModel()

    model.automation.tapShelf(.automation(1))
    send(.return, .command, to: model)

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
      switch place {
      case .field: break
      case .shelf: send(.downArrow, to: model)
      case .proposals: model.automation.enterProposals()
      }
      XCTAssertEqual(model.automation.place, place)

      send(.escape, to: model)

      XCTAssertTrue(dismissed, "\(place)")
    }
  }
}
