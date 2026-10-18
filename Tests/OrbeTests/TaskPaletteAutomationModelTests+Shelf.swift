import XCTest

@testable import Orbe

/// 提案タブの棚——候補の今すぐ更新（⌘↵）と、棚の段の 2 行目。
extension TaskPaletteAutomationModelTests {
  // MARK: - 候補の更新

  /// ⌘↵ はタスク候補を行き先にする部品まで流し、一巡の間は棚が更新中になり、もう一度の ⌘↵ は赤で断る。
  func testRefreshShowsRefreshingAndRefusesWhileRefreshing() {
    let automation = palette().automation
    automation.enterShelf()
    automation.moveShelf(1)

    automation.refresh()
    let selected = automation.selectedAutomation!
    XCTAssertTrue(automation.runner.isFlowing(selected.id))
    XCTAssertEqual(automation.status(of: selected, count: 2), .refreshing)
    XCTAssertNil(automation.error)

    automation.refresh()
    XCTAssertEqual(automation.error, .refreshing, "流している途中は赤で断る")
  }

  func testRefreshOnAllDoesNothing() {
    let automation = palette().automation
    automation.enterShelf()

    automation.refresh()

    XCTAssertFalse(automation.store.automations.contains { automation.runner.isFlowing($0.id) })
    XCTAssertNil(automation.error)
  }

  /// 候補の更新は判定へ至る部品だけを走らせ、判定へ至らない枝（副作用・報告）は走らせない。
  func testRefreshRunsOnlyThePartsLeadingToTheJudges() throws {
    let runner = DesignSceneFixtures.automationRunner()
    let id = try runner.set(
      nil,
      AutomationDefinition(
        name: "候補と投稿", notify: nil,
        parts: [
          DesignSceneFixtures.commandPart(
            "fetch", "GitHub", .manual, script: "gh", coverage: .newArrivals),
          DesignSceneFixtures.agentPart(
            "judge", "判定", .arrival, from: ["fetch"], instruction: "i", deliver: .taskCandidates),
          DesignSceneFixtures.commandPart(
            "log", "ログ", .manual, script: "log", coverage: .newArrivals),
          DesignSceneFixtures.commandPart(
            "post", "投稿", .arrival, from: ["log"], script: "post", deliver: .sideEffect),
        ])
    ).id
    let palette = TaskPaletteSamples.model([], automations: runner)
    palette.setTab(.automation)
    palette.automation.tapShelf(.automation(id))

    palette.automation.refresh()

    XCTAssertTrue(runner.isRunning(id, "fetch"))
    XCTAssertFalse(runner.isRunning(id, "log"), "副作用の枝の取得は走らない")
  }

  /// 提案タブの赤は、タブを替えた操作の境目で消える（戻ったときに当てはまらない赤が残らない）。
  func testLeavingTheTabClearsItsError() {
    let palette = palette()
    palette.automation.enterShelf()
    palette.automation.moveShelf(1)
    palette.automation.refresh()
    palette.automation.refresh()
    XCTAssertEqual(palette.automation.error, .refreshing)

    palette.setTab(.tasks)
    palette.setTab(.automation)

    XCTAssertNil(palette.automation.error)
  }

  // MARK: - 棚の 2 行目

  /// 次の判定は時刻のある判定（最も早い時刻）→ 届いたら → 手動の順。止めていれば停止中。失敗した部品は全部品から数える。
  func testShelfStatusSaysTheNextJudgeAndTheFailedParts() throws {
    let palette = TaskPaletteSamples.model(
      [],
      automations: DesignSceneFixtures.automationRunner(
        DesignSceneFixtures.automationShelfSamples()))
    let automation = palette.automation
    func status(_ id: Int) throws -> TaskPaletteAutomationShelfStatus {
      let row = try XCTUnwrap(automation.shelfRows.first { $0.id == .automation(id) })
      return automation.status(of: try XCTUnwrap(row.automation), count: row.count)
    }
    let owned = try XCTUnwrap(automation.store.automation(1))

    XCTAssertEqual(
      try status(1),
      .standing(
        plan: .at(DesignSceneFixtures.automationAt(9, daysAgo: -1)), noCandidates: false,
        failed: [try XCTUnwrap(owned.graph.node("contact"))]))
    XCTAssertEqual(try status(2), .standing(plan: .onArrival, noCandidates: false, failed: []))
    XCTAssertEqual(try status(3), .standing(plan: .manual, noCandidates: false, failed: []))
    XCTAssertEqual(try status(4), .standing(plan: .onArrival, noCandidates: true, failed: []))
    let paused = try XCTUnwrap(automation.store.automation(5))
    XCTAssertEqual(
      try status(5),
      .standing(
        plan: .paused, noCandidates: true, failed: [try XCTUnwrap(paused.graph.node("fetch"))]))
  }

  /// 判定の予定の種類が混ざれば、時刻のある判定（定義の順ではなく最も早い時刻）→ 届いたら → 手動の順で最初に当たったもので
  /// 言う。
  func testShelfStatusOfMixedJudgesSaysTheMostConcreteOne() throws {
    let runner = DesignSceneFixtures.automationRunner()
    func define(_ judges: [(key: String, trigger: AutomationPart.Trigger)]) throws -> Automation {
      try runner.set(
        nil,
        AutomationDefinition(
          name: "混在", notify: nil,
          parts: [
            DesignSceneFixtures.commandPart(
              "fetch", "取得", .manual, script: "cat", coverage: .newArrivals)
          ]
            + judges.map {
              DesignSceneFixtures.agentPart(
                $0.key, $0.key, $0.trigger, from: ["fetch"], instruction: "i",
                deliver: .taskCandidates)
            }))
    }
    let timed = try define([
      ("arrival", .arrival), ("late", .scheduled(DesignSceneFixtures.cron("0 13 * * *"))),
      ("early", .scheduled(DesignSceneFixtures.cron("0 9 * * *"))),
    ])
    let untimed = try define([("manual", .manual), ("arrival", .arrival)])
    let automation = TaskPaletteSamples.model([], automations: runner).automation

    XCTAssertEqual(
      automation.status(of: timed, count: 1),
      .standing(
        plan: .at(DesignSceneFixtures.automationAt(9, daysAgo: -1)), noCandidates: false,
        failed: []))
    XCTAssertEqual(
      automation.status(of: untimed, count: 1),
      .standing(plan: .onArrival, noCandidates: false, failed: []))
  }

  /// 失敗した部品は最後の回が失敗した部品だけで、新しい失敗が先（定義の順ではない）。失敗の後に成功した部品は数えない。
  func testShelfStatusCountsOnlyLatestFailuresNewestFirst() throws {
    let at = { (hour: Int) in DesignSceneFixtures.automationAt(hour) }
    func fetch(_ key: String) -> AutomationPart {
      DesignSceneFixtures.commandPart(
        key, key, .scheduled(.every(3600)), script: key, coverage: .newArrivals)
    }
    let failed = DesignSceneFixtures.failed("exited 1")
    let sample = AutomationSample(
      definition: AutomationDefinition(
        name: "失敗", notify: nil,
        parts: [
          fetch("older"), fetch("newer"), fetch("recovered"),
          DesignSceneFixtures.agentPart(
            "judge", "判定", .manual, from: ["older", "newer", "recovered"], instruction: "i",
            deliver: .taskCandidates),
        ]),
      createdAt: DesignSceneFixtures.automationAt(9, daysAgo: 3),
      passes: [
        AutomationSamplePass(part: "recovered", at: at(8), outcome: failed),
        AutomationSamplePass(part: "older", at: at(9), outcome: failed),
        AutomationSamplePass(part: "newer", at: at(10), outcome: failed),
        AutomationSamplePass(
          part: "recovered", at: at(11),
          outcome: DesignSceneFixtures.fetched(
            "recovered", DesignSceneFixtures.sampleItems("recovered", 1, at: at(11)))),
      ])
    let automation = TaskPaletteSamples.model(
      [], automations: DesignSceneFixtures.automationRunner([sample])
    ).automation
    let owner = try XCTUnwrap(automation.store.automations.first)

    guard case .standing(_, _, let parts) = automation.status(of: owner, count: 0) else {
      return XCTFail("一巡は無い")
    }
    XCTAssertEqual(parts.map(\.key), ["newer", "older"])
  }
}
