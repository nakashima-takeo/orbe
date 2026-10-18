import XCTest

@testable import Orbe

/// ボードの読み替え——一覧の右端と詳細の見出し。
///
/// 壊れると何が起きるか: 仕事の部品の応答の 1 行目が一覧の右端に入り、自動化の名前が潰れて読めなくなる。判定と報告を両方持つ
/// 自動化で、判定の回の見出しが「タスク候補・報告に追加」と誤った行き先を言う。
@MainActor
final class BoardAutomationSummaryTests: OrbeTestCase {
  private let text = AutomationText(
    l10n: LocalizationStore(language: .ja),
    today: .today(
      DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
    timeZone: DesignSceneFixtures.taskCalendar.timeZone)

  private func automation(_ samples: [AutomationSample]) throws -> Automation {
    try XCTUnwrap(DesignSceneFixtures.automationStore(samples).automations.first)
  }

  private func summary(_ samples: [AutomationSample]) throws -> BoardAutomationSummary {
    BoardAutomationSummary(try automation(samples), text: text, next: nil)
  }

  private func detail(_ samples: [AutomationSample]) throws -> BoardAutomationDetailValue {
    BoardAutomationDetailValue(
      try automation(samples), text: text, running: { _ in false }, open: 0)
  }

  func testAWorkRunWithAReplyShowsDoneAtTheRightEndNotTheReply() throws {
    let samples = [DesignSceneFixtures.boardAgentExample()]
    let summary = try summary(samples)
    let last = try detail(samples).last

    XCTAssertEqual(summary.mark, "10/3 9:00 に完了")
    XCTAssertTrue(last.hasSuffix("PR を投稿: レビュー待ちの PR 2 件を #dev-me に投稿した。"), last)
  }

  func testAJudgeRunSaysItAddedToTaskCandidatesEvenWithAReportPart() throws {
    let fixtures = DesignSceneFixtures.self
    let at = fixtures.automationAt(13)
    let item = fixtures.sampleItems("gh", 1, at: at)
    let sample = AutomationSample(
      definition: AutomationDefinition(
        name: "判定と要約", notify: nil,
        parts: [
          fixtures.commandPart(
            "fetch", "取る", .scheduled(.every(1800)), script: "gh", coverage: .newArrivals),
          fixtures.agentPart(
            "judge", "判定", .arrival, from: ["fetch"], instruction: "判定して",
            deliver: .taskCandidates),
          fixtures.agentPart(
            "digest", "要約", .scheduled(.every(86400)), from: ["fetch"], instruction: "要約して",
            deliver: .report),
        ]),
      createdAt: fixtures.automationAt(9),
      passes: [
        AutomationSamplePass(part: "fetch", at: at, outcome: fixtures.fetched("fetch", item)),
        AutomationSamplePass(
          part: "judge", at: at.addingTimeInterval(60), trigger: .arrival,
          outcome: fixtures.judged([fixtures.proposal(item[0], "対応する")], rows: 1)),
      ])

    let summary = try summary([sample])
    let last = try detail([sample]).last

    XCTAssertEqual(summary.output, "タスク候補・報告")
    XCTAssertTrue(last.hasSuffix("判定: 1件をタスク候補に追加"), last)
  }
}
