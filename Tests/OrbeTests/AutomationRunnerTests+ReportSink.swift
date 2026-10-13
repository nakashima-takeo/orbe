import XCTest

@testable import Orbe

/// 出力先の報告。最後の段の出力を JSON の行として読まず、文章のまま回の記録に残す。何も出さなかった回は「報告なし」の記録を
/// 持ち、2,000 字を超える報告は切る。回を記録するたびに走らせ役が自動化の ID を知らせる。
///
/// 壊れると何が起きるか: 報告の各行が形違いとして捨てられ、報告が残らない。何も言うことが無かった回が「すべて除外」と読まれる。
/// 長い報告が回の記録を膨らませる。通知を付けた自動化の回がピルに出ない。
extension AutomationRunnerTests {
  private func reportDefinition() -> AutomationDefinition {
    var definition = AutomationStoreTests.definition()
    definition.source?.coverage = .everything
    definition.sink = .report
    return definition
  }

  func testTheLastStepTextIsKeptAsTheReport() throws {
    let automation = try create(reportDefinition())
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a", "b"]))
    XCTAssertTrue(prompt(1).contains("Output nothing when there is nothing to report."))
    jobs.finish(1, replied("\n開いている PR は 2 件。\n- #1 …\n- #2 …\n\n"))

    let run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(run.failure)
    XCTAssertEqual(run.sink, .report(text: "開いている PR は 2 件。\n- #1 …\n- #2 …"))
    XCTAssertEqual(run.steps.last?.count, 1, "報告は 1 つの文章")
    XCTAssertEqual(run.steps.last?.rejected.count, 0, "文章の行を形違いとして捨てない")
    XCTAssertEqual(recorded, [automation.id])
  }

  func testAnEmptyLastStepIsNothingToReport() throws {
    let automation = try create(reportDefinition())
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, replied("  \n"))

    let run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(run.failure)
    XCTAssertEqual(run.sink, .report(text: nil))
    XCTAssertEqual(run.steps.last?.count, 0)
  }

  func testNothingNewLeavesNoReportRecord() throws {
    let automation = try create(reportDefinition())
    try runner.runNow(automation.id)
    jobs.finish(0, fetched([]))

    let run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertNil(run.sink, "最後の段まで届かなかった回は出力先の記録を持たない")
    XCTAssertEqual(recorded, [automation.id])
  }

  func testALongReportIsCut() throws {
    let automation = try create(reportDefinition())
    try runner.runNow(automation.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, replied(String(repeating: "あ", count: 2_500)))

    let run = try XCTUnwrap(store.automation(automation.id)?.runs.first)
    XCTAssertEqual(run.sink, .report(text: String(repeating: "あ", count: 2_000) + "…"))
  }

  func testAFailedRunIsRecordedAndAStoppedRunIsNot() throws {
    let automation = try create(reportDefinition())
    try runner.runNow(automation.id)
    jobs.finish(0, fetched([], exit: 1, stderr: "boom"))
    XCTAssertEqual(recorded, [automation.id], "失敗した回も記録を知らせる")

    try runner.runNow(automation.id)
    var definition = reportDefinition()
    definition.steps = [AutomationStoreTests.judgeStep("別の指示")]
    _ = try runner.set(automation.id, definition)
    XCTAssertEqual(recorded, [automation.id], "書き換えで止めた回は記録しないので知らせない")
  }

  func testAReportNeedsAStep() throws {
    var definition = reportDefinition()
    definition.steps = []
    XCTAssertThrowsError(try runner.set(nil, definition)) {
      XCTAssertEqual($0 as? AutomationError, .invalid("sink: report needs at least one step"))
    }
    definition.source = nil
    definition.steps = [AutomationStoreTests.judgeStep()]
    XCTAssertNoThrow(try runner.set(nil, definition), "取得元は任意")
  }

  func testEditingAReportDoesNotReviewEverything() throws {
    var definition = reportDefinition()
    definition.source?.coverage = .currentSet
    let automation = try create(definition)
    definition.steps = [AutomationStoreTests.judgeStep("別の指示")]
    _ = try runner.set(automation.id, definition)
    XCTAssertEqual(store.automation(automation.id)?.reviewAll, false)
  }

  func testNotifyIsReadAndRefusesUnknownValues() throws {
    let json =
      #"{"name": "n", "trigger": {"everyMinutes": 30}, "steps": [], "sink": {"kind": "report"}, "notify": "menuBar"}"#
    let definition = try AutomationWire.decoder.decode(
      AutomationDefinition.self, from: Data(json.utf8))
    XCTAssertEqual(definition.notify, .menuBar)
    let reread = try AutomationWire.decoder.decode(
      AutomationDefinition.self, from: AutomationWire.encoder().encode(definition))
    XCTAssertEqual(reread, definition)

    let unknown = json.replacingOccurrences(of: "menuBar", with: "mail")
    XCTAssertThrowsError(
      try AutomationWire.decoder.decode(AutomationDefinition.self, from: Data(unknown.utf8))
    ) {
      guard case .dataCorrupted(let context) = $0 as? DecodingError else { return XCTFail("\($0)") }
      XCTAssertEqual(context.debugDescription, "pass menuBar")
    }
  }

  func testChangingOnlyNotifyKeepsTheRunGoing() throws {
    let automation = try create(reportDefinition())
    try runner.runNow(automation.id)
    var definition = reportDefinition()
    definition.notify = .menuBar
    _ = try runner.set(automation.id, definition)
    XCTAssertTrue(runner.isRunning(automation.id))
    XCTAssertTrue(jobs.stopped.isEmpty)
  }
}
